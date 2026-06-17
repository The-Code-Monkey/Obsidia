// Interactive serial shell: a read-eval-print loop over COM1.
//
// Input arrives as IRQ4 (UART "received data available"). The IRQ handler is the
// producer: it pushes incoming bytes into a ring buffer. The run loop is the
// consumer: it drains the ring, edits the current line, and on Enter parses and
// runs a command. When the ring is empty the CPU `hlt`s until the next interrupt
// (serial or timer), so the shell is idle-friendly rather than busy-polling.

const std = @import("std"); // string helpers (trim, eql, indexOfScalar)
const serial = @import("drivers/serial.zig"); // I/O
const pic = @import("arch/pic.zig"); // register the IRQ4 handler; read uptime ticks
const pmm = @import("mm/pmm.zig"); // for the `mem` command
const console = @import("drivers/console.zig"); // to blink the on-screen cursor
const power = @import("arch/power.zig"); // restart / shutdown
const scheduler = @import("sched/scheduler.zig"); // for the `ps` command
const apic = @import("arch/apic.zig"); // pause/resume the timer for `sleep`
const fat32 = @import("fs/fat32.zig"); // for the `ls` / `cat` commands
const loader = @import("loader.zig"); // for the `exec` command
const auth = @import("auth.zig"); // scrypt password verification (login)
const heap = @import("mm/heap.zig"); // allocator for the scrypt verify
const install = @import("install.zig"); // the `install` command (in-guest installer)
const editor = @import("editor.zig"); // the `edit` command (text editor)
const ac97 = @import("drivers/ac97.zig"); // the `play` command (AC'97 audio)
const rtc = @import("drivers/rtc.zig"); // the `date` command (RTC wall-clock)
const wav = @import("fs/wav.zig"); // WAV (RIFF) parsing for `play`

// --- Input ring buffer (single producer = IRQ, single consumer = run loop) ---
const RING_SIZE: usize = 256; // capacity (power of two)
var ring: [RING_SIZE]u8 = undefined; // the byte storage
var ring_head: usize = 0; // next write index — only the IRQ advances this
var ring_tail: usize = 0; // next read index  — only the run loop advances this

// Producer: push a byte (called from IRQ context). Drops the byte if full.
fn ringPush(c: u8) void {
    const head = ring_head; // we (the producer) own head, plain read is fine
    const next = (head + 1) % RING_SIZE; // where head will point after this write
    if (next == @atomicLoad(usize, &ring_tail, .acquire)) return; // buffer full -> drop
    ring[head] = c; // store the byte
    @atomicStore(usize, &ring_head, next, .release); // publish it to the consumer
}

// Consumer: pop a byte, or null if empty (called from the run loop).
fn ringPop() ?u8 {
    const tail = ring_tail; // we (the consumer) own tail, plain read is fine
    if (tail == @atomicLoad(usize, &ring_head, .acquire)) return null; // empty
    const c = ring[tail]; // load the byte
    @atomicStore(usize, &ring_tail, (tail + 1) % RING_SIZE, .release); // consume it
    return c;
}

// Public input sink: push one byte into the shell's input ring. The keyboard
// driver registers this as its sink, so keystrokes feed the same buffer as
// serial input. (Both callers are IRQ handlers, which are serialized on a single
// core, so the single-producer invariant still holds.)
pub fn feed(c: u8) void {
    ringPush(c);
}

// True if the input ring currently holds no bytes. Reads ring_head atomically
// since the producer (an IRQ) advances it.
fn ringEmpty() bool {
    return ring_tail == @atomicLoad(usize, &ring_head, .acquire);
}

// Block until one input byte is available and return it. Idles on `hlt` between
// checks (woken by the input/timer IRQ). Used by the editor to read keystrokes.
pub fn getKeyBlocking() u8 {
    while (true) {
        if (ringPop()) |b| return b;
        asm volatile ("hlt");
    }
}

