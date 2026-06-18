================
``src/main.zig``
================

   The kernel entry point: declares the Limine boot requests and brings up every subsystem in order before handing off to the shell.

What it does
============

Limine loads the kernel in 64-bit long mode with paging already enabled, then jumps to ``_start``. This file declares the ``.limine_requests`` (framebuffer, memory map, HHDM, executable address, RSDP, paging mode) that the bootloader fills in, installs a custom kernel panic handler, and runs the boot sequence: serial → GDT → IDT → PIC → PMM → framebuffer capture → VMM → heap → console → ACPI/APIC → ATA → FAT32. It then switches to a kernel-owned stack, reclaims bootloader memory, runs scheduler self-tests, and starts the interactive shell as a scheduled thread.

Key components
==============

- ``_start()`` — exported entry symbol (named by the linker script's ENTRY); never returns. Runs the ordered init sequence and finally jumps to ``runAfterReclaim`` on the new kernel stack.
- ``runAfterReclaim()`` — runs on the kernel-owned stack: reclaims Limine boot memory, runs scheduler demos, starts the shell + keyboard, adopts the current context as the idle thread, spawns the shell thread, and begins permanent preemption.
- ``shellThread()`` — thin wrapper that runs ``shell.run()`` as a kernel thread.
- ``kernelPanic(msg, first_trace_addr)`` — wired in via ``pub const panic = std.debug.FullPanic(kernelPanic)``; disables interrupts, prints the message and faulting address to serial (mirrored to the framebuffer), then halts forever.
- ``hcf()`` — "halt and catch fire": stops the CPU forever (per-arch idle instruction) after a fatal early error or on completion.

Limine requests (exported, in ``.limine_requests``)
---------------------------------------------------

- ``start_marker`` / ``end_marker`` — bracket the request list so Limine can locate it.
- ``base_revision`` — declares boot-protocol revision 3.
- ``framebuffer_request``, ``memmap_request``, ``hhdm_request``, ``executable_address_request``, ``rsdp_request`` — request the framebuffer, physical memory map, HHDM offset, kernel load base, and ACPI RSDP.
- ``module_request`` — request the modules listed in ``limine.conf`` (the login credential, and on the installer medium the system image).
- ``paging_mode_request`` — forces 4-level paging (min/max/preferred all ``4lvl``).

Modules
-------

- ``readModules()`` — finds the loaded modules by path suffix and stashes their byte slices; module memory (type executable_and_modules) is never reclaimed and is reachable via the HHDM, so the slices stay valid after the CR3 switch and reclaim.
- ``authModule()`` / ``systemModule()`` — accessors handed to the shell's login and the installer respectively.

Constants
---------

- ``KERNEL_STACK_SIZE`` (64 KiB) and ``kernel_stack`` — the kernel's own stack, switched to before reclaiming Limine's boot stack.

Depends on / used by
====================

- **Imports:** essentially the whole kernel — ``drivers/serial``, ``arch/gdt``, ``arch/idt``, ``arch/pic``, ``arch/apic``, ``mm/pmm``, ``mm/vmm``, ``mm/heap``, ``drivers/console``, ``drivers/keyboard``, ``drivers/ata``, ``fs/fat32``, ``acpi/acpi``, ``sched/scheduler``, ``shell``, plus ``limine``, ``std``, and ``builtin``.
- **Used by:** the bootloader (Limine), via the ``_start`` entry symbol. This is the root of the call graph; nothing in the kernel calls into it.

Notes
=====

- Ordering is load-bearing. The framebuffer must be captured *before* the VMM takes over paging (Limine response pointers become unreachable afterward), and ACPI must be parsed *before* ``pmm.reclaimBootloader()`` because the RSDP response struct lives in bootloader-reclaimable memory.
- ``apic.init`` and the LAPIC timer only start if an RSDP response is present; otherwise the kernel stays on the 8259 PIC/PIT.
- The stack switch is done in inline assembly (``movq %rsp; callq``), and ``runAfterReclaim`` is ``noreturn``, so the old boot stack is never touched again and its frames are safe to free.
- ``serial.print("BOOT_OK\n", ...)`` emits the marker the test harness greps for.
