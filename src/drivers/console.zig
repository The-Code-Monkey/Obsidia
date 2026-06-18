// Framebuffer text console: renders characters as pixels into Limine's linear
// framebuffer (the QEMU window / a real monitor), as opposed to the serial port.
//
// Glyphs come from an embedded PSF (PC Screen Font) bitmap font: each glyph is a
// small grid of bits, so drawing a character is just copying those bits to
// pixels. We parse the PSF header at comptime, so dropping in a different PSF is
// a one-line change. (PSF only — scalable TrueType/OpenType would need a runtime
// rasterizer and the FPU, which is a separate future project.)
//
// Font: Tamzen (sunaku/tamzen-font), a freely-licensed bitmap font.

const std = @import("std"); // for std.fmt + std.mem.copyForwards
const serial = @import("serial.zig"); // for logging during init
const pic = @import("../arch/pic.zig"); // timer ticks, to pace the cursor blink
const sync = @import("../sched/sync.zig"); // print lock (atomic console updates)

// The font file, embedded directly into the kernel binary.
const psf = @embedFile("../fonts/Tamzen8x16.psf");

// --- PSF parsing (comptime) --------------------------------------------------
// Describes the embedded font after we've decoded its header.
const Font = struct {
    glyphs: []const u8, // raw glyph bitmaps (count * bytes_per_glyph)
    count: usize, // number of glyphs
    width: usize, // glyph width in pixels (we assume <= 8 -> 1 byte per row)
    height: usize, // glyph height in pixels
    bytes_per_row: usize, // ceil(width / 8)
    bytes_per_glyph: usize, // bytes for one glyph
};

// Read a little-endian u32 out of the font data at a fixed offset.
fn readU32(comptime data: []const u8, comptime off: usize) usize {
    return @as(usize, data[off]) | (@as(usize, data[off + 1]) << 8) |
        (@as(usize, data[off + 2]) << 16) | (@as(usize, data[off + 3]) << 24);
}

// Decode either a PSF1 or PSF2 header into a Font descriptor, at compile time.
fn parsePsf(comptime data: []const u8) Font {
    if (data[0] == 0x36 and data[1] == 0x04) { // PSF1 magic
        const mode = data[2]; // bit 0 set => 512 glyphs, else 256
        const charsize = data[3]; // bytes per glyph (= height, width is always 8)
        const count: usize = if (mode & 0x01 != 0) 512 else 256;
        return .{
            .glyphs = data[4 .. 4 + count * charsize], // glyphs follow the 4-byte header
            .count = count,
            .width = 8, // PSF1 is always 8 px wide
            .height = charsize,
            .bytes_per_row = 1,
            .bytes_per_glyph = charsize,
        };
    }
    if (data[0] == 0x72 and data[1] == 0xb5 and data[2] == 0x4a and data[3] == 0x86) { // PSF2 magic
        const headersize = readU32(data, 8); // where glyph data begins
        const count = readU32(data, 16); // glyph count
        const charsize = readU32(data, 20); // bytes per glyph
        const height = readU32(data, 24); // glyph height
        const width = readU32(data, 28); // glyph width
        return .{
            .glyphs = data[headersize .. headersize + count * charsize],
            .count = count,
            .width = width,
            .height = height,
            .bytes_per_row = (width + 7) / 8,
            .bytes_per_glyph = charsize,
        };
    }
    @compileError("console.zig: unrecognized PSF font magic");
}

const font: Font = parsePsf(psf); // decode our embedded font once, at comptime

// --- Framebuffer description (filled in from Limine) -------------------------
pub const FramebufferInfo = struct {
    address: usize, // virtual address of pixel (0,0)
    width: usize, // visible width in pixels
    height: usize, // visible height in pixels
    pitch: usize, // bytes per scanline (may exceed width * bytesPerPixel)
    bpp: u16, // bits per pixel (we assume 32)
    red_shift: u8, // bit position of the red channel
    green_shift: u8, // ...green
    blue_shift: u8, // ...blue
};