// Full-system sleep: halt the whole machine until a key is pressed. We mask the
// LAPIC timer (the kernel's preemption + timekeeping source), so nothing runs —
// no thread switching, no tick counting — and the CPU deep-halts. Only an input
// interrupt (keyboard/serial) can wake it. The waking key is consumed, not echoed.
fn systemSleep() void {
    asm volatile ("cli"); // set up the sleep atomically vs. input IRQs
    while (ringPop() != null) {} // drain stale input so we don't wake immediately
    apic.pauseTimer(); // stop the timer: the whole system goes quiet

    // Sleep until a byte arrives. `sti; hlt` is atomic (no interrupt is taken
    // between them), so a key that arrives right here can't be lost; the `cli`
    // after the wakeup re-masks for the next ring check.
    while (ringEmpty()) {
        asm volatile ("sti; hlt; cli");
    }

    apic.resumeTimer(); // timer back -> preemption + timekeeping resume
    asm volatile ("sti");
    _ = ringPop(); // discard the key that woke us
}

// IRQ4 handler: drain everything the UART has buffered into the ring.
fn onSerialIrq() void {
    while (serial.dataAvailable()) { // while bytes are waiting
        feed(serial.readByteRaw()); // enqueue (also clears the IRQ)
    }
}

// --- Line editor with history and cursor movement ----------------------------
var line: [256]u8 = undefined; // the line being edited
var line_len: usize = 0; // number of bytes in the line
var line_pos: usize = 0; // cursor index within the line (0..line_len)

// Command history (a small ring of recent command lines).
const HIST_SIZE: usize = 16;
var hist: [HIST_SIZE][256]u8 = undefined; // stored command bytes
var hist_lens: [HIST_SIZE]usize = undefined; // length of each stored command
var hist_head: usize = 0; // index where the next command will be stored
var hist_size: usize = 0; // number of valid entries (<= HIST_SIZE)
var browse: usize = 0; // history browse depth: 0 = fresh line, n = n-th most recent

// Escape-sequence parser for INPUT (arrow keys etc. arrive as ESC [ ...).
var in_esc: u8 = 0; // 0 = normal, 1 = saw ESC, 2 = in CSI
var csi_param: usize = 0; // numeric parameter of the current CSI sequence

// --- Terminal output helpers -------------------------------------------------
// These emit ANSI sequences that both the serial terminal and our framebuffer
// console understand, so the on-screen line stays in sync with our buffer.
fn moveLeft(n: usize) void {
    if (n > 0) serial.print("\x1b[{d}D", .{n}); // cursor left n columns
}
fn moveRight(n: usize) void {
    if (n > 0) serial.print("\x1b[{d}C", .{n}); // cursor right n columns
}
fn printRange(a: usize, b: usize) void {
    serial.print("{s}", .{line[a..b]}); // echo line[a..b]
}

// --- Editing operations ------------------------------------------------------
// Insert a character at the cursor, shifting the tail right.
fn insertChar(ch: u8) void {
    if (line_len >= line.len) return; // line full
    var i = line_len;
    while (i > line_pos) : (i -= 1) line[i] = line[i - 1]; // shift tail right
    line[line_pos] = ch;
    line_len += 1;
    printRange(line_pos, line_len); // redraw from the new char to the end
    line_pos += 1;
    moveLeft(line_len - line_pos); // move back to just after the inserted char
    browse = 0; // we're now editing a fresh line
}

// Delete the character before the cursor (Backspace).
fn backspace() void {
    if (line_pos == 0) return; // nothing to the left
    var i = line_pos - 1;
    while (i < line_len - 1) : (i += 1) line[i] = line[i + 1]; // shift tail left
    line_len -= 1;
    line_pos -= 1;
    moveLeft(1); // step onto the deleted cell
    printRange(line_pos, line_len); // redraw the tail
    serial.print(" ", .{}); // erase the now-stale last cell
    moveLeft(line_len - line_pos + 1); // move back to the cursor
    browse = 0;
}

// Delete the character at the cursor (Delete key).
fn deleteForward() void {
    if (line_pos >= line_len) return; // nothing under the cursor
    var i = line_pos;
    while (i < line_len - 1) : (i += 1) line[i] = line[i + 1]; // shift tail left
    line_len -= 1;
    printRange(line_pos, line_len); // redraw the tail
    serial.print(" ", .{}); // erase the stale last cell
    moveLeft(line_len - line_pos + 1); // move back to the cursor
    browse = 0;
}

