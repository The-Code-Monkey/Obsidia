// PS/2 mouse driver — just enough to turn the scroll wheel into console
// scrollback. We don't track a cursor (there's nothing on screen to move yet):
// we only care about the wheel, which on an "IntelliMouse" arrives as a fourth
// byte in each movement packet.
//
// The mouse shares the 8042 controller with the keyboard, on the "auxiliary"
// port. Two things make that sharing dangerous, and this driver is built around
// them:
//
//   1. Enabling the mouse means read-modify-writing the controller's *command
//      byte*, which also holds the keyboard's enable bits. A bad read written
//      back would kill the keyboard — so we FORCE the keyboard's bits to
//      known-good values, and bail (touching nothing) if we can't read it.
//   2. Keyboard and mouse bytes share one output buffer, distinguished by the
//      AUX status bit. Each IRQ handler consumes only its own bytes and leaves
//      the other's, so neither starves the other.

const serial = @import("serial.zig"); // port I/O + logging
const pic = @import("../arch/pic.zig"); // register the IRQ12 handler
const console = @import("console.zig"); // scrollUp/scrollDown — where the wheel goes

const DATA: u16 = 0x60; // 8042 data port (shared with the keyboard)
const STATUS: u16 = 0x64; // 8042 status (read) / command (write) port

// Status-register bits.
const OBF: u8 = 0x01; // output buffer full: a byte is ready to read from DATA
const IBF: u8 = 0x02; // input buffer full: the controller hasn't consumed our last write
const AUX: u8 = 0x20; // the pending byte came from the mouse, not the keyboard

// Controller command-byte bits (read with 0x20, written with 0x60).
const CB_KBD_INT: u8 = 0x01; // keyboard generates IRQ1
const CB_AUX_INT: u8 = 0x02; // mouse generates IRQ12
const CB_KBD_DISABLE: u8 = 0x10; // 1 = keyboard clock disabled
const CB_AUX_DISABLE: u8 = 0x20; // 1 = mouse clock disabled
const CB_TRANSLATE: u8 = 0x40; // 1 = translate scancodes to set 1 (our keyboard assumes this)

var has_wheel: bool = false; // did the IntelliMouse handshake enable the Z (wheel) byte?
var ready: bool = false; // true once init() succeeded

// --- 8042 access helpers (all bounded so a quirky controller can't hang us) ---
fn waitWrite() bool {
    var spins: u32 = 0;
    while (serial.inb(STATUS) & IBF != 0) : (spins += 1) { // wait for the input buffer to drain
        if (spins > 100_000) return false;
    }
    return true;
}
fn waitRead() bool {
    var spins: u32 = 0;
    while (serial.inb(STATUS) & OBF == 0) : (spins += 1) { // wait for a byte to appear
        if (spins > 100_000) return false;
    }
    return true;
}
fn ctrlCmd(cmd: u8) void { // command to the controller itself (port 0x64)
    _ = waitWrite();
    serial.outb(STATUS, cmd);
}
fn ctrlWrite(data: u8) void { // data byte to the controller (port 0x60)
    _ = waitWrite();
    serial.outb(DATA, data);
}
fn readByte() ?u8 { // read a byte, or null on timeout
    if (!waitRead()) return null;
    return serial.inb(DATA);
}
fn flush() void { // discard any bytes sitting in the output buffer
    var spins: u32 = 0;
    while (serial.inb(STATUS) & OBF != 0 and spins < 64) : (spins += 1) {
        _ = serial.inb(DATA);
    }
}
// Send one byte to the MOUSE (0xD4 = "forward the next data byte to the mouse")
// and swallow its 0xFA ACK.
fn mouseSend(byte: u8) void {
    ctrlCmd(0xD4);
    ctrlWrite(byte);
    _ = readByte(); // ACK (0xFA)
}

// --- IRQ12: movement/wheel packets -------------------------------------------
// Packets are 3 bytes (no wheel) or 4 bytes (wheel). byte0 has bit 3 always set;
// we use that as a sync check. We only look at the 4th byte (Z = wheel delta);
// movement and buttons are ignored.
var packet: [4]u8 = undefined;
var index: usize = 0;

