// RTC / CMOS wall-clock driver — reads the real-time clock for `date`.
//
// Every PC has a battery-backed Motorola-style RTC living inside the CMOS chip.
// It keeps ticking (seconds/minutes/hours/day/month/year) even while the machine
// is off, so it's our source of wall-clock time. We reach it through two legacy
// I/O ports: 0x70 is the INDEX register (which CMOS byte we want) and 0x71 is the
// DATA register (the byte at that index). On QEMU the emulated RTC defaults to the
// host's clock, so reading it on boot yields the real current date and time.
//
// Two subtleties make a naive read wrong:
//   1. The chip is mid-UPDATE for ~244 us each second (it's incrementing the time
//      fields). Reading during that window can return garbage, so we wait for the
//      "update in progress" (UIP) flag to clear, and then read the whole time
//      TWICE and only accept it once two back-to-back reads agree (guards against
//      a second/minute rolling over between two of our field reads).
//   2. The values may be stored in BCD (binary-coded decimal) and the hour may be
//      in 12-hour form. Status Register B tells us which, and we normalize both to
//      plain binary, 24-hour.

const serial = @import("serial.zig"); // logging + the in/out port helpers (inb/outb)

// --- CMOS port + register indices --------------------------------------------
const CMOS_INDEX: u16 = 0x70; // write here to select which CMOS byte to access
const CMOS_DATA: u16 = 0x71; // then read/write the selected byte here

// The time fields, by their CMOS register index.
const REG_SECONDS: u8 = 0x00; // seconds (0..59)
const REG_MINUTES: u8 = 0x02; // minutes (0..59)
const REG_HOURS: u8 = 0x04; // hours (0..23, or 1..12 + PM bit in 12-hour mode)
const REG_DAY: u8 = 0x07; // day of month (1..31)
const REG_MONTH: u8 = 0x08; // month (1..12)
const REG_YEAR: u8 = 0x09; // year within the century (0..99)

// Status registers.
const REG_STATUS_A: u8 = 0x0A; // bit 7 = update-in-progress (UIP)
const REG_STATUS_B: u8 = 0x0B; // bit 1 = 24-hour mode, bit 2 = binary (vs BCD)

const STATUS_A_UIP: u8 = 1 << 7; // set while the RTC is mid-update
const STATUS_B_24H: u8 = 1 << 1; // set = 24-hour, clear = 12-hour
const STATUS_B_BINARY: u8 = 1 << 2; // set = binary values, clear = BCD (the common default)
const HOUR_PM_BIT: u8 = 0x80; // in 12-hour mode, set on the hours byte means PM

// We assume the 21st century: CMOS year is 0..99 within a century, and there is no
// universally-readable century byte (the ACPI FADT exposes a "century index" but
// our acpi parser — src/acpi/acpi.zig — does not surface it). So we add 2000. This
// is correct for 2000..2099; revisit if/when the FADT century index is exposed.
const CENTURY_BASE: u16 = 2000;

// How many times to retry the consistency loop before giving up. Each iteration
// does a UIP-clear wait plus two full reads; this bound just stops us spinning
// forever if the hardware never settles (it always does on real chips/QEMU).
const MAX_RETRIES: usize = 100;

// A decoded wall-clock instant. All fields are plain binary, 24-hour. The RTC has
// no time-zone concept; on QEMU/most setups it reads as UTC, which is what we
// label it when printing.
pub const DateTime = struct {
    year: u16, // full year, e.g. 2026
    month: u8, // 1..12
    day: u8, // 1..31
    hour: u8, // 0..23
    minute: u8, // 0..59
    second: u8, // 0..59
};

// Read a single CMOS byte at `index`: select it via the index port, then read the
// data port. (The high bit of the index also controls NMI masking on real chips;
// we leave it clear, matching what the firmware set up.)
fn cmosRead(index: u8) u8 {
    serial.outb(CMOS_INDEX, index); // select the register
    return serial.inb(CMOS_DATA); // read its current value
}

// Is the RTC currently mid-update (its time fields momentarily inconsistent)?
fn updateInProgress() bool {
    return (cmosRead(REG_STATUS_A) & STATUS_A_UIP) != 0;
}

// Convert a BCD byte to binary: the high nibble is the tens digit, the low nibble
// the ones digit. e.g. 0x59 (BCD) -> 5*10 + 9 = 59.
fn bcdToBinary(v: u8) u8 {
    return (v & 0x0F) + ((v >> 4) * 10);
}

