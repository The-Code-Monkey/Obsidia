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
var cur_y: usize = 0; // cursor row
var fg: u32 = 0; // foreground pixel value
var bg: u32 = 0; // background pixel value
var ready: bool = false; // true once init() has run
var esc_state: u8 = 0; // ANSI escape parser: 0=normal, 1=saw ESC, 2=in CSI
var csi_param: usize = 0; // numeric parameter accumulated in a CSI sequence

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

// Fill the whole screen with the background color and home the cursor.
fn clear() void {
    var y: usize = 0;
    while (y < fb.height) : (y += 1) { // every scanline
        var x: usize = 0;
        while (x < fb.width) : (x += 1) putpixel(x, y, bg); // every pixel
    }
    cur_x = 0;
    cur_y = 0;
    cursor_drawn = false; // the old cursor underline is gone with the cleared screen
}

// Draw glyph `c` into text cell (col, row).
fn drawGlyph(c: u8, col: usize, row: usize) void {
    const gi: usize = if (c < font.count) c else '?'; // fall back to '?' if missing
    const glyph = font.glyphs[gi * font.bytes_per_glyph ..]; // start of this glyph
    const px = col * font.width; // pixel x of the cell
    const py = row * font.height; // pixel y of the cell
    var gy: usize = 0;
    while (gy < font.height) : (gy += 1) { // each row of the glyph
        const bits = glyph[gy * font.bytes_per_row]; // 1 byte (width <= 8)
        var gx: usize = 0;
        while (gx < font.width) : (gx += 1) { // each column
            const on = (bits & (@as(u8, 0x80) >> @intCast(gx))) != 0; // bit 7 = leftmost
            putpixel(px + gx, py + gy, if (on) fg else bg); // foreground or background
        }
    }
}

// Scroll the whole screen up by one text row and clear the new bottom row.
fn scroll() void {
    const row_bytes = fb.pitch * font.height; // bytes in one text row
    const total = fb.pitch * fb.height; // bytes in the whole framebuffer
    const len = total - row_bytes; // bytes to move
    const dst = @as([*]u8, @ptrFromInt(fb.address))[0..len]; // destination = top
    const src = @as([*]u8, @ptrFromInt(fb.address + row_bytes))[0..len]; // source = one row down
    std.mem.copyForwards(u8, dst, src); // move everything up (forward copy is safe here)

    var y: usize = (rows - 1) * font.height; // first pixel row of the last text row
    while (y < fb.height) : (y += 1) { // clear the freed bottom row
        var x: usize = 0;
        while (x < fb.width) : (x += 1) putpixel(x, y, bg);
    }
}

// Advance to the start of the next line, scrolling if we're at the bottom.
fn newline() void {
    cur_x = 0;
    cur_y += 1;
    if (cur_y >= rows) { // past the last row?
        scroll();
        cur_y = rows - 1; // stay on the last row
    }
}

// Clear one text cell to the background color.
fn clearCell(col: usize, row: usize) void {
    const px = col * font.width;
    const py = row * font.height;
    var gy: usize = 0;
    while (gy < font.height) : (gy += 1) {
        var gx: usize = 0;
        while (gx < font.width) : (gx += 1) putpixel(px + gx, py + gy, bg);
    }
}

// Erase from the cursor to the end of the current line (ESC[K).
fn eraseToEol() void {
    var x = cur_x;
    while (x < cols) : (x += 1) clearCell(x, cur_y);
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
                drawGlyph(' ', cur_x, cur_y);
            }
        },
        else => {
            if (c >= 0x20) { // printable
                drawGlyph(c, cur_x, cur_y); // draw it
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

// Set up the console over a given framebuffer.
pub fn init(info: FramebufferInfo) void {
    serial.print("[CON] Initializing framebuffer console...\n", .{});
    fb = info; // remember the framebuffer
    cols = fb.width / font.width; // text grid size
    rows = fb.height / font.height;
    fg = makeColor(0xc0, 0xc0, 0xc0); // light grey text
    bg = makeColor(0x0a, 0x0a, 0x0a); // near-black background
    clear(); // blank the screen
    ready = true; // now usable

    serial.print("[CON]   fb=0x{x} {d}x{d}, pitch={d}, bpp={d}\n", .{ fb.address, fb.width, fb.height, fb.pitch, fb.bpp });
    serial.print("[CON]   font {d}x{d}, grid {d}x{d} chars\n", .{ font.width, font.height, cols, rows });

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