fn onIrq() void {
    while (true) {
        const status = serial.inb(STATUS);
        if (status & OBF == 0) break; // nothing buffered
        if (status & AUX == 0) break; // next byte is the keyboard's — leave it for IRQ1
        const byte = serial.inb(DATA);

        if (index == 0 and (byte & 0x08) == 0) continue; // not a valid byte0 (bit3=1): resync
        packet[index] = byte;
        index += 1;

        const size: usize = if (has_wheel) 4 else 3;
        if (index < size) continue; // packet incomplete
        index = 0; // full packet assembled

        if (has_wheel) {
            // byte3 is a signed wheel delta (one notch -> +/-1). Map a notch to a
            // page of scrollback. NOTE: the sign convention here is a guess for
            // QEMU; if the wheel scrolls the wrong way, swap scrollUp/scrollDown.
            const z: i8 = @bitCast(packet[3]);
            if (z < 0) {
                console.scrollUp(); // wheel up -> older output
            } else if (z > 0) {
                console.scrollDown(); // wheel down -> toward the live bottom
            }
        }
    }
}

// --- Init --------------------------------------------------------------------
pub fn init() void {
    serial.print("[MOUSE] Initializing PS/2 mouse...\n", .{});

    // Mask interrupts for the whole polling handshake. Otherwise the keyboard's
    // IRQ1 handler races us: requesting a controller byte (e.g. the config byte)
    // fills the shared output buffer with AUX clear, which looks exactly like a
    // keyboard byte and raises IRQ1 — so keyboard.onIrq would read (steal) the
    // reply before our poll sees it. With interrupts off, only our polling reads
    // the controller. (We re-enable below, after IRQ12 is wired up.)
    asm volatile ("cli");
    defer asm volatile ("sti");

    flush(); // clear any stale byte so the config read below isn't polluted
    ctrlCmd(0xA8); // enable the auxiliary (mouse) device
    flush();

    // Read-modify-write the controller command byte. If we can't read it, leave
    // the controller completely untouched rather than risk the keyboard.
    ctrlCmd(0x20); // request the command byte
    var cb = readByte() orelse {
        serial.print("[MOUSE] could not read 8042 config byte; mouse disabled (keyboard untouched).\n", .{});
        return;
    };
    // FORCE the keyboard-critical bits to known-good values so even a wrong read
    // cannot disable the keyboard; enable the mouse interrupt + clock alongside.
    cb |= CB_KBD_INT; // keep keyboard IRQ1 on
    cb |= CB_TRANSLATE; // keep scancode translation on (our keyboard decodes set 1)
    cb &= ~CB_KBD_DISABLE; // keep the keyboard clock enabled
    cb |= CB_AUX_INT; // turn on mouse IRQ12
    cb &= ~CB_AUX_DISABLE; // turn on the mouse clock
    ctrlCmd(0x60); // write the command byte back...
    ctrlWrite(cb);

    mouseSend(0xF6); // load sane defaults

    // IntelliMouse handshake: the sample-rate sequence 200, 100, 80 switches a
    // wheel mouse to 4-byte packets; "get device ID" then returns 3 if the wheel
    // is active (0 = a plain 3-button mouse).
    mouseSend(0xF3);
    mouseSend(200);
    mouseSend(0xF3);
    mouseSend(100);
    mouseSend(0xF3);
    mouseSend(80);
    mouseSend(0xF2); // get device ID (ACK swallowed by mouseSend)
    const id = readByte() orelse 0; // the ID byte follows the ACK
    has_wheel = (id == 0x03);

    mouseSend(0xF4); // enable data reporting (start sending packets)
    flush(); // drop any stray byte before interrupts take over

    index = 0;
    pic.register(12, &onIrq); // route IRQ12 to us and unmask it
    ready = true;
    serial.print("[MOUSE] Mouse ready (IRQ12), wheel {s} (device id {d}).\n", .{ if (has_wheel) "enabled" else "absent", id });
}