var fb: FramebufferInfo = undefined; // the active framebuffer
var cols: usize = 0; // text columns (width / glyph width)
var rows: usize = 0; // text rows (height / glyph height)
var cur_x: usize = 0; // cursor column
var cur_y: usize = 0; // cursor row (screen row of the cursor's line)
var fg: u32 = 0; // foreground pixel value
var bg: u32 = 0; // background pixel value
var ready: bool = false; // true once init() has run
var esc_state: u8 = 0; // ANSI escape parser: 0=normal, 1=saw ESC, 2=in CSI
var csi_param: usize = 0; // numeric parameter accumulated in a CSI sequence

// --- Scrollback --------------------------------------------------------------
// Everything written is recorded in an in-memory character grid much taller than
// the visible screen, so the user can scroll back to re-read output that has
// already rolled off the top. The framebuffer shows a `rows`-tall WINDOW onto
// this grid; normally that window sits at the live bottom, but PageUp/PageDown
// slide it up and down over the retained history.
//
// Lines are addressed by a monotonic ABSOLUTE index and stored circularly
// (physical slot = abs % SB_LINES), so once we've written SB_LINES lines the
// oldest silently roll out of the buffer. The grid is the single source of
// truth: the live fast path draws straight to pixels AND records here, and any
// scrolled view is re-rendered purely from the grid.
const MAX_COLS: usize = 256; // widest line we record (>= any real text width)
const SB_LINES: usize = 1024; // total lines retained (visible window + scrollback)
var grid: [SB_LINES][MAX_COLS]u8 = undefined; // circular store of line contents (space-filled ASCII)
var top_abs: usize = 0; // absolute index of the line at screen row 0 when live
var max_abs: usize = 0; // highest absolute line index written so far (high-water mark)
var scrolled: bool = false; // true while the view is scrolled up off the live bottom
var view_top: usize = 0; // absolute index at screen row 0 while `scrolled`

// Blinking cursor state.
const BLINK_TICKS: u64 = 50; // toggle every 50 timer ticks (~500 ms at 100 Hz)
var cursor_drawn: bool = false; // is the cursor underline currently on screen?
var cursor_col: usize = 0; // where it was last drawn (so we can erase it)
var cursor_row: usize = 0;
var blink_phase: bool = false; // current on/off phase of the blink
var last_toggle: u64 = 0; // tick count at the last toggle

// Compose a pixel value from 8-bit r/g/b using the framebuffer's channel shifts.
fn makeColor(r: u8, g: u8, b: u8) u32 {
    return (@as(u32, r) << @intCast(fb.red_shift)) |
        (@as(u32, g) << @intCast(fb.green_shift)) |
        (@as(u32, b) << @intCast(fb.blue_shift));
}

// Write one pixel (assumes 32 bits per pixel).
fn putpixel(x: usize, y: usize, color: u32) void {
    const offset = y * fb.pitch + x * (fb.bpp / 8); // byte offset of this pixel
    const ptr: *volatile u32 = @ptrFromInt(fb.address + offset); // its address
    ptr.* = color; // store the color
}

// Fill a `w` x `h` pixel rectangle whose top-left is at (x0, y0) with a single
// solid `color`, using row-stride bulk copies instead of one volatile store per
// pixel. This is the hot path for screen clears and the post-scroll bottom-row
// fill: for a 1280x800 screen that is ~1M pixels, so the old per-pixel volatile
// stores dominated the cost of every clear/scroll.
//
// Strategy: build a short run of the fill color in a small stack buffer, then
// stamp it across each row in template-sized chunks with std.mem.copyForwards
// (which lowers to an optimized memcpy). The existing move-up scroll already
// memmoves the whole framebuffer as plain RAM, so a non-volatile bulk store is
// equally correct here; we keep the volatile putpixel only for the cursor's
// tiny spans where elision could bite. Like putpixel, this assumes 32 bpp.
//
// The template is deliberately small (1 KiB), not a full scanline: this runs on
// the live print path (newline -> scrollFb -> fillRect, under preemptDisable)
// where the 32 KiB thread stack is shared with std.fmt etc., so a multi-KiB
// frame here is undesirable. The chunk loop makes any width correct, and even
// at 1280 px wide that is only ~5 memcpys per row — still vastly cheaper than
// the old ~1280 volatile stores per row.
const FILL_TMPL_PX: usize = 256; // pixels per fill template (256 * 4 B = 1 KiB)

