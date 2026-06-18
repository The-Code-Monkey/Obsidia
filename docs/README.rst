=====================
Obsidia Documentation
=====================

This directory documents every source file in ``src/``. It mirrors the source folder structure: each doc lives at the same relative path as its source file, with ``.zig`` replaced by ``.rst``.

Source tree
===========

Top level
---------

- `main.rst <main.rst>`_ — kernel entry point (``_start``), Limine requests, boot sequence.
- `shell.rst <shell.rst>`_ — interactive serial/console shell (REPL, line editor, commands, login).
- `auth.rst <auth.rst>`_ — password hashing + verification (scrypt, PHC format).
- `install.rst <install.rst>`_ — in-guest installer (clones the system image onto the disk).
- `loader.rst <loader.rst>`_ — program loader (ELF64 + flat binaries).
- `tests.rst <tests.rst>`_ — host-side unit tests.

``acpi/``
---------

- `acpi/acpi.rst <acpi/acpi.rst>`_ — ACPI table parsing (RSDP → RSDT/XSDT → MADT).

``arch/``
---------

- `arch/gdt.rst <arch/gdt.rst>`_ — Global Descriptor Table + TSS.
- `arch/idt.rst <arch/idt.rst>`_ — Interrupt Descriptor Table + exception handlers.
- `arch/pic.rst <arch/pic.rst>`_ — legacy 8259 PIC remap + PIT timer.
- `arch/apic.rst <arch/apic.rst>`_ — LAPIC + I/O APIC + LAPIC timer.
- `arch/power.rst <arch/power.rst>`_ — reboot / shutdown.

``drivers/``
------------

- `drivers/serial.rst <drivers/serial.rst>`_ — COM1 serial UART (primary debug log + port I/O helpers).
- `drivers/console.rst <drivers/console.rst>`_ — framebuffer text console (Tamzen font, ANSI, cursor).
- `drivers/keyboard.rst <drivers/keyboard.rst>`_ — PS/2 keyboard (IRQ1, scancodes).
- `drivers/mouse.rst <drivers/mouse.rst>`_ — PS/2 mouse (IRQ12); wheel scrolls the console.
- `drivers/ata.rst <drivers/ata.rst>`_ — ATA PIO disk driver (block read + write).

``fs/``
-------

- `fs/fat32.rst <fs/fat32.rst>`_ — FAT32 filesystem (read-only).

``mm/``
-------

- `mm/pmm.rst <mm/pmm.rst>`_ — physical memory manager (bitmap frame allocator).
- `mm/vmm.rst <mm/vmm.rst>`_ — virtual memory manager (page tables, W^X).
- `mm/heap.rst <mm/heap.rst>`_ — kernel heap (``std.mem.Allocator``).

``sched/``
----------

- `sched/scheduler.rst <sched/scheduler.rst>`_ — kernel thread scheduler (cooperative + preemptive).
- `sched/sync.rst <sched/sync.rst>`_ — preemption-disable print lock.

``fonts/``
----------

- `fonts/README.rst <fonts/README.rst>`_ — bitmap font assets.