// Read all six time fields in one consistent pass. Waits for any in-progress
// update to finish first, so the snapshot isn't taken mid-tick.
const RawTime = struct {
    second: u8,
    minute: u8,
    hour: u8,
    day: u8,
    month: u8,
    year: u8,
};

fn readRaw() RawTime {
    // Wait (bounded) for the update-in-progress flag to clear before sampling, so
    // we don't read fields the chip is actively changing.
    var spins: usize = 0;
    while (updateInProgress() and spins < 100000) : (spins += 1) {}
    return .{
        .second = cmosRead(REG_SECONDS),
        .minute = cmosRead(REG_MINUTES),
        .hour = cmosRead(REG_HOURS),
        .day = cmosRead(REG_DAY),
        .month = cmosRead(REG_MONTH),
        .year = cmosRead(REG_YEAR),
    };
}

// Are two raw snapshots byte-for-byte identical? Used to confirm no field rolled
// over between two reads.
fn rawEqual(a: RawTime, b: RawTime) bool {
    return a.second == b.second and a.minute == b.minute and a.hour == b.hour and
        a.day == b.day and a.month == b.month and a.year == b.year;
}

// Read the current wall-clock time, fully decoded to binary 24-hour.
pub fn now() DateTime {
    // Read the time twice and only accept once two consecutive reads agree. This
    // closes the tiny window where a field (e.g. seconds 59->00) could roll over
    // between our individual cmosRead()s, yielding an impossible time.
    var prev = readRaw();
    var raw = prev;
    var tries: usize = 0;
    while (tries < MAX_RETRIES) : (tries += 1) {
        raw = readRaw();
        if (rawEqual(raw, prev)) break; // stable: two reads matched
        prev = raw; // changed mid-read; try again
    }

    // Status Register B tells us the encoding. The PM bit lives on the raw hours
    // byte and must be stripped before any BCD/binary conversion, then re-applied.
    const status_b = cmosRead(REG_STATUS_B);
    const is_binary = (status_b & STATUS_B_BINARY) != 0; // set = already binary
    const is_24h = (status_b & STATUS_B_24H) != 0; // set = 24-hour clock

    // Remember whether the (pre-conversion) hour byte's PM bit was set, then mask
    // it off so it doesn't corrupt the hour value we decode.
    const hour_is_pm = (raw.hour & HOUR_PM_BIT) != 0;
    const hour_raw = raw.hour & ~HOUR_PM_BIT;

    // Decode each field: convert from BCD unless the chip is in binary mode.
    var second = raw.second;
    var minute = raw.minute;
    var hour = hour_raw;
    var day = raw.day;
    var month = raw.month;
    var year_in_century = raw.year;
    if (!is_binary) {
        second = bcdToBinary(second);
        minute = bcdToBinary(minute);
        hour = bcdToBinary(hour);
        day = bcdToBinary(day);
        month = bcdToBinary(month);
        year_in_century = bcdToBinary(year_in_century);
    }

    // In 12-hour mode, fold the PM flag into a 24-hour value: 12am -> 0, 1..11pm
    // -> +12, 12pm stays 12. (12am is "12" with no PM bit; 12pm is "12" with it.)
    if (!is_24h) {
        if (hour == 12) hour = 0; // 12:xx am -> 00:xx
        if (hour_is_pm) hour += 12; // any pm hour -> +12 (so 12pm becomes 12 again)
    }

    return .{
        .year = CENTURY_BASE + @as(u16, year_in_century),
        .month = month,
        .day = day,
        .hour = hour,
        .minute = minute,
        .second = second,
    };
}

// Print a DateTime as "YYYY-MM-DD HH:MM:SS UTC" via the serial logger. Each field
// is zero-padded to its natural width with std.fmt's {d:0>N}.
pub fn printDateTime(dt: DateTime) void {
    serial.print("{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} UTC", .{
        dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second,
    });
}

// Boot marker: read the RTC once and log the current wall-clock time. Purely
// informational — the driver has no hardware to set up, the RTC is always running.
pub fn init() void {
    const dt = now();
    serial.print("[RTC] RTC initialized: ", .{});
    printDateTime(dt);
    serial.print("\n", .{});
}