// Replace the whole line (used when recalling history).
fn replaceLine(new: []const u8) void {
    moveLeft(line_pos); // go to the start of the input area
    var i: usize = 0;
    while (i < new.len) : (i += 1) line[i] = new[i]; // copy in the new text
    line_len = new.len;
    line_pos = line_len;
    printRange(0, line_len); // draw it
    serial.print("\x1b[K", .{}); // clear any leftover from a longer previous line
}

// --- History -----------------------------------------------------------------
fn addHistory(s: []const u8) void {
    if (s.len == 0) return; // don't store blank lines
    if (hist_size > 0) { // skip if identical to the most recent
        const last = (hist_head + HIST_SIZE - 1) % HIST_SIZE;
        if (hist_lens[last] == s.len and std.mem.eql(u8, hist[last][0..s.len], s)) return;
    }
    var i: usize = 0;
    while (i < s.len) : (i += 1) hist[hist_head][i] = s[i]; // store the command
    hist_lens[hist_head] = s.len;
    hist_head = (hist_head + 1) % HIST_SIZE; // advance the ring
    if (hist_size < HIST_SIZE) hist_size += 1;
}

// Return the command `back` entries ago (1 = most recent).
fn histAt(back: usize) []const u8 {
    const idx = (hist_head + HIST_SIZE - back) % HIST_SIZE;
    return hist[idx][0..hist_lens[idx]];
}

fn historyUp() void {
    if (browse >= hist_size) return; // already at the oldest
    browse += 1;
    replaceLine(histAt(browse));
}

fn historyDown() void {
    if (browse == 0) return; // already at the fresh line
    browse -= 1;
    if (browse == 0) replaceLine("") else replaceLine(histAt(browse));
}

// --- Working directory -------------------------------------------------------
// The shell tracks a current directory so paths can be relative. ls/cat/exec/cd
// all resolve their argument against it. Starts at the root "/".
var cwd_buf: [256]u8 = [_]u8{'/'} ++ [_]u8{0} ** 255;
var cwd_len: usize = 1;

// Collapse "." and ".." in `raw` into a clean absolute path written to `out`.
fn normalizePath(raw: []const u8, out: []u8) []const u8 {
    var comps: [32][]const u8 = undefined; // path components after normalization
    var n: usize = 0;
    var it = std.mem.tokenizeScalar(u8, raw, '/');
    while (it.next()) |c| {
        if (std.mem.eql(u8, c, ".")) continue; // "." = stay here
        if (std.mem.eql(u8, c, "..")) { // ".." = up one (no-op at root)
            if (n > 0) n -= 1;
            continue;
        }
        if (n < comps.len) {
            comps[n] = c;
            n += 1;
        }
    }
    if (n == 0) { // everything collapsed away -> root
        out[0] = '/';
        return out[0..1];
    }
    var len: usize = 0;
    for (comps[0..n]) |c| {
        out[len] = '/';
        len += 1;
        @memcpy(out[len..][0..c.len], c);
        len += c.len;
    }
    return out[0..len];
}

// Resolve `arg` to a normalized absolute path in `out`. An absolute arg is taken
// as-is; a relative one is joined onto the current directory; "" means the cwd.
fn resolvePath(arg: []const u8, out: []u8) []const u8 {
    var raw: [512]u8 = undefined;
    var rl: usize = 0;
    if (arg.len > 0 and arg[0] == '/') {
        @memcpy(raw[0..arg.len], arg);
        rl = arg.len;
    } else {
        @memcpy(raw[0..cwd_len], cwd_buf[0..cwd_len]); // start from the cwd
        rl = cwd_len;
        raw[rl] = '/';
        rl += 1;
        @memcpy(raw[rl..][0..arg.len], arg);
        rl += arg.len;
    }
    return normalizePath(raw[0..rl], out);
}

// --- Input handling ----------------------------------------------------------
fn prompt() void {
    serial.print("obsidia:{s}> ", .{cwd_buf[0..cwd_len]}); // show the current directory
}

