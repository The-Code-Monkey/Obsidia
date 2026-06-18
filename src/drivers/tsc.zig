// TSC: a high-resolution monotonic clock built on the CPU's Time-Stamp Counter.
//
// The TSC is a 64-bit counter that increments every CPU cycle (on modern CPUs at
// a constant "invariant" rate, independent of power/frequency scaling). RDTSC
// reads it. It is the finest-grained, lowest-overhead clock the machine offers,
// far better resolution than the 100 Hz (10 ms) timer tick — but it counts in
// raw cycles, not time. To turn cycles into wall-time we must learn how many
// cycles elapse per second, i.e. the TSC frequency.
//
// We learn that the same way apic.zig calibrates the LAPIC timer: measure how
// far the TSC advances across a KNOWN interval taken from the already-running
// kernel timer (the periodic timer fires at TIMER_HZ ticks/second, so each tick
// is a known slice of real time). Cycles-elapsed / seconds-elapsed = cycles/sec.
//
// Everything here is integer-only: build.zig disables SSE/AVX/MMX/soft-float, so
// there is no floating point available in the kernel. We carry the calibrated
// frequency in Hz and convert cycles -> nanoseconds with a 128-bit-widened
// integer multiply (cycles * 1e9 / hz) so we neither overflow nor lose precision.

const serial = @import("serial.zig"); // COM1 logging (print mirrors to console too)
const pic = @import("../arch/pic.zig"); // kernel timer tick counter (uptime in ticks)

// The kernel timer fires at this rate, so one tick is (1 / TIMER_HZ) seconds.
// Both the PIT (pic.zig) and the LAPIC timer (apic.zig) run at 100 Hz, so a tick
// is 10 ms regardless of which timer source is currently active.
const TIMER_HZ: u64 = 100;

// How many timer ticks to measure the TSC across. 10 ticks @ 100 Hz = 100 ms —
// long enough that the cycle count dwarfs measurement jitter, short enough not to
// noticeably stall boot.
const CALIBRATION_TICKS: u64 = 10;

// One billion: nanoseconds per second. Used to convert cycles <-> nanoseconds.
const NS_PER_SEC: u64 = 1_000_000_000;

// The calibrated TSC frequency in Hz (cycles per second). Zero until init()
// succeeds; a zero here means "not calibrated", and now() returns 0 so callers
// never divide by it or trust a bogus reading.
var tsc_hz: u64 = 0;

// The TSC value captured at the end of calibration — our "boot epoch" for the
// monotonic clock. now() reports nanoseconds since this point, so the clock reads
// ~0 right after init() rather than some huge cycles-since-CPU-reset value.
var base_tsc: u64 = 0;

// The largest nanosecond reading now() has ever returned. The monotonic contract
// says the clock never goes backwards; on a sane invariant TSC it never would, but
// a hypervisor rewind or a stray non-monotonic RDTSC could momentarily read below
// the epoch. We clamp to this floor so callers computing `now() - prev` can never
// underflow. Atomic so concurrent readers observe a consistent floor.
var last_ns: u64 = 0;

// Read the 64-bit CPU time-stamp counter (cycles since reset). RDTSC returns the
// low 32 bits in EAX and the high 32 bits in EDX; we recombine them into a u64.
// This mirrors the rdtsc() primitive in main.zig (kept local so tsc.zig has no
// dependency on the entry-point module).
pub inline fn rdtsc() u64 {
    var hi: u32 = undefined; // EDX: high 32 bits
    var lo: u32 = undefined; // EAX: low 32 bits
    asm volatile ("rdtsc"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
    );
    return (@as(u64, hi) << 32) | lo; // EDX:EAX -> single 64-bit value
}

// Spin until the timer tick counter advances once, bounded so we never hang if
// the timer somehow isn't ticking (mirrors apic.zig's waitForTick). Returns false
// if the guard budget runs out before a tick is observed.
fn waitForTick() bool {
    const start = pic.ticks(); // snapshot the current tick count
    var guard: u64 = 0; // bound the spin so a dead timer can't wedge us
    while (pic.ticks() == start) : (guard += 1) {
        if (guard > 4_000_000_000) return false; // timer never advanced -> give up
    }
    return true; // a tick edge was observed
}

