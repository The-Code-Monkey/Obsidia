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

// --- Input handling ----------------------------------------------------------
fn prompt() void {
    serial.print("obsidia> ", .{});
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

// Interpret a CSI escape sequence (arrow keys, Home/End, Delete).
fn handleCsi(c: u8) void {
    if (c >= '0' and c <= '9') { // accumulate the numeric parameter
        csi_param = csi_param * 10 + (c - '0');
        return;
    }
    in_esc = 0; // any non-digit is the final byte
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

    switch (c) {
        '\r', '\n' => submitLine(), // Enter: run the line
        0x08, 0x7f => backspace(), // Backspace / DEL
        else => if (c >= 0x20 and c < 0x7f) insertChar(c), // printable character
    }
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
        serial.print("          ls [path], cat <path>, sleep (full-system sleep til keypress),\n", .{});
        serial.print("          restart, shutdown, crash\n", .{});
        serial.print("  (up/down = history, left/right/home/end = move, del = delete)\n", .{});
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
    } else if (std.mem.eql(u8, cmd, "ls")) { // list a directory on the FAT32 disk
        fat32.ls(if (args.len > 0) args else "/"); // default to the root directory
    } else if (std.mem.eql(u8, cmd, "cat")) { // print a file from the FAT32 disk
        if (args.len == 0) serial.print("usage: cat <path>\n", .{}) else fat32.cat(args);
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

// The shell loop. Never returns: it is the kernel's idle task now.
pub fn run() noreturn {
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