fn submitLine() void {
    serial.print("\n", .{}); // finish the current line
    addHistory(line[0..line_len]); // remember it
    execute(line[0..line_len]); // run it
    line_len = 0; // reset for the next line
    line_pos = 0;
    browse = 0;
    prompt();
}

// Interpret a CSI escape sequence (arrow keys, Home/End, Delete, Page Up/Down).
fn handleCsi(c: u8) void {
    if (c >= '0' and c <= '9') { // accumulate the numeric parameter
        csi_param = csi_param * 10 + (c - '0');
        return;
    }
    in_esc = 0; // any non-digit is the final byte
    // Page Up / Page Down (ESC[5~ / ESC[6~) drive the console's scrollback and
    // leave the edited line alone. Every other key is line editing, so first snap
    // the on-screen view back to the live bottom (no-op if already there).
    if (c == '~' and csi_param == 5) return console.scrollUp();
    if (c == '~' and csi_param == 6) return console.scrollDown();
    console.scrollToBottom();
    switch (c) {
        'A' => historyUp(), // Up arrow
        'B' => historyDown(), // Down arrow
        'C' => if (line_pos < line_len) { // Right arrow
            line_pos += 1;
            moveRight(1);
        },
        'D' => if (line_pos > 0) { // Left arrow
            line_pos -= 1;
            moveLeft(1);
        },
        'H' => { // Home
            moveLeft(line_pos);
            line_pos = 0;
        },
        'F' => { // End
            moveRight(line_len - line_pos);
            line_pos = line_len;
        },
        '~' => if (csi_param == 3) deleteForward(), // Delete key
        else => {},
    }
}

// Process one input byte: drive the escape parser, then editing/commands.
fn handleChar(c: u8) void {
    switch (in_esc) {
        1 => { // saw ESC
            if (c == '[') {
                in_esc = 2;
                csi_param = 0;
            } else in_esc = 0;
            return;
        },
        2 => { // in CSI
            handleCsi(c);
            return;
        },
        else => {},
    }
    if (c == 0x1b) { // ESC begins a sequence
        in_esc = 1;
        return;
    }

    console.scrollToBottom(); // any real keystroke returns to the live bottom
    switch (c) {
        '\r', '\n' => submitLine(), // Enter: run the line
        0x08, 0x7f => backspace(), // Backspace / DEL
        else => if (c >= 0x20 and c < 0x7f) insertChar(c), // printable character
    }
}

// Bridge a fat32.FileReader to ac97's FillFn: hand the player the next chunk of
// the file each time it needs to refill a DMA buffer (raw-PCM path).
fn fillFromReader(ctx: *anyopaque, dst: []u8) usize {
    const r: *fat32.FileReader = @ptrCast(@alignCast(ctx));
    return r.read(dst);
}

// Bridge a wav.Stream to ac97's FillFn (WAV path: data-chunk-limited, mono->stereo).
fn fillWav(ctx: *anyopaque, dst: []u8) usize {
    const s: *wav.Stream = @ptrCast(@alignCast(ctx));
    return s.fill(dst);
}

// Does `path` end in ".wav" (case-insensitive)? Selects the WAV vs raw-PCM path.
fn hasWavExt(path: []const u8) bool {
    return path.len >= 4 and std.ascii.eqlIgnoreCase(path[path.len - 4 ..], ".wav");
}

