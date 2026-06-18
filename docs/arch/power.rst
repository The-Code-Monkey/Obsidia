======================
``src/arch/power.zig``
======================

   Reboots or powers off the machine using mechanisms that work before a full ACPI implementation exists.

What it does
============

Since the kernel does not yet parse ACPI for power management, this file uses the legacy/emulator mechanisms that work without it. Reboot pulses the CPU reset line through several methods in order; shutdown uses QEMU's ACPI poweroff I/O ports so it works under emulation. Real hardware will need a proper ACPI implementation later.

Key components
==============

- ``reboot()`` (``noreturn``) — masks interrupts, then tries three methods in order: (1) pulse the CPU reset line via the 8042 keyboard controller (command ``0xFE`` on port ``0x64``, after draining the input buffer), (2) the ICH9/PIIX reset-control register on port ``0xCF9`` (``0x06`` then ``0x0E``), and (3) a deliberate triple fault as a last resort — loads a zero-limit IDT and executes ``int3`` so the fault has no handler (``#GP`` → ``#DF`` → triple fault).
- ``shutdown()`` (``noreturn``) — masks interrupts and writes the ACPI ``SLP_EN`` value (``0x2000``) to the common QEMU PM1a_CNT ports (``0x604`` for q35/modern, ``0xB004`` for i440fx/Bochs); halts if poweroff is unsupported.

Depends on / used by
====================

- **Imports:** ``../drivers/serial.zig`` (for ``inb``/``outb``/``outw`` port I/O).
- **Used by:** Invoked by higher-level kernel logic such as a shell/command interface handling reboot and shutdown requests.

Notes
=====

- Both functions begin with ``cli`` to mask interrupts during the sequence and end with a ``cli; hlt`` loop as an unreachable fallback.
- The reboot triple-fault path is intentional, not a bug: a zero-limit IDT guarantees the ``int3`` escalates to a triple fault and resets the machine.
- Shutdown is effectively QEMU-specific today; it depends on the emulated chipset's PM1a_CNT port, hence trying both common addresses.