// Calibrate the TSC against the running kernel timer and arm the monotonic clock.
// Call AFTER the timer is up (PIT or LAPIC) — the periodic tick is our time base.
pub fn init() void {
    // Align to a tick edge first, so the measurement window starts cleanly at the
    // boundary of a tick rather than partway through one.
    if (!waitForTick()) {
        // The timer isn't advancing, so we have no time base to calibrate against.
        // Skip cleanly (tsc_hz stays 0, now() returns 0) and still print a marker.
        serial.print("[TSC] calibration skipped: timer not ticking\n", .{});
        return;
    }

    // Snapshot the TSC and the tick count at the start of the measurement window.
    const tsc_start = rdtsc();
    const ticks_start = pic.ticks();

    // Busy-wait until CALIBRATION_TICKS ticks have elapsed, bounding the spin so a
    // stalled timer can't hang the boot. Crucially, unlike apic.zig — which reads a
    // hardware counter so its window is self-measured — OUR window length is ASSUMED
    // from the tick count. If the timer stalls mid-window the guard would trip while
    // the TSC kept advancing for the whole (multi-second) spin; computing a frequency
    // from that corrupt window would be badly wrong. So if the guard expires before
    // the full window elapses, we treat calibration as failed and skip cleanly.
    var guard: u64 = 0;
    var stalled = false;
    while (pic.ticks() - ticks_start < CALIBRATION_TICKS) : (guard += 1) {
        if (guard > 8_000_000_000) { // safety valve: never spin forever
            stalled = true;
            break;
        }
    }

    // Snapshot the TSC again at the end of the window.
    const tsc_end = rdtsc();
    const ticks_elapsed = pic.ticks() - ticks_start; // how many ticks we actually saw

    // If the timer stalled mid-window or didn't advance at all, the measurement
    // window is untrustworthy — bail without arming the clock.
    if (stalled or ticks_elapsed == 0) {
        serial.print("[TSC] calibration skipped: timer stalled mid-window\n", .{});
        return;
    }

    // Cycles the TSC advanced over the window. RDTSC counts up, so end >= start on
    // a sane CPU; guard against a wrap/non-monotonic reading just in case.
    if (tsc_end <= tsc_start) {
        serial.print("[TSC] calibration skipped: TSC did not advance\n", .{});
        return;
    }
    const cycles = tsc_end - tsc_start;

    // The window covered `ticks_elapsed` ticks, each (1 / TIMER_HZ) seconds. So:
    //   seconds  = ticks_elapsed / TIMER_HZ
    //   tsc_hz   = cycles / seconds = cycles * TIMER_HZ / ticks_elapsed
    // All integer math. `cycles` (~hundreds of millions for 100 ms) times TIMER_HZ
    // (100) stays well within u64, so no widening is needed here.
    const hz = (cycles * TIMER_HZ) / ticks_elapsed;

    // Sanity-check the result: a real CPU TSC runs somewhere from ~100 MHz to tens
    // of GHz. Anything outside a generous [1 MHz, 1 THz] band means the calibration
    // is bogus (e.g. a frozen or absurd timer), so we skip rather than trust it.
    if (hz < 1_000_000 or hz > 1_000_000_000_000) {
        serial.print("[TSC] calibration implausible ({d} Hz); skipping\n", .{hz});
        return;
    }

    // Commit the calibration and set the boot epoch to "now", so the monotonic
    // clock starts near zero.
    tsc_hz = hz;
    base_tsc = rdtsc();

    // Report in MHz (integer divide) — the marker our test harness greps for.
    serial.print("[TSC] calibrated: {d} MHz\n", .{hz / 1_000_000});
}

// Was the TSC successfully calibrated? When false, now()/nanos() return 0.
pub fn isReady() bool {
    return tsc_hz != 0;
}

// The calibrated TSC frequency in Hz (0 if calibration was skipped).
pub fn frequencyHz() u64 {
    return tsc_hz;
}

// Monotonic nanoseconds since the clock was armed in init(). The fundamental
// kernel time primitive: a high-resolution, never-decreasing reading.
//
// Conversion: ns = cycles * 1e9 / tsc_hz. `cycles` can be huge (a multi-GHz TSC
// reaches ~1.8e19 — near the u64 ceiling — after only a few years), and
// multiplying by 1e9 would overflow u64 long before that. So we widen to u128 for
// the multiply+divide, then narrow back: a u128 holds the product comfortably and
// the quotient always fits u64 for any realistic uptime.
pub fn now() u64 {
    if (tsc_hz == 0) return 0; // not calibrated -> no meaningful time
    const cur = rdtsc(); // current raw cycle count
    // Compute elapsed cycles since the epoch. If a non-monotonic read lands at or
    // below the epoch, treat it as zero elapsed rather than wrapping.
    const cycles: u128 = if (cur > base_tsc) cur - base_tsc else 0;
    const ns_wide: u128 = (cycles * NS_PER_SEC) / tsc_hz; // cycles -> nanoseconds
    const ns: u64 = if (ns_wide > 0xFFFF_FFFF_FFFF_FFFF) 0xFFFF_FFFF_FFFF_FFFF else @intCast(ns_wide); // saturate, never trap
    // Enforce monotonicity: never report less than the highest value seen so far,
    // so a transient backward TSC read can't make a caller's `now() - prev` wrap.
    const prev = @atomicLoad(u64, &last_ns, .monotonic);
    if (ns <= prev) return prev; // would go backwards -> hold the floor
    @atomicStore(u64, &last_ns, ns, .monotonic); // advance the floor
    return ns;
}

// Convenience alias spelled out for callers that prefer the explicit name.
pub fn nanos() u64 {
    return now();
}