// --- Command dispatch --------------------------------------------------------
fn execute(raw: []const u8) void {
    const text = std.mem.trim(u8, raw, " \t\r\n"); // strip surrounding whitespace
    if (text.len == 0) return; // blank line: do nothing
    const sp = std.mem.indexOfScalar(u8, text, ' '); // find the first space
    const cmd = if (sp) |i| text[0..i] else text; // the command word
    const args = if (sp) |i| std.mem.trim(u8, text[i + 1 ..], " ") else text[0..0]; // the rest

    if (std.mem.eql(u8, cmd, "help")) { // list commands
        serial.print("commands: help, clear, echo <text>, mem, uptime, history, ps,\n", .{});
        serial.print("          cd [dir], ls [path], cat <path>, edit <path>, exec <path>, date,\n", .{});
        if (ac97.isPresent()) serial.print("          play <file> (.wav or 16-bit stereo 48 kHz .pcm),\n", .{});
        if (install.available()) serial.print("          install (clone Obsidia onto the disk),\n", .{});
        serial.print("          sleep (full-system sleep til keypress), restart, shutdown, crash\n", .{});
        serial.print("  (up/down = history, left/right/home/end = move, del = delete,\n", .{});
        serial.print("   pageup/pagedown = scroll the screen back/forward)\n", .{});
    } else if (std.mem.eql(u8, cmd, "restart") or std.mem.eql(u8, cmd, "reboot")) { // reboot
        serial.print("restarting...\n", .{});
        power.reboot();
    } else if (std.mem.eql(u8, cmd, "shutdown") or std.mem.eql(u8, cmd, "poweroff")) { // power off
        serial.print("shutting down...\n", .{});
        power.shutdown();
    } else if (std.mem.eql(u8, cmd, "sleep")) { // full-system sleep until a keypress
        serial.print("system sleep... press a key to wake.\n", .{});
        systemSleep(); // halt the whole machine (timer off) until input arrives
        serial.print("awake.\n", .{});
    } else if (std.mem.eql(u8, cmd, "history")) { // list recent commands
        var k = hist_size;
        while (k > 0) : (k -= 1) { // oldest first
            serial.print("  {d}: {s}\n", .{ hist_size - k + 1, histAt(k) });
        }
    } else if (std.mem.eql(u8, cmd, "cd")) { // change the current directory
        var pbuf: [256]u8 = undefined;
        const target = resolvePath(if (args.len > 0) args else "/", &pbuf);
        if (std.mem.eql(u8, target, "/")) { // root always exists
            cwd_buf[0] = '/';
            cwd_len = 1;
        } else if (fat32.resolve(target)) |node| {
            if (!node.is_dir) {
                serial.print("cd: not a directory: {s}\n", .{target});
            } else if (target.len > cwd_buf.len) {
                serial.print("cd: path too long\n", .{});
            } else {
                @memcpy(cwd_buf[0..target.len], target);
                cwd_len = target.len;
            }
        } else serial.print("cd: no such directory: {s}\n", .{target});
    } else if (std.mem.eql(u8, cmd, "ls")) { // list a directory on the FAT32 disk
        var pbuf: [256]u8 = undefined;
        fat32.ls(resolvePath(args, &pbuf)); // no arg -> the current directory
    } else if (std.mem.eql(u8, cmd, "cat")) { // print a file from the FAT32 disk
        if (args.len == 0) {
            serial.print("usage: cat <path>\n", .{});
        } else {
            var pbuf: [256]u8 = undefined;
            fat32.cat(resolvePath(args, &pbuf));
        }
    } else if (std.mem.eql(u8, cmd, "play")) { // stream an audio file to the AC'97 codec
        if (args.len == 0) {
            serial.print("usage: play <file>  (.wav, or raw 16-bit stereo 48 kHz .pcm)\n", .{});
        } else if (!ac97.isPresent()) {
            serial.print("play: no audio device\n", .{});
        } else {
            var pbuf: [256]u8 = undefined;
            const path = resolvePath(args, &pbuf);
            if (fat32.open(path)) |reader| {
                var r = reader; // stable storage for the streaming cursor
                if (hasWavExt(path)) { // .wav: parse the header, then stream the data chunk
                    if (wav.parse(&r)) |fmt| {
                        var stream = wav.Stream{ .reader = &r, .remaining = fmt.data_bytes, .channels = fmt.channels };
                        serial.print("play: WAV {d} Hz, {d} ch, {d}-bit, {d} data bytes\n", .{ fmt.sample_rate, fmt.channels, fmt.bits, fmt.data_bytes });
                        const n = ac97.play(fmt.sample_rate, &stream, &fillWav);
                        serial.print("play: streamed {d} bytes of {s}\n", .{ n, path });
                    } else serial.print("play: not a playable WAV: {s}\n", .{path});
                } else { // anything else: treat as raw 16-bit stereo 48 kHz PCM
                    const n = ac97.play(48000, &r, &fillFromReader);
                    serial.print("play: streamed {d} bytes of {s}\n", .{ n, path });
                }
            } else serial.print("play: no such file: {s}\n", .{path});
        }
    } else if (std.mem.eql(u8, cmd, "exec")) { // load + run an ELF or flat binary as a ring-3 process
        if (args.len == 0) {
            serial.print("usage: exec <path>\n", .{});
        } else {
            var pbuf: [256]u8 = undefined;
            _ = loader.execUser(resolvePath(args, &pbuf));
        }
    } else if (std.mem.eql(u8, cmd, "exec0")) { // legacy: load + run in ring 0 (the old binary contract)
        if (args.len == 0) {
            serial.print("usage: exec0 <path>\n", .{});
        } else {
            var pbuf: [256]u8 = undefined;
            _ = loader.exec(resolvePath(args, &pbuf));
        }
    } else if (std.mem.eql(u8, cmd, "edit")) { // open a file in the text editor
        if (args.len == 0) {
            serial.print("usage: edit <path>\n", .{});
        } else {
            var pbuf: [256]u8 = undefined;
            editor.run(resolvePath(args, &pbuf), &getKeyBlocking);
        }
    } else if (std.mem.eql(u8, cmd, "install")) { // install Obsidia onto the disk
        install.run(&getKeyBlocking); // construct a fresh disk, or clone the image
    } else if (std.mem.eql(u8, cmd, "ps")) { // list kernel threads
        scheduler.dump();
    } else if (std.mem.eql(u8, cmd, "clear")) { // clear the terminal
        serial.print("\x1b[2J\x1b[H", .{}); // ANSI: erase screen + cursor home
    } else if (std.mem.eql(u8, cmd, "echo")) { // print the arguments back
        serial.print("{s}\n", .{args});
    } else if (std.mem.eql(u8, cmd, "mem")) { // physical memory stats
        const free = pmm.freeFrames(); // free frames
        const total = pmm.totalFrames(); // total frames
        const free_mib = free * pmm.PAGE_SIZE / (1024 * 1024); // free MiB
        const total_mib = total * pmm.PAGE_SIZE / (1024 * 1024); // total MiB
        serial.print("memory: {d}/{d} frames free ({d}/{d} MiB)\n", .{ free, total, free_mib, total_mib });
    } else if (std.mem.eql(u8, cmd, "date")) { // current wall-clock time from the RTC
        rtc.printDateTime(rtc.now()); // read + format "YYYY-MM-DD HH:MM:SS UTC"
        serial.print("\n", .{});
    } else if (std.mem.eql(u8, cmd, "uptime")) { // seconds since boot
        const t = pic.ticks(); // 100 Hz tick counter
        serial.print("uptime: {d}.{d:0>2}s ({d} ticks @ 100 Hz)\n", .{ t / 100, t % 100, t });
    } else if (std.mem.eql(u8, cmd, "crash")) { // demo the IDT crash dump
        serial.print("triggering a page fault to demo the crash dump...\n", .{});
        const bad: *volatile u8 = @ptrFromInt(0xdeadbeef); // unmapped address (u8 = no alignment requirement)
        bad.* = 0; // write -> #PF -> IDT dumps registers and halts
    } else { // anything else
        serial.print("unknown command: {s} (try 'help')\n", .{cmd});
    }
}

