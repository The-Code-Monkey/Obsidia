// Power management: reboot and shut down the machine.
//
// We now prefer *real* ACPI, using the register ports the firmware describes in
// the FADT (parsed in acpi.zig). Shutdown writes SLP_TYP|SLP_EN to PM1a_CNT (and
// PM1b_CNT if present) to enter the S5 "soft off" state; reboot writes the FADT
// RESET_VALUE to the FADT RESET_REG port when the firmware advertises one.
//
// We do NOT parse the DSDT's \_S5 package (that needs an AML interpreter, which
// is out of scope), so we assume SLP_TYP = 0 — the value QEMU and most firmware
// use for S5. If ACPI is unavailable, the table lacks the register, or the write
// simply doesn't take effect, we FALL BACK to the previously-working mechanisms:
// the QEMU ACPI poweroff ports for shutdown, and the 8042 / 0xCF9 / triple-fault
// sequence for reboot. The fallbacks stay because the test harness depends on
// them and they are what works under plain emulation.

const serial = @import("../drivers/serial.zig"); // for port I/O
const acpi = @import("../acpi/acpi.zig"); // FADT-derived PM1/reset register info

// S5 ("soft off") sleep type. The real value is encoded in the DSDT \_S5 package,
// which we don't decode (no AML interpreter). QEMU and typical firmware use 0.
const SLP_TYP_S5: u16 = 0;

// Reboot the machine. Never returns (the CPU resets before this function ends).
pub fn reboot() noreturn {
    asm volatile ("cli"); // mask interrupts during the reset sequence

    // Method 0 (preferred): the ACPI RESET_REG from the FADT, when the firmware
    // advertises one in I/O space. Write RESET_VALUE to the given port; if the
    // platform honours it the CPU resets here and the fallbacks never run.
    if (acpi.fadtInfo()) |f| {
        if (f.reset_supported and f.reset_is_io and f.reset_port != 0) {
            serial.outb(f.reset_port, f.reset_value); // ACPI-described reset
        }
    }

    // Method 1: pulse the CPU reset line via the 8042 keyboard controller.
    var spin: u32 = 100_000; // bounded wait for the input buffer to drain
    while (spin > 0 and (serial.inb(0x64) & 0x02) != 0) : (spin -= 1) {}
    serial.outb(0x64, 0xFE); // command 0xFE = pulse reset line

    // Method 2: ICH9/PIIX reset control register (0xCF9).
    serial.outb(0xCF9, 0x06); // SYS_RST | RST_CPU
    serial.outb(0xCF9, 0x0E); // + FULL_RST

    // Method 3 (last resort): triple fault by loading an empty IDT and faulting.
    // With a zero-limit IDT, int3 has no handler -> #GP -> #DF -> triple fault.
    const Idtr = packed struct { limit: u16, base: u64 };
    const null_idtr = Idtr{ .limit = 0, .base = 0 };
    asm volatile (
        \\ lidt (%[p])
        \\ int3
        :
        : [p] "r" (&null_idtr),
    );
    while (true) asm volatile ("cli; hlt"); // unreachable
}

// Power the machine off. Never returns (or halts if poweroff isn't supported).
pub fn shutdown() noreturn {
    asm volatile ("cli"); // mask interrupts during the power-off sequence

    // Method 0 (preferred): real ACPI S5 transition via the FADT's PM1_CNT ports.
    // The S5 command is (SLP_TYP << 10) | SLP_EN; we write it to PM1a_CNT and, if
    // the chipset has a second control block, to PM1b_CNT too. PM1_CNT registers
    // are 16-bit, so the FADT's u32 port addresses are truncated for the OUT.
    if (acpi.fadtInfo()) |f| {
        const cmd: u16 = (SLP_TYP_S5 << acpi.SLP_TYP_SHIFT) | acpi.SLP_EN;
        if (f.pm1a_cnt != 0) serial.outw(@truncate(f.pm1a_cnt), cmd); // PM1a_CNT
        if (f.pm1b_cnt != 0) serial.outw(@truncate(f.pm1b_cnt), cmd); // PM1b_CNT
    }

    // Fallback: QEMU ACPI poweroff ports. Write SLP_EN (1<<13) with SLP_TYP=0.
    // The port depends on the emulated chipset, so try the common ones. This is
    // the path the harness has relied on, so it stays unconditionally.
    serial.outw(0x604, 0x2000); // QEMU q35 / modern
    serial.outw(0xB004, 0x2000); // QEMU i440fx / Bochs
    while (true) asm volatile ("cli; hlt"); // if poweroff didn't take, just halt
}
