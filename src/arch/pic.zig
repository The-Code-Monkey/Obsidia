// 8259 PIC remap + IRQ dispatch, and the 8254 PIT (timer) on IRQ0.
//
// The two cascaded 8259 PICs power-on mapping IRQ0-7 to interrupt vectors
// 0x08-0x0F and IRQ8-15 to 0x70-0x77. The first range collides head-on with
// the CPU exception vectors (IRQ0 would arrive as vector 8, the double fault),
// so before enabling interrupts we MUST remap them out of the way. We move
// master IRQ0-7 -> vectors 32-39 and slave IRQ8-15 -> vectors 40-47, which is
// precisely the range the IDT already populated with stubs.
//
// This module owns the `sti` that first enables maskable interrupts, and wires
// the PIT to a tick counter so we can prove asynchronous interrupts work.

const serial = @import("../drivers/serial.zig"); // for outb/inb and logging

// PIC I/O ports. The master and slave each have a command and a data port.
const MASTER_CMD: u16 = 0x20;
const MASTER_DATA: u16 = 0x21;
const SLAVE_CMD: u16 = 0xA0;
const SLAVE_DATA: u16 = 0xA1;
const EOI: u8 = 0x20; // OCW2: non-specific end-of-interrupt

// PIT (programmable interval timer) I/O ports.
const PIT_CHANNEL0: u16 = 0x40; // channel 0 data port
const PIT_CMD: u16 = 0x43; // mode/command register
const PIT_BASE_FREQ: u32 = 1193182; // the PIT's fixed input clock, in Hz

// Where we relocate the PIC vectors to, and our tick rate.
const VECTOR_OFFSET: u8 = 32; // master IRQ0 -> vector 32
const TIMER_HZ: u32 = 100; // 100 ticks/second (10 ms per tick)

// Short I/O delay by writing the POST diagnostic port; gives older PICs time to
// settle between command writes.
fn ioWait() void {
    serial.outb(0x80, 0); // port 0x80 is a harmless scratch port
}

// --- IRQ mask (OCW1) ---------------------------------------------------------
// Each PIC has an 8-bit mask; a set bit disables that IRQ line.
pub fn setMask(irq: u8) void {
    const port: u16 = if (irq < 8) MASTER_DATA else SLAVE_DATA; // which PIC owns this IRQ
    const bit = @as(u8, 1) << @intCast(irq % 8); // bit within that PIC's mask
    serial.outb(port, serial.inb(port) | bit); // set the bit (mask = disable)
}

pub fn clearMask(irq: u8) void {
    const port: u16 = if (irq < 8) MASTER_DATA else SLAVE_DATA; // which PIC
    const bit = @as(u8, 1) << @intCast(irq % 8); // bit within the mask
    serial.outb(port, serial.inb(port) & ~bit); // clear the bit (unmask = enable)
}

// --- APIC takeover hooks -----------------------------------------------------
// When the APIC driver takes over, it sets these so our dispatch acknowledges
// interrupts at the LAPIC and unmasks them at the I/O APIC instead of the PIC.
// (Hooks rather than an import, to avoid a pic<->apic dependency cycle.)
pub var eoi_hook: ?*const fn () void = null; // LAPIC EOI
pub var route_hook: ?*const fn (u8) void = null; // I/O APIC unmask/route

// Fully mask the PIC (used by the APIC driver to retire it).
pub fn disable() void {
    serial.outb(MASTER_DATA, 0xFF);
    serial.outb(SLAVE_DATA, 0xFF);
}

// Re-route every already-registered IRQ through the new route_hook (the APIC).
pub fn rerouteRegistered() void {
    for (handlers, 0..) |h, i| {
        if (h != null) {
            if (route_hook) |f| f(@intCast(i));
        }
    }
}

// --- End of interrupt --------------------------------------------------------
// The PIC won't deliver another IRQ on a line until it gets an EOI.
fn eoi(irq: u8) void {
    if (eoi_hook) |f| { // APIC active -> EOI goes to the LAPIC
        f();
        return;
    }
    if (irq >= 8) serial.outb(SLAVE_CMD, EOI); // slave first for IRQ8-15
    serial.outb(MASTER_CMD, EOI); // always EOI the master
}

// Read the In-Service Register to distinguish real vs spurious IRQs.
fn readMasterIsr() u8 {
    serial.outb(MASTER_CMD, 0x0B); // OCW3: select ISR for the next read
    return serial.inb(MASTER_CMD); // read it back
}
fn readSlaveIsr() u8 {
    serial.outb(SLAVE_CMD, 0x0B); // select the slave's ISR
    return serial.inb(SLAVE_CMD);
}