// --- Public entry points -----------------------------------------------------
pub fn init() void {
    serial.print("[SHELL] Starting interactive serial shell...\n", .{});
    serial.enableRxInterrupt(); // make the UART raise IRQ4 on input
    pic.register(4, &onSerialIrq); // route IRQ4 to our handler and unmask it
    serial.print("[SHELL] Type 'help' for commands.\n", .{});
}

// --- Login -------------------------------------------------------------------
// Credentials live in /OBSIDIA/AUTH on the disk as a single line "user:phc",
// where phc is an Argon2id PHC hash (created by the installer). If the file is
// absent (e.g. a disk-less dev boot), login is skipped so the shell still comes
// up. Otherwise the shell is gated behind a username + password check.
var cred_user: [64]u8 = undefined; // configured username
var cred_user_len: usize = 0;
var cred_phc: [auth.MAX_HASH]u8 = undefined; // configured scrypt PHC hash
var cred_phc_len: usize = 0;

// The credential bytes Limine loaded as a module, if any (set by main before the
// shell starts). Preferred over the on-disk file because it works on a GPT disk
// without the kernel parsing partitions.
var auth_module: ?[]const u8 = null;
pub fn setAuthModule(m: ?[]const u8) void {
    auth_module = m;
}

// Read and parse the credential ("user:phc") into cred_user/cred_phc. Prefers
// the Limine auth module, falling back to /OBSIDIA/AUTH on a plain FAT32 disk.
// Returns false if there's no usable credential.
fn loadCredential() bool {
    var buf: [512]u8 = undefined;
    const raw: []const u8 = if (auth_module) |m| m else blk: {
        const n = fat32.readFile("/OBSIDIA/AUTH", &buf) orelse return false;
        break :blk buf[0..n];
    };
    const text = std.mem.trim(u8, raw, " \t\r\n");
    const colon = std.mem.indexOfScalar(u8, text, ':') orelse return false; // user:phc
    const user = text[0..colon];
    const phc = text[colon + 1 ..];
    if (user.len == 0 or user.len > cred_user.len) return false;
    if (phc.len == 0 or phc.len > cred_phc.len) return false;
    @memcpy(cred_user[0..user.len], user);
    cred_user_len = user.len;
    @memcpy(cred_phc[0..phc.len], phc);
    cred_phc_len = phc.len;
    return true;
}

