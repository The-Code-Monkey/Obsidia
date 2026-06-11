// PS/2 keyboard driver: turns key presses into ASCII bytes.
//
// The 8042 controller raises IRQ1 when a key is pressed or released and puts a
// "scancode" in port 0x60. We decode scancode set 1 (the default QEMU delivers):
// make codes 0x01..0x58 for presses, the same code | 0x80 for releases, and a
// 0xE0 prefix for the extended keys (arrows, etc.). Decoded characters are handed
// to a sink callback (the shell registers its input buffer).

const serial = @import("serial.zig"); // for port I/O (inb) and logging
const pic = @import("../arch/pic.zig"); // to register the IRQ1 handler

const DATA: u16 = 0x60; // PS/2 data port (scancodes appear here)
const STATUS: u16 = 0x64; // PS/2 status/command port

// Scancode-set-1 -> ASCII, unshifted. Index = make code; 0 means "no character".
const map = blk: {
    var m = [_]u8{0} ** 128;
    m[0x02] = '1'; m[0x03] = '2'; m[0x04] = '3'; m[0x05] = '4'; m[0x06] = '5';
    m[0x07] = '6'; m[0x08] = '7'; m[0x09] = '8'; m[0x0A] = '9'; m[0x0B] = '0';
    m[0x0C] = '-'; m[0x0D] = '='; m[0x0E] = 8; m[0x0F] = '\t'; // - = Backspace Tab
    m[0x10] = 'q'; m[0x11] = 'w'; m[0x12] = 'e'; m[0x13] = 'r'; m[0x14] = 't';
    m[0x15] = 'y'; m[0x16] = 'u'; m[0x17] = 'i'; m[0x18] = 'o'; m[0x19] = 'p';
    m[0x1A] = '['; m[0x1B] = ']'; m[0x1C] = '\n'; // [ ] Enter
    m[0x1E] = 'a'; m[0x1F] = 's'; m[0x20] = 'd'; m[0x21] = 'f'; m[0x22] = 'g';
    m[0x23] = 'h'; m[0x24] = 'j'; m[0x25] = 'k'; m[0x26] = 'l';
    m[0x27] = ';'; m[0x28] = '\''; m[0x29] = '`';
    m[0x2B] = '\\';
    m[0x2C] = 'z'; m[0x2D] = 'x'; m[0x2E] = 'c'; m[0x2F] = 'v'; m[0x30] = 'b';
    m[0x31] = 'n'; m[0x32] = 'm';
    m[0x33] = ','; m[0x34] = '.'; m[0x35] = '/';
    m[0x37] = '*'; m[0x39] = ' '; // keypad * and Space
    break :blk m;
};

// The same keys with Shift held.
const map_shift = blk: {
    var m = [_]u8{0} ** 128;
    m[0x02] = '!'; m[0x03] = '@'; m[0x04] = '#'; m[0x05] = '$'; m[0x06] = '%';
    m[0x07] = '^'; m[0x08] = '&'; m[0x09] = '*'; m[0x0A] = '('; m[0x0B] = ')';
    m[0x0C] = '_'; m[0x0D] = '+'; m[0x0E] = 8; m[0x0F] = '\t';
    m[0x10] = 'Q'; m[0x11] = 'W'; m[0x12] = 'E'; m[0x13] = 'R'; m[0x14] = 'T';
    m[0x15] = 'Y'; m[0x16] = 'U'; m[0x17] = 'I'; m[0x18] = 'O'; m[0x19] = 'P';
    m[0x1A] = '{'; m[0x1B] = '}'; m[0x1C] = '\n';
    m[0x1E] = 'A'; m[0x1F] = 'S'; m[0x20] = 'D'; m[0x21] = 'F'; m[0x22] = 'G';
    m[0x23] = 'H'; m[0x24] = 'J'; m[0x25] = 'K'; m[0x26] = 'L';
    m[0x27] = ':'; m[0x28] = '"'; m[0x29] = '~';
    m[0x2B] = '|';
    m[0x2C] = 'Z'; m[0x2D] = 'X'; m[0x2E] = 'C'; m[0x2F] = 'V'; m[0x30] = 'B';
    m[0x31] = 'N'; m[0x32] = 'M';
    m[0x33] = '<'; m[0x34] = '>'; m[0x35] = '?';
    m[0x37] = '*'; m[0x39] = ' ';
    break :blk m;
};

// Modifier / state tracking.
var shift = false; // either Shift key currently held
var caps = false; // Caps Lock toggle
var extended = false; // saw a 0xE0 prefix (next byte is an extended key)

// Where decoded characters go (the shell's input buffer).
var sink: ?*const fn (u8) void = null;
pub fn setSink(f: *const fn (u8) void) void {
    sink = f;
}

// Send a multi-byte sequence to the sink (used for escape sequences).
fn emit(seq: []const u8) void {
    if (sink) |s| {
        for (seq) |b| s(b);
    }
}