fn fillRect(x0: usize, y0: usize, w: usize, h: usize, color: u32) void {
    if (w == 0 or h == 0) return; // empty rectangle: nothing to do
    const bpp_bytes = fb.bpp / 8; // bytes per pixel (4 at 32 bpp)

    var rowbuf: [FILL_TMPL_PX]u32 = undefined; // the reusable solid-color run
    const tmpl = @min(w, rowbuf.len); // pixels we can template in one go
    var i: usize = 0;
    while (i < tmpl) : (i += 1) rowbuf[i] = color;
    const tmpl_src = @as([*]const u8, @ptrCast(&rowbuf)); // bytes of the template

    var y: usize = y0;
    while (y < y0 + h) : (y += 1) { // each scanline of the rectangle
        const base = fb.address + y * fb.pitch + x0 * bpp_bytes; // row start address
        var done: usize = 0; // pixels written on this row so far
        while (done < w) { // copy the template across (one pass unless w > tmpl)
            const chunk = @min(w - done, tmpl); // pixels to copy this iteration
            const dst = @as([*]u8, @ptrFromInt(base + done * bpp_bytes))[0 .. chunk * bpp_bytes];
            std.mem.copyForwards(u8, dst, tmpl_src[0 .. chunk * bpp_bytes]);
            done += chunk;
        }
    }
}

// Paint every pixel with the background color (no cursor/state changes).
fn blankScreen() void {
    fillRect(0, 0, fb.width, fb.height, bg); // one bulk fill of the whole screen
    cursor_drawn = false; // the old cursor underline is gone with the cleared pixels
}

// --- Scrollback grid helpers -------------------------------------------------
fn slotOf(abs: usize) usize {
    return abs % SB_LINES; // physical grid row backing an absolute line index
}
fn absLine() usize {
    return top_abs + cur_y; // absolute index of the line the cursor sits on
}
fn oldestAbs() usize {
    // Once more than SB_LINES lines exist, the earliest have been overwritten.
    return if (max_abs + 1 > SB_LINES) max_abs + 1 - SB_LINES else 0;
}
fn clearGridLine(abs: usize) void {
    const row = &grid[slotOf(abs)]; // blank one stored line to spaces
    var i: usize = 0;
    while (i < MAX_COLS) : (i += 1) row[i] = ' ';
}

// ESC[2J : clear the visible screen but KEEP the scrollback. The current content
// stays in the grid as history and a fresh blank screen begins just past it, so
// PageUp can still reveal everything that was on screen before the clear (how
// modern terminals treat `clear`).
fn clear() void {
    blankScreen(); // wipe the pixels
    top_abs = max_abs + 1; // start the live window on fresh lines after all history
    cur_x = 0;
    cur_y = 0;
    clearGridLine(absLine()); // the new current line starts blank
    if (absLine() > max_abs) max_abs = absLine();
}

