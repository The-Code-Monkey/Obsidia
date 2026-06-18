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
// A line counts as "registered" if it has at least one handler in its chain.
pub fn rerouteRegistered() void {
    for (handlers, 0..) |line, i| {
        if (line.count != 0) {
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

// Optional per-tick hook (the scheduler sets this to preempt on each timer IRQ).
pub var on_tick: ?*const fn () void = null;

// Public accessor so other code can read uptime in ticks. Atomic load so a
// busy-wait reader (e.g. the LAPIC-timer calibration) sees the IRQ's updates and
// the compiler can't hoist the read out of a spin loop.
pub fn ticks() u64 {
    return @atomicLoad(u64, &tick_count, .monotonic);
}

// The timer-IRQ handler: just count the tick. (Originally driven by the PIT on
// IRQ0; once the LAPIC timer is calibrated it drives this instead.) The `uptime`
// command and the cursor blink read this counter.
fn timerTick() void {
    _ = @atomicRmw(u64, &tick_count, .Add, 1, .monotonic); // one more tick
    if (on_tick) |f| f(); // optional preemption hook (runs in IRQ context)
}

// --- IRQ dispatch ------------------------------------------------------------
// SHARED, LEVEL-TRIGGERED IRQ LINES. On real PC hardware (and QEMU's PCI bus)
// several devices commonly wire their interrupt to ONE physical IRQ line — e.g.
// an audio controller and a NIC may both assert PIRQ-routed IRQ11. The line is
// level-triggered: it stays asserted as long as ANY sharer has an interrupt
// pending. So a single line needs a CHAIN of handlers, not just one. The old
// design kept exactly one handler per line and overwrote it on the second
// register(), silently disabling the first device. We now keep a small fixed-
// size array per line and, on each interrupt, call EVERY registered handler.
//
// The shared-IRQ contract: each device handler reads its own status register
// first; if its device didn't raise this interrupt it returns immediately
// (a cheap no-op). Calling all handlers is therefore correct and safe — the
// one device that did assert the line clears its condition (de-asserting the
// level), and the bystanders do nothing. We cannot tell from the PIC alone
// WHICH sharer fired, so "call everyone" is the standard, only-correct policy.
const IrqHandler = *const fn () void; // a handler is just a function pointer
const MAX_SHARERS: usize = 4; // up to 4 devices may share a single IRQ line

// One IRQ line: a fixed array of handlers plus how many are populated. Fixed
// size keeps us allocator-free (this runs before the heap exists) and bounds
// the per-interrupt dispatch work.
const IrqLine = struct {
    chain: [MAX_SHARERS]?IrqHandler = [_]?IrqHandler{null} ** MAX_SHARERS,
    count: usize = 0, // number of valid entries in `chain` (always packed [0..count))
};
var handlers: [16]IrqLine = [_]IrqLine{.{}} ** 16; // one chain per IRQ line

// Register (APPEND) a handler for an IRQ line and unmask it. Multiple calls for
// the same line stack onto the chain rather than overwriting, so shared-line
// devices coexist. With the APIC active, the unmask happens at the I/O APIC
// (route_hook); otherwise at the PIC. Re-unmasking an already-unmasked line on
// the second sharer is harmless and idempotent.
pub fn register(irq: u4, handler: IrqHandler) void {
    const line = &handlers[irq];
    if (line.count >= MAX_SHARERS) { // chain full: refuse rather than clobber a sharer
        return;
    }
    line.chain[line.count] = handler; // append at the end of the packed chain
    line.count += 1; // grow the chain
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

    // Acknowledge BEFORE running the handler. Our IRQs are edge-triggered (the
    // device data persists until read), and crucially the timer handler may
    // context-switch away — so the EOI must already be sent, or the controller
    // wouldn't deliver the next interrupt to the thread we switch to.
    eoi(irq);

    // Dispatch to EVERY registered sharer on this line. Each handler checks its
    // own device's status and returns fast if the interrupt wasn't theirs, so
    // running all of them is the correct shared-line behavior. We read `count`
    // once into a local: a handler may context-switch away (the timer's
    // preemption hook), and we want a stable bound over the loop.
    const line = &handlers[irq];
    const n = line.count;
    if (n == 0) {
        return;
    }
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (line.chain[i]) |h| h(); // run each sharer (one of them may preempt us)
    }
}

// --- Init --------------------------------------------------------------------
pub fn init() void {
    remap(); // move IRQs off the exception vectors

    pitInit(TIMER_HZ); // start the 100 Hz timer

    register(0, &timerTick); // install + unmask the timer on IRQ0

    asm volatile ("sti"); // set IF: from here, maskable interrupts can fire

    serial.log("[PIC] PIC + PIT initialized.\n", .{});
}
