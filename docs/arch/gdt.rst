====================
``src/arch/gdt.zig``
====================

   Builds and installs the kernel's own Global Descriptor Table and 64-bit Task State Segment for x86-64 long mode.

What it does
============

Limine hands the kernel a working GDT, but this file replaces it so the kernel owns its segmentation state and, crucially, controls the TSS. In long mode segmentation is mostly flat — the code/data descriptors carry no real base/limit and only set the privilege level and the long-mode (``L``) bit. The part that matters going forward is the TSS, which supplies ``RSP0`` (the stack the CPU switches to on a privilege change) and the IST entries (dedicated per-gate interrupt stacks); the IDT step points the double-fault handler at IST1.

Key components
==============

Segment selectors (byte offsets into the GDT, exported for other subsystems):

- ``KERNEL_CODE`` (``0x08``) — ring 0 code selector (GDT index 1).
- ``KERNEL_DATA`` (``0x10``) — ring 0 data selector (GDT index 2).
- ``USER_CODE`` (``0x1B``) — ring 3 code selector (index 3, RPL 3).
- ``USER_DATA`` (``0x23``) — ring 3 data selector (index 4, RPL 3).
- ``TSS_SELECTOR`` (``0x28``) — TSS descriptor (spans GDT indices 5 and 6).

Types and storage:

- ``Tss`` — ``packed struct`` modelling the 64-bit Task State Segment (``rsp0``-``rsp2``, ``ist1``-``ist7``, ``iopb_offset``). A ``comptime`` block asserts hardware byte offsets (``rsp0`` @ 0x04, ``ist1`` @ 0x24, ``iopb_offset`` @ 0x66).
- ``Gdtr`` — ``packed struct`` (limit + base) used as the operand for ``lgdt``.
- ``gdt``, ``gdtr``, ``tss`` — module-level storage for the table, its pointer, and the single TSS.
- ``ring0_stack``, ``ist1_stack`` — two 16 KiB (``STACK_SIZE``) stacks referenced by the TSS.

Encoders and loaders:

- ``makeEntry(base, limit, access, flags)`` — encode a standard 8-byte code/data descriptor.
- ``makeTssLow(base, limit)`` / ``makeTssHigh(base)`` — encode the two halves of the 16-byte 64-bit TSS descriptor.
- ``load(ptr)`` — runs ``lgdt``, reloads ``CS`` via a far return (``lretq``), and reloads the data segment registers.
- ``loadTss(selector)`` — runs ``ltr`` to activate the TSS.
- ``init()`` — fills the 7 GDT entries, points the TSS at its stack tops, disables the I/O permission bitmap, installs the table, and activates the TSS.

Depends on / used by
====================

- **Imports:** ``../drivers/serial.zig`` (logging only).
- **Used by:** ``idt.zig`` references ``gdt.KERNEL_CODE`` for its gate selectors; called early in the boot sequence (first of the GDT→IDT→PIC→… ordering), before the IDT is set up.

Notes
=====

- ``Tss`` and ``Gdtr`` MUST be ``packed`` structs. The hardware places the 8-byte ``RSP``/``IST`` fields at 4-byte-aligned offsets; an ``extern struct`` would pad and silently misplace fields, leading to a triple fault. The ``comptime`` offset assertions are tripwires against this.
- ``CS`` cannot be loaded with a ``mov``; ``load()`` reloads it with a pushed selector + address followed by ``lretq``.
- The TSS occupies two GDT slots (indices 5 and 6), so the table has 7 entries total (limit = 55 bytes).
- ``iopb_offset`` is set to ``@sizeOf(Tss)`` (past the limit) to disable the I/O permission bitmap.
- TSS stack fields are set to the *top* of each stack since the stack grows down.