// Translate an extended (0xE0-prefixed) make code into the ANSI escape sequence
// a terminal would send, so the shell can parse keyboard and serial input the
// same way.
fn emitExtended(code: u8) void {
    switch (code) {
        0x48 => emit("\x1b[A"), // Up
        0x50 => emit("\x1b[B"), // Down
        0x4D => emit("\x1b[C"), // Right
        0x4B => emit("\x1b[D"), // Left
        0x47 => emit("\x1b[H"), // Home
        0x4F => emit("\x1b[F"), // End
        0x53 => emit("\x1b[3~"), // Delete (forward)
        else => {}, // ignore other extended keys
    }
}

// Translate a make code to a character, applying Shift and Caps Lock.
fn translate(code: u8) u8 {
    if (code >= 128) return 0; // out of table range
    const base = map[code]; // unshifted character
    if (base == 0) return 0; // unmapped key
    const is_letter = base >= 'a' and base <= 'z';
    // Letters: upper-case when Shift XOR Caps. Others: shifted only when Shift.
    const upper = if (is_letter) (shift != caps) else shift;
    return if (upper) map_shift[code] else base;
}

// Decode one scancode and, if it produces a character, hand it to the sink.
fn handle(sc: u8) void {
    if (sc == 0xE0) { // extended-key prefix
        extended = true;
        return;
    }
    const released = (sc & 0x80) != 0; // high bit set = key release
    const code = sc & 0x7F; // strip the release bit to get the make code

    if (extended) { // arrows / Home / End / Delete
        extended = false;
        if (!released) emitExtended(code); // emit on press only
        return;
    }

    switch (code) {
        0x2A, 0x36 => { // left / right Shift
            shift = !released; // held while pressed
            return;
        },
        0x3A => { // Caps Lock
            if (!released) caps = !caps; // toggles on press only
            return;
        },
        else => {},
    }

    if (released) return; // we only emit characters on key press

    const c = translate(code); // map to ASCII
    if (c != 0) {
        if (sink) |s| s(c); // deliver it
    }
}

// IRQ1 handler: read the scancode and decode it.
fn onIrq() void {
    const sc = serial.inb(DATA);
    handle(sc);
}

pub fn init() void {
    serial.print("[KBD] Initializing PS/2 keyboard...\n", .{});
    // Drain any bytes the controller already has queued, so a stale scancode
    // doesn't fire IRQ1 immediately.
    while (serial.inb(STATUS) & 0x01 != 0) {
        _ = serial.inb(DATA);
    }
    pic.register(1, &onIrq); // route IRQ1 to us and unmask it
    serial.print("[KBD] Keyboard ready (IRQ1).\n", .{});
}

// --- Unit tests (run with `zig build test`) ---------------------------------
test "unshifted letters and digits" {
    const t = @import("std").testing;
    shift = false;
    caps = false;
    try t.expectEqual(@as(u8, 'a'), translate(0x1E)); // A key
    try t.expectEqual(@as(u8, 'z'), translate(0x2C)); // Z key
    try t.expectEqual(@as(u8, '1'), translate(0x02)); // 1 key
    try t.expectEqual(@as(u8, ' '), translate(0x39)); // Space
}

test "shift gives capitals and shifted symbols" {
    const t = @import("std").testing;
    shift = true;
    caps = false;
    try t.expectEqual(@as(u8, 'A'), translate(0x1E)); // shift+A
    try t.expectEqual(@as(u8, '!'), translate(0x02)); // shift+1
    try t.expectEqual(@as(u8, '?'), translate(0x35)); // shift+/
    shift = false; // restore
}

test "caps lock affects letters only" {
    const t = @import("std").testing;
    shift = false;
    caps = true;
    try t.expectEqual(@as(u8, 'A'), translate(0x1E)); // caps -> A
    try t.expectEqual(@as(u8, '1'), translate(0x02)); // caps doesn't shift digits
    caps = false; // restore
}

test "shift and caps cancel for letters" {
    const t = @import("std").testing;
    shift = true;
    caps = true;
    try t.expectEqual(@as(u8, 'a'), translate(0x1E)); // shift XOR caps = lowercase
    shift = false;
    caps = false;
}

test "extended arrow keys emit escape sequences" {
    const t = @import("std").testing;
    const Capture = struct {
        var buf: [8]u8 = undefined;
        var len: usize = 0;
        fn reset() void {
            len = 0;
        }
        fn sinkFn(c: u8) void {
            buf[len] = c;
            len += 1;
        }
    };
    setSink(&Capture.sinkFn);
    Capture.reset();
    handle(0xE0); // extended prefix
    handle(0x48); // Up arrow (press)
    try t.expectEqualStrings("\x1b[A", Capture.buf[0..Capture.len]);
}
