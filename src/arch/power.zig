// Power management: reboot and shut down the machine.
//
// We don't parse ACPI yet, so we use the mechanisms that work without it.
// Reboot pulses the CPU reset line via the 8042 keyboard controller and the
// ICH9/PIIX reset-control register (port 0xCF9), falling back to a deliberate
// triple fault. Shutdown uses QEMU's ACPI poweroff I/O ports — so it works under
// emulation; real hardware will need a proper ACPI implementation later.

const serial = @import("../drivers/serial.zig"); // for port I/O

// Reboot the machine. Never returns (the CPU resets before this function ends).
pub fn reboot() noreturn {
    asm volatile ("cli"); // mask interrupts during the reset sequence

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
    asm volatile ("cli");
    // QEMU ACPI poweroff: write SLP_EN (1<<13) to PM1a_CNT. The port depends on
    // the emulated chipset, so try the common ones.
    serial.outw(0x604, 0x2000); // QEMU q35 / modern
    serial.outw(0xB004, 0x2000); // QEMU i440fx / Bochs
    while (true) asm volatile ("cli; hlt"); // if poweroff didn't take, just halt
}