// Draw glyph `c` into text cell (col, row).
//
// Hot path: one glyph is drawn per printed character, font.width * font.height
// pixels (128 for our 8x16 font). The old code did one volatile putpixel per
// pixel, recomputing the byte offset (y*pitch + x*bpp) every store. Here we
// build the glyph row's pixels in a small stack buffer (foreground where the
// bit is set, background otherwise) and write the whole row as ONE contiguous
// span via copyForwards, recomputing the offset only once per row.
fn drawGlyph(c: u8, col: usize, row: usize) void {
    const gi: usize = if (c < font.count) c else '?'; // fall back to '?' if missing
    const glyph = font.glyphs[gi * font.bytes_per_glyph ..]; // start of this glyph
    const bpp_bytes = fb.bpp / 8; // bytes per pixel (4 at 32 bpp)
    const px = col * font.width; // pixel x of the cell
    const py = row * font.height; // pixel y of the cell

    // One glyph row is at most font.width pixels (<= 8 here). Buffer it, then
    // blast it to the framebuffer as a single contiguous run.
    var rowbuf: [font.width]u32 = undefined;
    const span = font.width * bpp_bytes; // bytes in one glyph row

    var gy: usize = 0;
    while (gy < font.height) : (gy += 1) { // each row of the glyph
        const bits = glyph[gy * font.bytes_per_row]; // 1 byte (width <= 8)
        var gx: usize = 0;
        while (gx < font.width) : (gx += 1) { // pick fg/bg per column (bit 7 = leftmost)
            rowbuf[gx] = if (bits & (@as(u8, 0x80) >> @intCast(gx)) != 0) fg else bg;
        }
        const base = fb.address + (py + gy) * fb.pitch + px * bpp_bytes; // row start
        const dst = @as([*]u8, @ptrFromInt(base))[0..span];
        std.mem.copyForwards(u8, dst, @as([*]const u8, @ptrCast(&rowbuf))[0..span]);
    }
}

// Slide the on-screen pixels up by one text row and clear the freed bottom row.
// This is the fast live-scroll path (a single framebuffer memmove); the grid
// bookkeeping is handled by the caller.
fn scrollFb() void {
    const row_bytes = fb.pitch * font.height; // bytes in one text row
    const total = fb.pitch * fb.height; // bytes in the whole framebuffer
    const len = total - row_bytes; // bytes to move
    const dst = @as([*]u8, @ptrFromInt(fb.address))[0..len]; // destination = top
    const src = @as([*]u8, @ptrFromInt(fb.address + row_bytes))[0..len]; // source = one row down
    std.mem.copyForwards(u8, dst, src); // move everything up (forward copy is safe here)

    // Clear the freed bottom region with a single bulk row-stride fill instead
    // of a volatile store per pixel.
    const top = (rows - 1) * font.height; // first pixel row of the last text row
    fillRect(0, top, fb.width, fb.height - top, bg);
}

// Advance to the start of the next line. The live window's top advances (and the
// screen scrolls) when we run past the bottom row; the new line is started blank
// in the grid either way. We keep the grid + top_abs current even while the user
// is scrolled up (we just don't repaint), so returning to the bottom is correct.
fn newline() void {
    cur_x = 0;
    cur_y += 1;
    if (cur_y >= rows) { // past the last visible row?
        if (!scrolled) scrollFb(); // repaint only when viewing the live bottom
        top_abs += 1; // the live window's top line advances regardless
        cur_y = rows - 1; // cursor stays on the last row
    }
    const abs = absLine(); // the fresh line the cursor now sits on
    clearGridLine(abs); // start it blank in the grid
    if (abs > max_abs) max_abs = abs; // extend the high-water mark
}

// Write character `ch` into column `col` of the cursor's current line: record it
// in the scrollback grid (the source of truth) and, only when viewing the live
// bottom, paint it immediately.
fn cellPut(col: usize, ch: u8) void {
    if (col >= cols) return; // ignore writes past the recorded line width
    const abs = absLine();
    const row: *[MAX_COLS]u8 = &grid[slotOf(abs)]; // pointer, never copy the grid
    row[col] = ch; // record it
    if (abs > max_abs) max_abs = abs;
    if (!scrolled) drawGlyph(ch, col, cur_y); // live view: draw it now
}

