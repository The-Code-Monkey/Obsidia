// Terminal line discipline (a tiny "TTY layer").
//
// Every input byte — from the PS/2 keyboard and from the serial port — now passes
// through here on its way to whoever is reading input (today: the shell's input
// ring). Its job is to interpret terminal CONTROL characters rather than letting
// them through as ordinary data. Right now it handles exactly one: Ctrl-C (the
// "interrupt" character), which should stop whatever program is running in the
// foreground rather than be typed into it.
//
// Why a separate layer: the keyboard driver only knows about keys, and the shell
// only knows about its own line of text. Neither is the right place to decide
// "this keystroke means: interrupt the running program." That policy lives here,
// in front of both, so it can grow later (Ctrl-Z to suspend, Ctrl-D for end-of-
// input, a raw vs. cooked mode flag) without touching the driver or the shell.
//
// Design note: this layer does NOT print anything itself, because feed() is called
// from interrupt context (the keyboard/serial IRQ). It only sets a flag and either
// swallows or forwards the byte; the code that acts on the flag (the program
// supervisor in the scheduler, or the shell) does the user-visible echo from
// normal thread context.

// Control characters we recognise. (Only the interrupt char for now.)
const INTR: u8 = 0x03; // Ctrl-C — request to interrupt the foreground program

// Who is "in front of" the terminal right now — i.e. who a Ctrl-C should act on.
//   .shell   — the interactive shell is reading a command line (Ctrl-C cancels it)
//   .process — a user program launched by the shell is running (Ctrl-C kills it)
pub const Foreground = enum { shell, process };

var foreground: Foreground = .shell; // the shell owns the terminal until it runs a program
var intr_pending: bool = false; // a Ctrl-C arrived while a program was in the foreground

// Where ordinary (non-intercepted) bytes go next. The shell registers its input
// ring here at boot, so for everything except an intercepted Ctrl-C this layer is
// a transparent pass-through and input behaves exactly as before.
var sink: ?*const fn (u8) void = null;

// Register the downstream consumer of ordinary input bytes (the shell's ring).
pub fn setSink(f: *const fn (u8) void) void {
    sink = f;
}

// Declare who currently owns the terminal. The scheduler calls this with .process
// just before it runs a user program and .shell again once that program is gone,
// so a Ctrl-C is routed to the right place.
pub fn setForeground(fg: Foreground) void {
    foreground = fg;
}

// Atomically read-and-clear the "Ctrl-C was pressed" flag. The program supervisor
// (scheduler.runUser) polls this while a foreground program runs; a true result
// means "terminate that program now." Clearing on read means each Ctrl-C fires once.
pub fn takeIntr() bool {
    return @atomicRmw(bool, &intr_pending, .Xchg, false, .acq_rel);
}

// The single entry point for every input byte (keyboard + serial both call this).
// Runs in IRQ context, so it does no I/O of its own.
pub fn feed(c: u8) void {
    if (c == INTR and foreground == .process) {
        // A program is running in the foreground: don't deliver Ctrl-C to it as
        // data — record that an interrupt was requested and drop the byte. The
        // supervisor will see this via takeIntr() and stop the program.
        @atomicStore(bool, &intr_pending, true, .release);
        return;
    }
    // Everything else (including Ctrl-C typed at the shell prompt, which the shell
    // turns into "cancel this line") passes straight through to the reader.
    if (sink) |s| s(c);
}

// --- Unit test (runs on the host via `zig build test`) -----------------------
test "Ctrl-C is swallowed for a foreground process but forwarded to the shell" {
    const t = @import("std").testing;
    const Cap = struct {
        var buf: [8]u8 = undefined;
        var len: usize = 0;
        fn reset() void {
            len = 0;
        }
        fn fwd(c: u8) void {
            buf[len] = c;
            len += 1;
        }
    };
    setSink(&Cap.fwd);

    // Foreground = a running program: Ctrl-C is swallowed and flags an interrupt.
    setForeground(.process);
    Cap.reset();
    feed(INTR);
    try t.expectEqual(@as(usize, 0), Cap.len); // not forwarded as data
    try t.expect(takeIntr()); // interrupt was recorded...
    try t.expect(!takeIntr()); // ...and is cleared after one read

    // Foreground = the shell: Ctrl-C is forwarded (the shell cancels its line).
    setForeground(.shell);
    Cap.reset();
    feed(INTR);
    try t.expectEqual(@as(usize, 1), Cap.len);
    try t.expectEqual(INTR, Cap.buf[0]);
    try t.expect(!takeIntr()); // no interrupt flagged in shell mode

    // An ordinary byte is always forwarded unchanged, in either mode.
    setForeground(.process);
    Cap.reset();
    feed('x');
    try t.expectEqual(@as(usize, 1), Cap.len);
    try t.expectEqual(@as(u8, 'x'), Cap.buf[0]);
    setForeground(.shell); // restore default for any later test
}
