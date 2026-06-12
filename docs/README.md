# Obsidia Documentation

This directory documents every source file in `src/`. It mirrors the source folder structure: each doc lives at the same relative path as its source file, with `.zig` replaced by `.md`.

## Source tree

### Top level
- [`main.md`](main.md) — kernel entry point (`_start`), Limine requests, boot sequence.
- [`shell.md`](shell.md) — interactive serial/console shell (REPL, line editor, commands, login).
- [`auth.md`](auth.md) — password hashing + verification (scrypt, PHC format).
- [`install.md`](install.md) — in-guest installer (clones the system image onto the disk).
- [`loader.md`](loader.md) — program loader (ELF64 + flat binaries).
- [`tests.md`](tests.md) — host-side unit tests.

### `acpi/`
- [`acpi/acpi.md`](acpi/acpi.md) — ACPI table parsing (RSDP → RSDT/XSDT → MADT).

### `arch/`
- [`arch/gdt.md`](arch/gdt.md) — Global Descriptor Table + TSS.
- [`arch/idt.md`](arch/idt.md) — Interrupt Descriptor Table + exception handlers.
- [`arch/pic.md`](arch/pic.md) — legacy 8259 PIC remap + PIT timer.
- [`arch/apic.md`](arch/apic.md) — LAPIC + I/O APIC + LAPIC timer.
- [`arch/power.md`](arch/power.md) — reboot / shutdown.

### `drivers/`
- [`drivers/serial.md`](drivers/serial.md) — COM1 serial UART (primary debug log + port I/O helpers).
- [`drivers/console.md`](drivers/console.md) — framebuffer text console (Tamzen font, ANSI, cursor).
- [`drivers/keyboard.md`](drivers/keyboard.md) — PS/2 keyboard (IRQ1, scancodes).
- [`drivers/mouse.md`](drivers/mouse.md) — PS/2 mouse (IRQ12); wheel scrolls the console.
- [`drivers/ata.md`](drivers/ata.md) — ATA PIO disk driver (block read + write).

### `fs/`
- [`fs/fat32.md`](fs/fat32.md) — FAT32 filesystem (read-only).

### `mm/`
- [`mm/pmm.md`](mm/pmm.md) — physical memory manager (bitmap frame allocator).
- [`mm/vmm.md`](mm/vmm.md) — virtual memory manager (page tables, W^X).
- [`mm/heap.md`](mm/heap.md) — kernel heap (`std.mem.Allocator`).

### `sched/`
- [`sched/scheduler.md`](sched/scheduler.md) — kernel thread scheduler (cooperative + preemptive).
- [`sched/sync.md`](sched/sync.md) — preemption-disable print lock.

### `fonts/`
- [`fonts/README.md`](fonts/README.md) — bitmap font assets.