// Redraw one grid line `abs` into screen row `screen_row` (blank if that line is
// beyond the written range or has rolled out of the retained history). We take a
// POINTER to the grid row — indexing `grid[i][col]` by value would copy the whole
// 256 KiB grid onto the stack and blow the thread stack.
fn drawGridRow(abs: usize, screen_row: usize) void {
    const blank = !(abs <= max_abs and abs >= oldestAbs());
    const row: *const [MAX_COLS]u8 = &grid[slotOf(abs)];
    var col: usize = 0;
    while (col < cols) : (col += 1) {
        drawGlyph(if (blank) ' ' else row[col], col, screen_row);
    }
}

// Repaint the whole screen from the grid, showing the window of `rows` lines that
// starts at absolute line `win_top`.
fn renderWindow(win_top: usize) void {
    var r: usize = 0;
    while (r < rows) : (r += 1) drawGridRow(win_top + r, r);
}

// Erase from the cursor to the end of the current line (ESC[K). Goes through
// cellPut so the scrollback grid is updated alongside the pixels.
fn eraseToEol() void {
    var x = cur_x;
    while (x < cols) : (x += 1) cellPut(x, ' ');
}

// Act on a CSI escape sequence's final byte. We implement just enough of an
// ANSI terminal for the shell's line editing: cursor movement, erase-to-EOL,
// and clear-screen. Unknown sequences (e.g. colors) are ignored.
fn handleCsi(final: u8, n: usize) void {
    switch (final) {
        'J' => if (n == 2) clear(), // ESC[2J : clear the whole screen
        'H' => { // ESC[H : cursor home
            cur_x = 0;
            cur_y = 0;
        },
        'K' => eraseToEol(), // ESC[K : erase to end of line
        'C' => { // ESC[nC : cursor right by n
            const d = if (n == 0) 1 else n;
            cur_x = @min(cur_x + d, cols - 1);
        },
        'D' => { // ESC[nD : cursor left by n
            const d = if (n == 0) 1 else n;
            cur_x = if (cur_x >= d) cur_x - d else 0;
        },
        else => {}, // ignore anything we don't implement
    }
}

// Handle a single output character (the core of the "terminal").
fn putcharRaw(c: u8) void {
    // ANSI escape parser: ESC [ <digits> <final-byte>.
    switch (esc_state) {
        1 => { // we just saw ESC
            if (c == '[') {
                esc_state = 2; // ESC [ starts a CSI sequence
                csi_param = 0; // reset the numeric parameter
            } else esc_state = 0;
            return;
        },
        2 => { // inside a CSI sequence
            if (c >= '0' and c <= '9') { // accumulate the numeric parameter
                csi_param = csi_param * 10 + (c - '0');
                return;
            }
            if (c == ';') { // multiple params: we only use the last
                csi_param = 0;
                return;
            }
            esc_state = 0; // any other byte is the final byte
            handleCsi(c, csi_param);
            return;
        },
        else => {},
    }
    if (c == 0x1b) { // ESC
        esc_state = 1;
        return;
    }

    switch (c) {
        '\n' => newline(), // line feed
        '\r' => cur_x = 0, // carriage return
        0x08 => { // backspace: move left and erase
            if (cur_x > 0) {
                cur_x -= 1;
                cellPut(cur_x, ' '); // erase the cell (grid + pixels)
            }
        },
        else => {
            if (c >= 0x20) { // printable
                cellPut(cur_x, c); // record + draw it
                cur_x += 1; // advance the cursor
                if (cur_x >= cols) newline(); // wrap at the right edge
            }
        },
    }
}

// --- Cursor ------------------------------------------------------------------
// The cursor is an underline (bottom 2 pixel rows) drawn at the next-character
// cell. Since that cell is always empty until something is typed there, drawing
// and erasing it never disturbs existing text.
fn drawCursor() void {
    const px = cur_x * font.width; // pixel position of the current cell
    const py = cur_y * font.height;
    var y: usize = font.height - 2; // bottom two rows
    while (y < font.height) : (y += 1) {
        var x: usize = 0;
        while (x < font.width) : (x += 1) putpixel(px + x, py + y, fg);
    }
    cursor_col = cur_x; // remember where, so we can erase it later
    cursor_row = cur_y;
    cursor_drawn = true;
}

