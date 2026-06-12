// COM1 serial-port driver. Serial is our primary debugging channel: every
// subsystem prints its state here, and QEMU captures it to a log file. This
// file talks to the legacy 16550 UART through x86 port I/O.

const std = @import("std"); // standard library, used for std.fmt + std.io.Writer
const sync = @import("../sched/sync.zig"); // the print lock (preemption disable)

// COM1's base I/O port. The UART exposes 8 consecutive registers at PORT..PORT+7.
const PORT: u16 = 0x3F8;

// Write one byte to an I/O port. `inline` so the OUT instruction is emitted
// directly at the call site (no function-call overhead in this hot path).
pub inline fn outb(port: u16, data: u8) void {
    // AT&T-syntax inline assembly: `outb %al, %dx` writes AL to the port in DX.
    asm volatile ("outb %al, %dx"
        : // no outputs
        : [data] "{al}" (data), // put `data` in AL
          [port] "{dx}" (port), // put `port` in DX
    );
}

// Write one 16-bit word to an I/O port (used for the ACPI poweroff register).
pub inline fn outw(port: u16, data: u16) void {
    asm volatile ("outw %ax, %dx"
        : // no outputs
        : [data] "{ax}" (data), // put `data` in AX
          [port] "{dx}" (port), // put `port` in DX
    );
}

// Read one byte from an I/O port and return it.
pub inline fn inb(port: u16) u8 {
    var data: u8 = undefined; // destination for the byte we read
    // `inb %dx, %al` reads the port in DX into AL.
    asm volatile ("inb %dx, %al"
        : [data] "={al}" (data), // capture AL into `data`
        : [port] "{dx}" (port), // port number goes in DX
    );
    return data; // hand the byte back to the caller
}

// Program the UART into a usable state: 38400 baud, 8N1, FIFOs on.
pub fn init() void {
    outb(PORT + 1, 0x00); // IER: disable all UART interrupts (we poll instead)
    outb(PORT + 3, 0x80); // LCR: set DLAB=1 so the next two writes set the divisor
    outb(PORT + 0, 0x03); // divisor low byte = 3  -> 115200/3 = 38400 baud
    outb(PORT + 1, 0x00); // divisor high byte = 0
    outb(PORT + 3, 0x03); // LCR: DLAB=0, 8 data bits, no parity, 1 stop bit (8N1)
    outb(PORT + 2, 0xC7); // FCR: enable+clear FIFOs, 14-byte interrupt threshold
    outb(PORT + 4, 0x0B); // MCR: assert RTS/DSR and enable the OUT2 line
}

// Is the transmit holding register empty (ready to accept the next byte)?
fn isTransmitEmpty() bool {
    // LSR (line status register) is at PORT+5; bit 5 (0x20) = transmitter empty.
    return (inb(PORT + 5) & 0x20) != 0;
}

// Send a single byte, busy-waiting until the UART can accept it.
fn writeByte(b: u8) void {
    while (!isTransmitEmpty()) {} // spin until the transmit register drains
    outb(PORT, b); // write the byte to the data register (PORT+0)
}

// --- Zig std.fmt integration -------------------------------------------------
// Wrapping the UART in a std.io.Writer lets us reuse std.fmt's formatter, so we
// get printf-style formatting (`{d}`, `{x}`, `{s}`, ...) for free.

// A Writer whose context is `void` (we keep no state), never errors, and sends
// bytes through writeFn.
const SerialWriter = std.io.Writer(void, error{}, writeFn);

// The Writer's sink: push every byte of the slice out the serial port.
fn writeFn(_: void, bytes: []const u8) error{}!usize {
    for (bytes) |b| { // iterate each byte to send
        writeByte(b); // transmit it
    }
    if (mirror) |m| m(bytes); // ...and mirror to the framebuffer console if registered
    return bytes.len; // report that we consumed the whole slice
}

// A single shared Writer instance (its context is the empty value `{}`).
const writer: SerialWriter = .{ .context = {} };

// Optional mirror: if set, every byte we transmit is also forwarded here. The
// framebuffer console registers itself, so all serial output also appears on
// screen — with no changes to the code doing the printing.
var mirror: ?*const fn ([]const u8) void = null;

// Register (or clear) the mirror sink.
pub fn setMirror(f: ?*const fn ([]const u8) void) void {
    mirror = f;
}

// Public printf-style logger used everywhere in the kernel. Holds the print lock
// so a thread can't be preempted mid-line (which would interleave output).
pub fn print(comptime format: []const u8, args: anytype) void {
    sync.preemptDisable();
    defer sync.preemptEnable();
    // Format into the serial writer; our writeFn can't fail, so `catch unreachable`.
    std.fmt.format(writer, format, args) catch unreachable;
}

// A Writer that goes ONLY to the UART, never to the mirror.
const SerialOnlyWriter = std.io.Writer(void, error{}, writeOnlyFn);
fn writeOnlyFn(_: void, bytes: []const u8) error{}!usize {
    for (bytes) |b| writeByte(b); // transmit each byte, but do NOT mirror
    return bytes.len;
}
const note_writer: SerialOnlyWriter = .{ .context = {} };

// Like print(), but writes ONLY to the serial log — it deliberately does NOT
// mirror to the framebuffer console. Used for messages that would be on-screen
// noise (e.g. the console's own scrollback status line) yet should still be
// captured in the serial log. Bypassing the mirror also avoids re-entering the
// console from inside the console's own code.
pub fn note(comptime format: []const u8, args: anytype) void {
    sync.preemptDisable();
    defer sync.preemptEnable();
    std.fmt.format(note_writer, format, args) catch unreachable;
}

// --- Input (RX), used by the serial shell ------------------------------------

// Is there a received byte waiting in the UART receive register?
pub inline fn dataAvailable() bool {
    return (inb(PORT + 5) & 0x01) != 0; // LSR bit 0 = "data ready"
}

// Read one received byte from the UART data register. Reading it also clears
// the pending "received data available" interrupt.
pub inline fn readByteRaw() u8 {
    return inb(PORT);
}

// Enable the "received data available" interrupt, so COM1 raises IRQ4 when a
// byte arrives (init() left all UART interrupts disabled).
pub fn enableRxInterrupt() void {
    outb(PORT + 1, 0x01); // IER bit 0
}

// Echo a single character to the port (used by the shell's line editor).
pub fn putc(c: u8) void {
    sync.preemptDisable();
    defer sync.preemptEnable();
    writeByte(c); // out the serial port
    if (mirror) |m| { // and to the framebuffer console, if registered
        const tmp = [_]u8{c};
        m(&tmp);
    }
}
