const std = @import("std");

// The standard base address for the COM1 serial port
const PORT: u16 = 0x3F8;

// Write a single byte to an I/O port using inline assembly
inline fn outb(port: u16, data: u8) void {
    asm volatile ("outb %[data], %[port]"
        :
        : [data] "{al}" (data),
          [port] "{N{dx}}" (port),
    );
}

// Read a single byte from an I/O port
inline fn inb(port: u16) u8 {
    var data: u8 = undefined;
    asm volatile ("inb %[port], %[data]"
        : [data] "={al}" (data),
        : [port] "{N{dx}}" (port),
    );
    return data;
}

pub fn init() void {
    outb(PORT + 1, 0x00); // Disable all interrupts
    outb(PORT + 3, 0x80); // Enable DLAB (set baud rate divisor)
    outb(PORT + 0, 0x03); // Set divisor to 3 (lo byte) 38400 baud
    outb(PORT + 1, 0x00); //                  (hi byte)
    outb(PORT + 3, 0x03); // 8 bits, no parity, one stop bit
    outb(PORT + 2, 0xC7); // Enable FIFO, clear them, with 14-byte threshold
    outb(PORT + 4, 0x0B); // IRQs enabled, RTS/DSR set
}

// Check if the transmit buffer is empty and ready for the next byte
fn isTransmitEmpty() bool {
    return (inb(PORT + 5) & 0x20) != 0;
}

// Push a single character to the serial port
fn writeByte(b: u8) void {
    while (!isTransmitEmpty()) {}
    outb(PORT, b);
}

// --- Zig std.fmt Integration ---

// Create a custom Writer interface so we can use std.fmt.format
const SerialWriter = std.io.Writer(void, error{}, writeFn);

fn writeFn(_: void, bytes: []const u8) error{}!usize {
    for (bytes) |b| {
        writeByte(b);
    }
    return bytes.len;
}

const writer: SerialWriter = .{ .context = {} };

// A convenient public print function that accepts formatting arguments
pub fn print(comptime format: []const u8, args: anytype) void {
    std.fmt.format(writer, format, args) catch unreachable;
}