fn eraseCursor() void {
    if (!cursor_drawn) return; // nothing to erase
    const px = cursor_col * font.width; // the cell where we drew it
    const py = cursor_row * font.height;
    var y: usize = font.height - 2;
    while (y < font.height) : (y += 1) {
        var x: usize = 0;
        while (x < font.width) : (x += 1) putpixel(px + x, py + y, bg);
    }
    cursor_drawn = false;
}

// Called periodically (from the shell loop, not IRQ context) to blink the
// cursor. Uses the timer tick count so the rate is time-accurate regardless of
// how often it's called.
pub fn cursorBlinkTick() void {
    if (!ready) return;
    if (scrolled) return; // no live cursor while viewing history
    const t = pic.ticks();
    if (t -% last_toggle < BLINK_TICKS) return; // not time to toggle yet
    sync.preemptDisable(); // don't let a printing thread cut in mid-draw
    defer sync.preemptEnable();
    last_toggle = t;
    blink_phase = !blink_phase; // flip on/off
    if (blink_phase) drawCursor() else eraseCursor();
}

// --- Public API --------------------------------------------------------------
// Write a string to the framebuffer console.
pub fn writeString(s: []const u8) void {
    if (!ready) return; // ignore until initialized
    sync.preemptDisable(); // atomic w.r.t. other threads drawing to the console
    defer sync.preemptEnable();
    eraseCursor(); // remove the blinking cursor before drawing text over it
    for (s) |c| putcharRaw(c); // it reappears at the new position on the next blink
}

// std.fmt-compatible writer so we get formatting on the framebuffer too.
const ConsoleWriter = std.io.Writer(void, error{}, writeFn);
fn writeFn(_: void, bytes: []const u8) error{}!usize {
    writeString(bytes);
    return bytes.len;
}
const cwriter: ConsoleWriter = .{ .context = {} };

// printf-style print to the framebuffer console.
pub fn print(comptime fmt: []const u8, args: anytype) void {
    std.fmt.format(cwriter, fmt, args) catch unreachable;
}

// --- Scrollback control ------------------------------------------------------
// How many lines one PageUp/PageDown moves: a screenful minus one line, so a
// line of context carries over (the usual terminal feel).
fn page() usize {
    return if (rows > 1) rows - 1 else 1;
}

// Scroll the view UP toward older history by `lines`, repainting from the grid.
// Status goes to the serial log only (serial.note), never onto the screen.
pub fn scrollUpBy(lines: usize) void {
    if (!ready or lines == 0) return;
    sync.preemptDisable();
    defer sync.preemptEnable();
    const oldest = oldestAbs();
    const cur_view = if (scrolled) view_top else top_abs; // where row 0 is right now
    if (cur_view <= oldest) { // already as far back as the buffer goes
        if (!scrolled) { // first scroll on a screen that hasn't filled history yet
            scrolled = true;
            view_top = oldest;
            renderWindow(view_top);
        }
        serial.note("[CON] scrollback: at oldest line\n", .{});
        return;
    }
    view_top = if (cur_view >= oldest + lines) cur_view - lines else oldest;
    scrolled = true;
    renderWindow(view_top);
    serial.note("[CON] scrollback up: {d} line(s) back\n", .{top_abs - view_top});
}

// Scroll the view DOWN toward the live bottom by `lines`. Reaching the bottom
// drops back into live mode (the cursor reappears on the next blink).
pub fn scrollDownBy(lines: usize) void {
    if (!ready or !scrolled or lines == 0) return; // already live: nothing to do
    sync.preemptDisable();
    defer sync.preemptEnable();
    if (view_top + lines >= top_abs) { // would reach (or pass) the live bottom
        scrolled = false;
        renderWindow(top_abs); // restore the live screen from the grid
        serial.note("[CON] scrollback: live (bottom)\n", .{});
    } else {
        view_top += lines;
        renderWindow(view_top);
        serial.note("[CON] scrollback up: {d} line(s) back\n", .{top_abs - view_top});
    }
}

