// A tiny nano-style text editor.
//
// It loads a file into a fixed buffer, lets you move around and type, and saves
// back to the FAT32 disk with `fat32.writeFile`. Rendering is plain ANSI: clear
// the screen, print the text, position the cursor — which works fully over a
// serial terminal (the framebuffer console handles the clear and text, but not
// absolute cursor positioning, so there the blinking cursor sits at the top).
//
// Keys: arrows move; Backspace/Enter/printable edit; Ctrl-S saves; Ctrl-X exits.
// Input comes one byte at a time from a key-reader the shell passes in (the same
// ring the shell reads), so the editor needs no input plumbing of its own.

const serial = @import("drivers/serial.zig");
const fat32 = @import("fs/fat32.zig");

const MAX = 8192; // largest file we edit (8 KiB)
var buf: [MAX]u8 = undefined; // the file contents being edited
var len: usize = 0; // bytes in `buf`
var cur: usize = 0; // cursor position (0..len)
var status: [48]u8 = undefined; // transient status message ("saved", etc.)
var status_len: usize = 0;

fn setStatus(s: []const u8) void {
    const n = @min(s.len, status.len);
    @memcpy(status[0..n], s[0..n]);
    status_len = n;
}

// Insert one byte at the cursor (shifting the tail right). Ignores if full.
fn insert(c: u8) void {
    if (len >= MAX) return;
    var i = len;
    while (i > cur) : (i -= 1) buf[i] = buf[i - 1];
    buf[cur] = c;
    len += 1;
    cur += 1;
}

// Delete the byte before the cursor (Backspace).
fn backspace() void {
    if (cur == 0) return;
    var i = cur - 1;
    while (i < len - 1) : (i += 1) buf[i] = buf[i + 1];
    len -= 1;
    cur -= 1;
}

// Start index of the line containing position `p`.
fn lineStart(p: usize) usize {
    var i = p;
    while (i > 0 and buf[i - 1] != '\n') i -= 1;
    return i;
}
// Index just past the end of the line containing `p` (at the '\n' or len).
fn lineEnd(p: usize) usize {
    var i = p;
    while (i < len and buf[i] != '\n') i += 1;
    return i;
}

fn moveUp() void {
    const start = lineStart(cur);
    if (start == 0) return; // already on the first line
    const col = cur - start;
    const prev_start = lineStart(start - 1); // start - 1 is the previous '\n'
    const prev_len = (start - 1) - prev_start;
    cur = prev_start + @min(col, prev_len);
}
fn moveDown() void {
    const start = lineStart(cur);
    const end = lineEnd(cur);
    if (end >= len) return; // already on the last line
    const col = cur - start;
    const next_start = end + 1;
    const next_len = lineEnd(next_start) - next_start;
    cur = next_start + @min(col, next_len);
}

// Repaint the whole screen from the buffer and place the cursor.
fn redraw(path: []const u8) void {
    serial.print("\x1b[2J\x1b[H", .{}); // clear + home
    serial.print("  edit: {s}   [Ctrl-S save  Ctrl-X exit]", .{path});
    if (status_len > 0) serial.print("   -- {s} --", .{status[0..status_len]});
    serial.print("\r\n", .{});
    serial.print("{s}", .{buf[0..len]}); // the text (line 2 onward)

    // Cursor: count lines/columns up to `cur`. Text starts at terminal row 2.
    var row: usize = 1; // 1-based line number within the text
    var col: usize = 0; // 0-based column
    var i: usize = 0;
    while (i < cur) : (i += 1) {
        if (buf[i] == '\n') {
            row += 1;
            col = 0;
        } else col += 1;
    }
    serial.print("\x1b[{d};{d}H", .{ row + 1, col + 1 });
}

// Open `path` in the editor. `getKey` blocks and returns the next input byte.
pub fn run(path: []const u8, getKey: *const fn () u8) void {
    len = fat32.readFile(path, &buf) orelse 0; // missing file -> start empty (new file)
    cur = 0;
    status_len = 0;
    redraw(path);

    while (true) {
        const k = getKey();
        switch (k) {
            0x18, 0x11 => { // Ctrl-X / Ctrl-Q: exit
                serial.print("\x1b[2J\x1b[H", .{}); // leave a clean screen
                return;
            },
            0x13 => { // Ctrl-S: save
                if (fat32.writeFile(path, buf[0..len])) setStatus("saved") else setStatus("SAVE FAILED");
                redraw(path);
            },
            0x1b => { // ESC: an arrow-key sequence (ESC [ A/B/C/D)
                if (getKey() != '[') continue;
                switch (getKey()) {
                    'A' => moveUp(),
                    'B' => moveDown(),
                    'C' => if (cur < len) {
                        cur += 1;
                    },
                    'D' => if (cur > 0) {
                        cur -= 1;
                    },
                    else => {},
                }
                redraw(path);
            },
            0x08, 0x7f => { // Backspace
                backspace();
                redraw(path);
            },
            '\r', '\n' => {
                insert('\n');
                redraw(path);
            },
            else => if (k >= 0x20 and k < 0x7f) { // printable
                insert(k);
                redraw(path);
            },
        }
    }
}