// Block until a full line is read from the input ring. `echo` controls whether
// typed characters are shown (false masks them with '*', for passwords). Handles
// backspace and Enter; ignores other control bytes.
fn readLine(buf: []u8, echo: bool) usize {
    var len: usize = 0;
    while (true) {
        const c = while (true) {
            if (ringPop()) |b| break b;
            asm volatile ("hlt"); // idle until the next input/timer interrupt
        };
        switch (c) {
            '\r', '\n' => {
                serial.print("\n", .{});
                return len;
            },
            0x08, 0x7f => if (len > 0) { // backspace
                len -= 1;
                if (echo) serial.print("\x08 \x08", .{}); // rub out the echoed char
            },
            else => if (c >= 0x20 and c < 0x7f and len < buf.len) {
                buf[len] = c;
                len += 1;
                serial.print("{c}", .{if (echo) c else '*'}); // echo, or mask passwords
            },
        }
    }
}

// Gate the shell behind a login if a credential is configured. Loops until the
// username + Argon2id-verified password match. No-op (open shell) when no
// credential exists, so disk-less boots are unaffected.
fn login() void {
    if (!loadCredential()) {
        serial.print("[LOGIN] no credential configured (/OBSIDIA/AUTH absent); open shell.\n", .{});
        return;
    }
    while (true) {
        var ubuf: [64]u8 = undefined;
        var pbuf: [128]u8 = undefined;
        serial.print("\nobsidia login: ", .{});
        const ulen = readLine(&ubuf, true);
        serial.print("password: ", .{});
        const plen = readLine(&pbuf, false);
        // Verify the username AND the Argon2id hash. Both must match.
        const user_ok = std.mem.eql(u8, ubuf[0..ulen], cred_user[0..cred_user_len]);
        const pass_ok = auth.verify(heap.allocator(), cred_phc[0..cred_phc_len], pbuf[0..plen]);
        if (user_ok and pass_ok) {
            serial.print("\nWelcome, {s}.\n", .{cred_user[0..cred_user_len]});
            return;
        }
        serial.print("\nLogin incorrect.\n", .{});
    }
}

// The shell loop. Never returns: it is the kernel's idle task now.
pub fn run() noreturn {
    login(); // gate behind a password if one is configured
    prompt(); // initial prompt
    while (true) {
        console.cursorBlinkTick(); // blink the on-screen cursor (no-op until due)
        if (ringPop()) |c| { // got an input byte?
            handleChar(c); // edit the line / run a command
        } else {
            // Nothing buffered: sleep until any interrupt. The 100 Hz timer
            // guarantees we re-check at least every 10 ms, so even a missed
            // serial-IRQ wakeup costs at most one tick of latency.
            asm volatile ("hlt");
        }
    }
}