// Page Up / Page Down: move a full screenful (minus a line of context). The
// mouse wheel uses scrollUpBy/scrollDownBy directly with a small line count.
pub fn scrollUp() void {
    scrollUpBy(page());
}
pub fn scrollDown() void {
    scrollDownBy(page());
}

// Snap straight back to the live bottom (called when the user types, so they
// always see their own input). A no-op when already live.
pub fn scrollToBottom() void {
    if (!ready or !scrolled) return;
    sync.preemptDisable();
    defer sync.preemptEnable();
    scrolled = false;
    renderWindow(top_abs);
}

// Set up the console over a given framebuffer.
pub fn init(info: FramebufferInfo) void {
    fb = info; // remember the framebuffer
    cols = fb.width / font.width; // text grid size
    rows = fb.height / font.height;
    // The scrollback grid is fixed-size, so clamp the text dimensions to it.
    // (Real framebuffers here are far under these caps; this is a safety net.)
    if (cols > MAX_COLS) cols = MAX_COLS;
    if (rows > SB_LINES) rows = SB_LINES;
    fg = makeColor(0xc0, 0xc0, 0xc0); // light grey text
    bg = makeColor(0x0a, 0x0a, 0x0a); // near-black background

    // Start the scrollback grid blank and the live window at the very top.
    var l: usize = 0;
    while (l < SB_LINES) : (l += 1) clearGridLine(l);
    top_abs = 0;
    max_abs = 0;
    cur_x = 0;
    cur_y = 0;
    scrolled = false;
    view_top = 0;
    blankScreen(); // blank the pixels (state is already homed)
    ready = true; // now usable

    serial.print("[CON]   scrollback: {d} lines retained (PageUp/PageDown to scroll)\n", .{SB_LINES});

    // Draw a banner straight to the framebuffer so there's something to see.
    print("Obsidia framebuffer console ({d}x{d}, {d}x{d} font)\n", .{ fb.width, fb.height, font.width, font.height });
    print("--------------------------------------------------\n", .{});

    serial.print("[CON] Framebuffer console initialized.\n", .{});
}

// --- Unit tests (run with `zig build test`) ---------------------------------
test "embedded PSF font parses to an 8x16 256-glyph font" {
    const t = @import("std").testing;
    try t.expectEqual(@as(usize, 8), font.width);
    try t.expectEqual(@as(usize, 16), font.height);
    try t.expect(font.count >= 256);
    try t.expectEqual(@as(usize, 1), font.bytes_per_row); // 8 px wide -> 1 byte/row
    try t.expectEqual(font.count * font.bytes_per_glyph, font.glyphs.len); // no truncation
}

test "parsePsf handles a synthetic PSF2 header" {
    const t = @import("std").testing;
    // PSF2: magic, version, headersize=32, flags=0, count=1, charsize=16,
    // height=16, width=8, then one 16-byte glyph.
    const data = [_]u8{
        0x72, 0xb5, 0x4a, 0x86, // magic
        0, 0, 0, 0, // version
        32, 0, 0, 0, // headersize
        0, 0, 0, 0, // flags
        1, 0, 0, 0, // glyph count
        16, 0, 0, 0, // bytes per glyph
        16, 0, 0, 0, // height
        8, 0, 0, 0, // width
    } ++ [_]u8{0} ** 16; // one glyph
    const f = parsePsf(&data);
    try t.expectEqual(@as(usize, 8), f.width);
    try t.expectEqual(@as(usize, 16), f.height);
    try t.expectEqual(@as(usize, 1), f.count);
    try t.expectEqual(@as(usize, 16), f.glyphs.len);
}