// --- Remap (ICW1-ICW4) -------------------------------------------------------
// The 8259 is reprogrammed by writing an initialization command word sequence.
fn remap() void {
    serial.outb(MASTER_CMD, 0x11); // ICW1: begin init, expect ICW4
    ioWait();
    serial.outb(SLAVE_CMD, 0x11); // ICW1 to the slave too
    ioWait();
    serial.outb(MASTER_DATA, VECTOR_OFFSET); // ICW2: master vector offset (32)
    ioWait();
    serial.outb(SLAVE_DATA, VECTOR_OFFSET + 8); // ICW2: slave vector offset (40)
    ioWait();
    serial.outb(MASTER_DATA, 0x04); // ICW3: slave is wired to master IRQ2 (bit 2)
    ioWait();
    serial.outb(SLAVE_DATA, 0x02); // ICW3: slave cascade identity = 2
    ioWait();
    serial.outb(MASTER_DATA, 0x01); // ICW4: 8086/88 mode
    ioWait();
    serial.outb(SLAVE_DATA, 0x01); // ICW4 to the slave
    ioWait();
    serial.outb(MASTER_DATA, 0xFF); // OCW1: mask all master IRQs for now
    ioWait();
    serial.outb(SLAVE_DATA, 0xFF); // mask all slave IRQs for now
    ioWait();
}

// --- PIT ---------------------------------------------------------------------
// Program channel 0 to fire IRQ0 at `hz` times per second.
fn pitInit(hz: u32) void {
    const divisor: u16 = @intCast(PIT_BASE_FREQ / hz); // ticks of the base clock per output tick
    serial.outb(PIT_CMD, 0x36); // channel 0, lo/hi byte, mode 3 (square wave)
    serial.outb(PIT_CHANNEL0, @truncate(divisor)); // divisor low byte
    serial.outb(PIT_CHANNEL0, @truncate(divisor >> 8)); // divisor high byte
}

var tick_count: u64 = 0; // total timer interrupts seen since boot

// Public accessor so other code can read uptime in ticks.
pub fn ticks() u64 {
    return tick_count;
}

// The IRQ0 handler: just count the tick. (We used to log once per second to
// prove interrupts fire, but that would spam the shell prompt; the `uptime`
// command reads this counter instead.)
fn timerTick() void {
    tick_count += 1; // one more 10 ms tick
}

// --- IRQ dispatch ------------------------------------------------------------
const IrqHandler = *const fn () void; // a handler is just a function pointer
var handlers: [16]?IrqHandler = [_]?IrqHandler{null} ** 16; // one slot per IRQ line

// Register a handler for an IRQ line and unmask it. With the APIC active, the
// unmask happens at the I/O APIC (route_hook); otherwise at the PIC.
pub fn register(irq: u4, handler: IrqHandler) void {
    handlers[irq] = handler; // remember the handler
    if (route_hook) |f| f(irq) else clearMask(irq); // let the IRQ through
}

// Called by the IDT for vectors 32-47. Handles spurious IRQs correctly, then
// dispatches to the registered handler and acknowledges the PIC.
pub fn handleIrq(vector: u8) void {
    const irq: u8 = vector - VECTOR_OFFSET; // convert vector back to IRQ number

    // Spurious master IRQ7: the line isn't actually in service -> no EOI.
    if (irq == 7 and (readMasterIsr() & 0x80) == 0) {
        return;
    }
    // Spurious slave IRQ15: EOI the master only (it accepted the cascade).
    if (irq == 15 and (readSlaveIsr() & 0x80) == 0) {
        serial.outb(MASTER_CMD, EOI);
        return;
    }

    if (handlers[irq]) |h| { // do we have a handler?
        h(); // run it
    } else {
        serial.print("[PIC] Unhandled IRQ{d} (vector {d}).\n", .{ irq, vector });
    }

    eoi(irq); // tell the PIC we're done so it can deliver the next one
}

// --- Init --------------------------------------------------------------------
pub fn init() void {
    serial.print("[PIC] Initializing PIC + PIT...\n", .{});

    remap(); // move IRQs off the exception vectors
    serial.print("[PIC]   Remapped: master IRQ0-7 -> vec 32-39, slave IRQ8-15 -> vec 40-47.\n", .{});

    pitInit(TIMER_HZ); // start the 100 Hz timer
    serial.print("[PIC]   PIT channel 0 @ {d} Hz (divisor {d}).\n", .{ TIMER_HZ, PIT_BASE_FREQ / TIMER_HZ });

    register(0, &timerTick); // install + unmask the timer on IRQ0
    serial.print("[PIC]   Registered timer on IRQ0; unmasked.\n", .{});

    asm volatile ("sti"); // set IF: from here, maskable interrupts can fire
    serial.print("[PIC]   Interrupts enabled (sti). master mask=0x{x}, slave mask=0x{x}.\n", .{ serial.inb(MASTER_DATA), serial.inb(SLAVE_DATA) });

    serial.print("[PIC] PIC + PIT initialized.\n", .{});
}
