==========================================================
Obsidia — Full System Specification
==========================================================

:Project: Obsidia, an x86-64 operating-system kernel written from scratch in Zig
:Target: 64-bit Intel/AMD PCs (x86-64), booted by the Limine bootloader, run under QEMU
:Toolchain: Zig 0.14.0 (pinned in CI and ``build.zig.zon``)
:Primary debug channel: COM1 serial; a successful boot ends with the marker ``BOOT_OK``
:Status of this document: A complete description of what the system does **today**, plus an
   exhaustive, dependency-ordered enumeration of **everything still required** to reach a
   basic graphical desktop environment.

.. contents:: Table of Contents
   :depth: 3
   :backlinks: none

.. note::

   This specification is synthesized from the project ``README.rst``, the per-module
   documentation under ``docs/``, and a direct reading of the source under ``src/`` and the
   build/run/test scripts. Where the prose documentation and the source disagreed, the
   **source is treated as authoritative** and the discrepancy is called out inline (for
   example, the scrypt cost parameter and the installer "Option B" path).


1. Overview
===========

What Obsidia is
---------------

Obsidia is a small operating-system **kernel** — the program a computer runs first, before
any applications, that talks directly to the hardware (CPU, memory, framebuffer, keyboard,
mouse, disk, audio codec). It is written from scratch in `Zig <https://ziglang.org>`_ for
64-bit Intel/AMD PCs as a learning project, and it is exercised inside
`QEMU <https://www.qemu.org>`_ so no physical hardware is required.

On boot it brings the machine up one subsystem at a time and then presents an interactive
**shell** over both the serial line and the on-screen framebuffer console. It can read (and,
on a FAT32 disk, write) files, run small user programs in ring 3, install itself onto a disk,
and gate the shell behind a real password login.

Design philosophy
-----------------

* **One subsystem at a time.** Subsystems are brought up in a strict dependency order, each
  verified to boot before the next is stacked on top. The boot log prints a success marker
  for every subsystem; the integration harness asserts every marker.
* **Micro-commits / one unit per branch.** Each unit of work is a single branch and pull
  request with a conventional-commit message.
* **Educational, near-every-line comments.** The source is written to teach; comments
  explain the *why* of low-level decisions (hardware quirks, ABI alignment, ordering
  constraints).
* **Documentation is gospel.** Existing documentation is not modified except on explicit
  instruction. (This file is a newly authored specification, not a modification.)
* **Don't break userspace.** The ring-3 user ABI (the syscall contract) is a stability
  boundary.

Target and constraints
----------------------

* **Architecture:** x86-64 long mode only (4-level paging; 5-level / LA57 is rejected as
  fatal).
* **Boot protocol:** Limine, boot-protocol revision 3, via a hybrid ISO that boots under both
  UEFI and legacy BIOS.
* **Emulator:** QEMU, KVM-accelerated for interactive runs; TCG (no KVM) in CI.
* **Floating point is disabled at the toolchain level.** ``build.zig`` removes the
  ``sse``, ``sse2``, ``avx``, ``avx2`` and ``mmx`` feature families and adds ``soft_float``
  (plus ``popcnt``). Emitting any SSE instruction before the FPU is configured in-kernel
  triple-faults at boot, so these features stay disabled until an FPU-enable step exists.
* **No red zone** (``red_zone = false``): an interrupt arriving mid-function would corrupt
  the System V red zone.
* **Kernel code model** (``code_model = .kernel``): the higher-half code model for the top
  2 GiB of the address space.


2. Architecture
================

Boot flow
---------

#. **Firmware → Limine.** UEFI or legacy BIOS loads Limine from the hybrid ISO. ``limine.conf``
   selects the ``limine`` protocol and loads ``boot():/boot/kernel.elf``, with serial logging
   enabled and a zero-second timeout.
#. **Limine → ``_start``.** Limine enters the kernel at ``export fn _start`` (named by the
   linker script's ``ENTRY``) already in 64-bit long mode with paging enabled. The kernel
   declares a set of Limine *requests* in the ``.limine_requests`` ELF segment, which Limine
   fills in before the jump.
#. **Ordered init sequence** (see *Init order* below). Each subsystem logs a success marker.
#. **Stack switch + reclaim.** After ``BOOT_OK`` the kernel switches ``RSP`` to its own 64 KiB
   stack and ``call``\ s ``runAfterReclaim`` (which is ``noreturn``), so Limine's boot stack —
   which lives in bootloader-reclaimable memory — is never touched again and can be freed.
#. **Self-tests, then permanent multitasking.** ``runAfterReclaim`` reclaims bootloader
   memory, runs the scheduler / usermode / VMM / loader self-tests, starts the shell and input
   drivers, adopts the boot context as the idle thread, spawns the shell thread, and enters
   permanent preemption.

Limine requests (declared in ``main.zig``, kept in the ``.limine_requests`` segment)
------------------------------------------------------------------------------------

* ``base_revision`` — boot-protocol revision 3 (verified ``isSupported`` or the kernel halts).
* ``framebuffer_request`` — the linear framebuffer (address/width/height/pitch/bpp + channel
  shifts). Only the first framebuffer is used.
* ``memmap_request`` — the physical memory map.
* ``hhdm_request`` — the Higher-Half Direct Map offset (``virtual = hhdm_offset + physical``).
* ``executable_address_request`` — the kernel's physical and virtual load base.
* ``rsdp_request`` — the ACPI RSDP pointer.
* ``module_request`` — modules listed in ``limine.conf`` (login credential, and on the
  installer medium, the system image / kernel / bootloader / config).
* ``paging_mode_request`` — forces 4-level paging (min/max/preferred all ``4lvl``).

Init order (the exact sequence in ``_start``)
---------------------------------------------

#. ``serial.init()`` — COM1 first, so everything afterward can log.
#. verify ``base_revision.isSupported()`` (else ``hcf()``).
#. ``gdt.init()``
#. ``idt.init()`` (runs the ``int3`` self-test).
#. ``syscall.init()`` (programs the SYSCALL/SYSRET MSRs; needs GDT selectors).
#. ``pic.init()`` (remap PICs, start the 100 Hz PIT, ``sti``).
#. unwrap HHDM + memmap responses, then ``pmm.init(memmap, hhdm_offset)``.
#. ``readModules()`` — stash module byte-slices (AUTH, SYSTEM.IMG, BOOTX64.EFI,
   INSTALLED.CONF, KERNEL.ELF) by case-insensitive path suffix.
#. capture the framebuffer info (copied out **before** the VMM takes over paging, because
   Limine response pointers become unreachable afterward).
#. ``vmm.init(physical_base, virtual_base, hhdm_offset)`` — build own page tables, load CR3.
#. ``kstack.init()`` — populate the guarded-kernel-stack region's page-table path **before**
   any per-process address space is cloned, so the shared kernel-half subtree is inherited.
#. ``cpu.enableSmepSmap()`` — must follow the VMM (own tables with correct U/S bits).
#. ``heap.init()``
#. if a framebuffer exists: ``console.init(info)`` then ``serial.setMirror(&console.writeString)``.
#. if an RSDP response exists: ``acpi.init(rsdp)`` → ``apic.init()`` → ``apic.initTimer(100)``.
   Otherwise warn and stay on the 8259 PIC / PIT.
#. ``dma.init()``
#. ``pci.init()``
#. ``ac97.init()``
#. ``ata.init()``; ``ata.selfTest()``
#. ``ahci.init()``; ``ahci.selfTest()``
#. ``rtc.init()``
#. ``fat32.selfTest()``
#. print ``Kernel initialized successfully.`` then ``BOOT_OK``.
#. switch ``RSP`` to ``kernel_stack`` (64 KiB) and ``callq runAfterReclaim``.

``runAfterReclaim`` then runs (in order): ``pmm.reclaimBootloader()``; the demos
``scheduler.selfTest`` / ``preemptDemo`` / ``blockSleepDemo`` / ``mutexDemo`` /
``usermode.selfTest`` / ``vmm.selfTestAddressSpace`` / ``vmm.selfTestUncacheable`` /
``scheduler.userProcessDemo``; ``loader.selfTest()``; shell + installer wiring;
``keyboard.init`` / ``mouse.init``; ``scheduler.init`` (idle = thread 0);
``scheduler.spawn("shell")``; ``scheduler.startPreemption()``; ``scheduler.idle()`` (never
returns).

Memory layout (higher-half)
---------------------------

The kernel image lives in the top 2 GiB at base ``0xffffffff80000000`` (Limine's mandated
higher-half region). The linker script (``linker-x86_64.lds``) emits each section in its own
page-aligned ``PT_LOAD`` segment with boundary symbols so the VMM can map each with distinct
permissions (W^X).

.. list-table:: Reserved virtual regions
   :header-rows: 1
   :widths: 28 30 42

   * - Region
     - Base (PML4 slot)
     - Purpose
   * - Kernel image
     - ``0xffffffff80000000``
     - ``.text`` (R+X), ``.rodata`` (R, NX), ``.data``/``.bss`` (RW, NX),
       ``.limine_requests`` (RW, NX), each its own page-aligned segment.
   * - HHDM
     - Limine-provided offset
     - Direct map of all physical RAM + MMIO, 2 MiB huge pages, RW + NX, spanning at least
       ``max(4 GiB, top of RAM)``.
   * - Kernel heap
     - ``0xffffc00000000000`` (slot 384)
     - On-demand-grown heap region, capped 4 GiB above its base.
   * - Kernel stacks
     - ``0xffffe00000000000`` (slot 448)
     - Per-thread 32 KiB guarded stacks (unmapped guard page below each).
   * - Ring-0 flat-binary load
     - ``0xffffd00000000000`` (slot 416)
     - Legacy ring-0 ``exec0`` flat-binary load base.
   * - AHCI MMIO (ABAR)
     - ``0xffffffffe1000000``
     - Uncacheable mapping of the AHCI HBA registers.
   * - User half
     - ``0x0`` .. ``USER_LIMIT`` (``0x0000800000000000``)
     - Per-process low half: flat user load at ``0x400000``, user stack top ``0x800000``;
       PML4 slots 256..511 (kernel half) are shared into every process.


3. Subsystem specifications
===========================

Each subsection describes the subsystem **as implemented today**, including the constants and
behaviors the integration harness asserts.

3.1 Architecture / CPU
----------------------

GDT + TSS (``arch/gdt.zig``)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Replaces Limine's GDT so the kernel owns segmentation and, crucially, the TSS. Seven entries:
null, kernel code (1), kernel data (2), user data (3), user code (4), and a 64-bit TSS
descriptor spanning slots 5–6.

.. list-table:: Segment selectors
   :header-rows: 1
   :widths: 24 16 60

   * - Name
     - Selector
     - Notes
   * - ``KERNEL_CODE``
     - ``0x08``
     - ring 0 code, long-mode (L) bit set
   * - ``KERNEL_DATA``
     - ``0x10``
     - ring 0 data
   * - ``USER_DATA``
     - ``0x1B``
     - index 3, RPL 3 — placed **before** user code so SYSRET derives SS/CS correctly
   * - ``USER_CODE``
     - ``0x23``
     - index 4, RPL 3
   * - ``TSS_SELECTOR``
     - ``0x28``
     - 16-byte descriptor across slots 5 and 6

The ``Tss`` is a ``packed struct`` with compile-time offset tripwires (``rsp0`` @ 0x04,
``ist1`` @ 0x24, ``iopb_offset`` @ 0x66). Two 16 KiB stacks back ``rsp0`` (the stack the CPU
switches to on a privilege change) and ``ist1`` (the double-fault stack). ``setKernelStack``
is called by the scheduler on every thread switch so a trap from a running user process lands
on that process's kernel stack. ``load()`` runs ``lgdt``, reloads CS via a far return
(``lretq``), and reloads the data segments; ``loadTss`` runs ``ltr``.

IDT + exception handlers (``arch/idt.zig``)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

256 comptime-generated naked stubs normalize the stack (pushing a dummy ``0`` error code for
vectors that don't push one — real error codes only on 8, 10–14, 17, 21, 29, 30), push the
vector number, and jump to a single trampoline ``isrCommon`` which saves all 15 GP registers,
calls the Zig ``isrHandler``, restores, drops vector + error code, and ``iretq``\ s.

* ``InterruptFrame`` is an ``extern struct`` of ``u64`` whose field order exactly mirrors the
  pushes.
* Gate type ``0x8E`` (present, DPL 0, 64-bit interrupt gate); selector ``KERNEL_CODE``.
* Dispatch: vector < 32 → call the optional ``fault_hook`` (ring-3 recovery), else
  ``dumpException`` and ``hang()`` (``cli; hlt`` forever). Vector 3 (``#BP``) is recoverable
  (the boot self-test executes ``int3`` and recovers). Vectors 32–47 →
  ``pic.handleIrq``. Vector ``0xFF`` (LAPIC spurious) → no-op.
* ``dumpException`` prints vector + mnemonic, decodes the ``#PF`` error-code bits and reads
  ``CR2``, and dumps all GPRs and ``CR0``/``CR2``/``CR3``/``CR4``.
* Vector 8 (``#DF``) runs on **IST1**, a known-good stack even if the kernel stack is corrupt.

8259 PIC + 8254 PIT (``arch/pic.zig``)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Remaps master IRQ0–7 → vectors 32–39 and slave IRQ8–15 → vectors 40–47 (the range the IDT
populated). Ports: master ``0x20``/``0x21``, slave ``0xA0``/``0xA1``; PIT channel 0 ``0x40``,
command ``0x43``; ``PIT_BASE_FREQ = 1193182 Hz``; ``VECTOR_OFFSET = 32``; ``TIMER_HZ = 100``.

* ``pitInit(hz)``: divisor = ``1193182 / hz``, command ``0x36`` (channel 0, lo/hi, mode 3
  square wave), at 100 Hz.
* **Shared/chained IRQ lines:** ``handlers[16]``, each up to ``MAX_SHARERS = 4`` handlers.
  ``register(irq, handler)`` appends and unmasks (via ``route_hook`` if APIC active, else
  ``clearMask``).
* ``handleIrq`` filters spurious master IRQ7 / slave IRQ15, **EOIs before** running handlers
  (the timer handler may context-switch away), then runs every sharer.
* Timekeeping: ``timerTick`` atomically increments ``tick_count`` and calls the optional
  ``on_tick`` (the scheduler's preemption hook); ``ticks()`` is an atomic monotonic load.
* APIC takeover hooks (``eoi_hook``, ``route_hook``, ``rerouteRegistered``, ``disable``)
  avoid a ``pic`` ↔ ``apic`` import cycle.

CPU features (``arch/cpu.zig``)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Shared MSR/CPUID/CR4 wrappers and security feature enables.

* MSR numbers: ``IA32_EFER 0xC0000080`` (bits ``SCE`` 0, ``NXE`` 11), ``IA32_STAR
  0xC0000081``, ``IA32_LSTAR 0xC0000082``, ``IA32_FMASK 0xC0000084``. ``rdmsr``/``wrmsr``.
* ``cpuid(leaf, subleaf)`` saves/restores ``EBX`` by hand (the compiler reserves it as the PIC
  base register under this build).
* ``enableSmepSmap()`` — checks CPUID leaf 7 subleaf 0 (EBX bit 7 = SMEP, bit 20 = SMAP) and
  sets ``CR4.SMEP`` (bit 20) / ``CR4.SMAP`` (bit 21) when present. Must run after ``vmm.init``.
* ``rdrandFill(buffer)`` — CPUID leaf 1 ECX bit 30; draws 64 bits at a time via ``RDRAND
  r64`` with a 10-try retry budget on ``CF=0``; returns false if absent or exhausted so the
  caller can fall back to a software seed.

ACPI (``acpi/acpi.zig``)
~~~~~~~~~~~~~~~~~~~~~~~~~~

Starting from the Limine RSDP (verified ``"RSD PTR "`` signature; checksum mismatch is only a
warning), follows the XSDT (64-bit entries, ACPI ≥ 2.0) or the RSDT (32-bit), enumerates every
SDT, and parses the MADT (``"APIC"``):

* type 0 — Processor Local APIC (counted if the enable flag is set),
* type 1 — I/O APIC (id, MMIO address, GSI base; up to 16),
* type 2 — Interrupt Source Override (source IRQ, GSI, polarity/trigger flags; up to 48),
* type 5 — 64-bit Local APIC Address Override.

Default LAPIC base ``0xFEE00000`` unless overridden. All fields read with
``std.mem.readInt`` (tables are byte-packed/unaligned). Accessors: ``lapicAddress``,
``ioApics``, ``isos``, ``cpuCount``, ``isReady``.

APIC: LAPIC + I/O APIC + LAPIC timer (``arch/apic.zig``)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Enables the modern interrupt controller and retires the legacy PIC, keeping the existing
vector layout (device IRQ N → vector 32+N) and ``pic.zig`` handler registry intact.

* LAPIC regs (MMIO via HHDM): ID ``0x20``, EOI ``0xB0``, TPR ``0x80``, SVR ``0xF0``; timer
  LVT ``0x320``, init ``0x380``, current ``0x390``, divide ``0x3E0``. ``IA32_APIC_BASE`` MSR
  ``0x1B`` bit 11 = global enable. ``SPURIOUS_VECTOR = 0xFF``.
* ``init()`` (no-op unless ACPI ready): ``cli``, ``pic.disable()``, enable LAPIC, TPR = 0,
  SVR = ``0x100 | 0xFF``, install ``pic.eoi_hook = eoi`` and ``pic.route_hook = routeIrq``,
  reroute registered IRQs, ``sti``.
* ``routeIrq`` programs an I/O APIC redirection entry applying ACPI source overrides (GSI
  remap, polarity, trigger), targeting the BSP, unmasking; ``routeIrqPci`` forces active-low +
  level-triggered for PCI INTx; ``maskIrq`` masks an IRQ.
* ``initTimer(100)`` — calibrates against 10 PIT ticks (divide ÷16), runs the LAPIC timer
  periodically on **the same vector 32** the PIT used (so ``timerTick`` and the uptime counter
  are reused), then masks IRQ0 (retires the PIT). Falls back to the PIT if calibration looks
  implausible (elapsed < 1000).
* ``pauseTimer`` / ``resumeTimer`` mask/unmask the LVT timer entry (the shell's full-system
  ``sleep``).

SYSCALL/SYSRET ABI (``arch/syscall.zig``)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

The fast system-call gate from ring 3.

* ``init()``: sets ``EFER.SCE``; ``STAR = (0x13 << 48) | (KERNEL_CODE << 32)`` (yields user
  CS ``0x23`` / SS ``0x1B``); ``LSTAR = &syscallEntry``; **``FMASK = 0x700``** (clears IF/DF/TF
  on entry); default kernel RSP = a static 16 KiB ``syscall_stack``.
* ``syscallEntry`` (naked): switches to the per-process kernel stack, saves user RIP (RCX) /
  RFLAGS (R11), marshals user registers into the C ABI, calls ``syscallDispatch``, restores,
  applies a **canonical-RIP guard** (CVE-2012-0217 mitigation: clamp a non-canonical RCX to 0
  so the fault occurs in ring 3), restores user RSP, ``sysretq``.

.. list-table:: System calls (number in ``RAX``; args ``RDI``/``RSI``/``RDX``)
   :header-rows: 1
   :widths: 12 16 72

   * - Number
     - Name
     - Behavior
   * - 1
     - ``SYS_write(fd, ptr, len)``
     - ``fd`` must be 1 or 2 (else ``EBADF -9``); ``n = min(len, 4096)``; the buffer must lie
       strictly below ``USER_LIMIT`` and be page-present + USER (``vmm.userRangeAccessible``),
       else ``EFAULT -14``; the single user-pointer deref is bracketed by ``STAC``/``CLAC`` to
       lift SMAP; bytes are copied to serial.
   * - 2
     - ``SYS_yield()``
     - ``scheduler.yield()``.
   * - 3
     - ``SYS_exit(code)``
     - routes to the installed ``exit_handler`` (``noreturn``); unknown numbers return
       ``ENOSYS -38``.

Ring-3 entry (``arch/usermode.zig``)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Transitions the CPU to CPL 3.

* ``enterRing3(entry, user_stack)`` (``noreturn``) — builds an ``iretq`` frame (SS ``0x1b``,
  RSP = user stack, RFLAGS ``0x202`` so IF is on and the process is preemptible, CS ``0x23``,
  RIP = entry) and ``iretq``\ s. The scheduler's user-thread trampoline calls this for real
  processes.
* ``usermodeEnter`` / ``usermodeResume`` — a ``longjmp``-style pair for the bounded self-test:
  enters ring 3 and resumes the kernel caller on completion or fault.
* ``faultHook`` (installed as ``idt.fault_hook``) — during the self-test, recovers a ``#GP``
  raised from CPL 3 by redirecting the frame to ``usermodeResume``.
* ``exitToKernel(code)`` (installed as ``syscall.exit_handler``) — restores the kernel RSP,
  ``sti``, and jumps to ``usermodeResume``.

Power (``arch/power.zig``)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~

No ACPI power management yet, so legacy/emulator mechanisms are used.

* ``reboot()`` (``noreturn``): ``cli``, then in order (1) pulse the CPU reset line via the
  8042 (drain input buffer, ``outb(0x64, 0xFE)``), (2) the ICH9/PIIX reset-control port
  ``0xCF9`` (write ``0x06`` then ``0x0E``), (3) a deliberate triple fault (zero-limit IDT +
  ``int3``).
* ``shutdown()`` (``noreturn``): ``cli``, then write ``SLP_EN`` (``0x2000``) to the QEMU
  PM1a_CNT ports ``0x604`` (q35) and ``0xB004`` (i440fx/Bochs); halts if unsupported.

3.2 Memory management
---------------------

PMM — physical memory manager (``mm/pmm.zig``)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

A **bitmap frame allocator** (1 bit per 4 KiB frame, 0 = free) over Limine's memory map,
accessed only through the HHDM (``physToVirt(phys) = hhdm_offset + phys``).

* ``init`` sizes a bitmap covering ``highest_addr`` (which includes bootloader-reclaimable
  regions, one of which can sit above usable RAM), bootstraps it into the first usable region
  ≥ 1 MiB large enough, marks all used, frees usable regions, and permanently reserves
  frame 0 (so ``alloc`` never returns 0) and the bitmap's own frames.
* ``alloc() ?u64`` — byte-at-a-time scan from a ``next_hint`` cursor (wrapping for one full
  sweep), skipping ``0xFF`` bytes and using ``@ctz(~byte)`` for the first free bit.
  ``allocZeroed()`` additionally zeroes the frame (used for page tables).
* ``free(phys)`` biases ``next_hint`` toward the freed space.
* ``allocContiguous(count, max_phys)`` / ``freeContiguous`` — N consecutive free frames
  strictly below a ceiling (the DMA path; ``DMA_MAX_ADDR = 0x100000000`` = 4 GiB); not zeroed.
* ``reclaimBootloader()`` frees recorded reclaimable regions (copied at init, up to 64, since
  the memory map lives in the memory it describes); runs only after leaving Limine's boot
  stack.

VMM — virtual memory manager (``mm/vmm.zig``)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Builds the kernel's own 4-level page tables (PML4 → PDPT → PD → PT) and takes over paging by
loading CR3.

* Entry flags: PRESENT(0), WRITE(1), USER(2), PWT(3), PCD(4), HUGE(7), NX(63);
  ``ADDR_MASK = 0x000FFFFFFFFFF000``. ``EFER.NXE`` enabled before any NX entry. ``CR4.LA57``
  must be 0 (4-level only; 5-level → fatal).
* **W^X mapping** at init: the HHDM with 2 MiB huge pages (RW + NX, spanning ≥ 4 GiB); the
  kernel image **per section** — ``.text`` R+X (read-only), ``.rodata`` R + NX,
  ``.data``/``.bss`` RW + NX, ``.limine_requests`` RW + NX.
* Public API: ``map`` / ``unmap`` (live kernel tables + ``invlpg`` flush);
  ``mapUncacheable`` (sets PCD for UC MMIO via the default PAT); ``isMapped``; exported
  ``FLAG_WRITE`` / ``FLAG_NX`` / ``FLAG_USER`` / ``FLAG_UC``.
* **Per-process address spaces:** kernel owns PML4 slots 256..511; ``createAddressSpace``
  makes a fresh PML4 with the kernel-half entries copied in (shared) and an empty low half.
  ``switchTo`` loads CR3; ``mapInto`` / ``unmapInto`` operate on a non-active space (no flush
  needed); ``destroyAddressSpace`` recursively frees the low-half tables. ``kernelSpace``,
  ``activeSpace``.
* ``userRangeAccessible(space, virt, len)`` — a ``copy_from_user``-style probe (every page
  PRESENT + USER) used by ``SYS_write`` before touching a user buffer.

Heap (``mm/heap.zig``)
~~~~~~~~~~~~~~~~~~~~~~~~

A ``std.mem.Allocator`` backed by the VMM: a first-fit, address-sorted free list with
forward/backward coalescing over an on-demand-grown virtual region.

* ``HEAP_BASE = 0xffffc00000000000`` (slot 384), ``HEAP_MAX`` = base + 4 GiB,
  ``INITIAL_HEAP = 64 KiB``, ``GROW_MIN = 64 KiB``.
* ``grow`` maps ``allocZeroed`` frames RW + NX at the top and donates them; returns false past
  ``HEAP_MAX``.
* The ``std`` bridge over-allocates ``header + alignment + len`` and stashes an
  ``AllocHeader`` before the aligned payload so ``free``/``resize``/``remap`` recover the
  block. ``vtAlloc`` **rejects oversized allocations** (``len > HEAP_SPAN`` or where the
  header/padding wouldn't fit) with overflow-safe arithmetic, preventing a ``usize`` wrap from
  producing a too-small block.

DMA (``mm/dma.zig``)
~~~~~~~~~~~~~~~~~~~~~

Physically-contiguous, sub-4 GiB, zeroed buffers for bus-master devices. ``Buffer{phys, virt
(HHDM alias), frames, len}`` with a ``bytes()`` slice. ``alloc(len)`` rounds up to frames and
calls ``pmm.allocContiguous(frames, DMA_MAX_ADDR)``; on x86 DMA is cache-coherent so no
special cache attributes are needed. ``free`` returns the whole run.

3.3 Scheduling and synchronization
----------------------------------

Scheduler (``sched/scheduler.zig``)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

A cooperative-**and**-preemptive round-robin scheduler over a fixed ``threads[MAX_THREADS=16]``
table; each thread has a private 32 KiB **guarded** kernel stack.

* ``switchContext(old, new)`` — hand-written assembly: push ``rbp/rbx/r12-r15``, store ``rsp``
  into ``*old``, load ``new`` into ``rsp``, pop, ``ret``.
* ``Thread`` — saved ``rsp``, ``stack`` slice, ``State`` (``ready``/``running``/``finished``/
  ``blocked``), ``name``, ``entry``, ``wake_tick``, plus process fields ``pml4``,
  ``kstack_top``, ``user_entry``, ``user_stack``.
* ``spawn(name, func)`` — guarded stack from ``kstack``, hand-built so the first ``ret`` enters
  ``threadStart`` (``sti`` then run the body) with ``threadExit`` as fall-through; stack top
  16-byte aligned for the System V ABI.
* ``yield()`` — IF-aware: snapshot RFLAGS, ``cli``, round-robin to the next ``ready`` thread,
  switch CR3 only if the target address space differs, ``switchContext``, restore IF.
* ``tick()`` (``pic.on_tick``) — wakes due sleepers (``pic.ticks()`` @ 100 Hz) then ``yield``\
  s **unless** ``sync.preemptDisabled()`` (don't switch mid-print).
* Blocking: ``sleep(ticks)``, ``block()`` / ``blockTimeout`` / ``wake(id)`` (callers hold IF
  disabled so a wakeup can't be lost).
* User processes: ``spawnUser`` (trampoline → ``usermode.enterRing3``); ``runUser`` /
  ``runUserStandalone`` run a single ring-3 process at a time and park the caller until the
  ``SYS_exit`` handler signals; ``dump()`` backs the shell ``ps``.

Guarded kernel stacks (``sched/kstack.zig``)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Each per-thread stack is 32 KiB (RW + NX) with **one unmapped guard page below it**, in the
``REGION = 0xffffe00000000000`` (slot 448) region, ``MAX_STACKS = 16``. An overflow past the
bottom hits the unmapped guard → ``#PF`` → an IDT crash dump at the overflow site instead of
silent corruption. ``init()`` pre-touches the region so the PML4 entry exists **before** any
address-space clone; ``alloc(i)`` is idempotent (reused thread id → same stack, no leak).

WaitQueue (``sched/waitqueue.zig``)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Blocks a thread until a device IRQ signals it. ``WaitQueue{waiters: u16 bitmask, pending:
bool}``. ``wait(timeout) → bool`` (true = signalled, false = timed out) consumes a pending
signal immediately (no lost wakeup), else sets its bit and blocks with a timeout safety net.
``signal()`` (IRQ-safe) sets ``pending`` if nobody waits, else wakes all waiters. First user:
the AC'97 player.

Mutex (``sched/mutex.zig``)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

A blocking (sleeping) mutex: a thread finding it held **deschedules** rather than spins.
``owner`` + a FIFO waiter ring (``MAX_WAITERS = 16``). ``lock`` enqueues self and ``block``\ s
(re-checking on wake — a wake is permission to retry, not a guarantee); ``unlock`` wakes one
FIFO waiter. Atomicity on a single core comes from masking interrupts across the critical
region.

Sync primitives (``sched/sync.zig``)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Imports nothing (breaks the cycle with serial/console). A nestable **print lock**
(``preempt_off`` counter via ``.acq_rel``/``.acquire`` atomics) — interrupts stay on (the
timer keeps ticking) but the scheduler declines to ``yield`` while the counter is nonzero, so
a print can't be split. Plus IF helpers ``saveAndDisableInterrupts`` / ``restoreInterrupts``
used by Mutex/WaitQueue to make "decide to wait" + "block" atomic against the waking IRQ.

3.4 Drivers
-----------

Serial / COM1 (``drivers/serial.zig``)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

16550 UART at base ``0x3F8``, 38400 baud 8N1, FIFOs on, polled TX. The kernel's primary log
channel and the home of the port-I/O primitives (``outb``/``inb``/``outw``/``inw``/``outl``/
``inl``) reused by every other driver. ``print`` (printf via ``std.io.Writer``, holds the
print lock), ``putc``, ``note`` (serial-only, bypasses the framebuffer mirror). Optional
``setMirror`` callback (the console registers itself so all logging appears on screen). RX:
``dataAvailable`` / ``readByteRaw`` / ``enableRxInterrupt`` (IRQ4) for the serial shell.

Framebuffer console (``drivers/console.zig``)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

A text console over Limine's 32-bpp linear framebuffer using the embedded Tamzen 8×16 PSF
font (PSF1/PSF2 parsed at comptime; glyphs blitted row-by-row). Terminal emulation handles
``\n``/``\r``/backspace/printable-with-wrap and an ANSI/CSI subset: ``ESC[2J`` clear,
``ESC[H`` home, ``ESC[K`` erase-to-EOL, ``ESC[nC``/``ESC[nD`` cursor right/left (colors and
other CSI ignored; fixed light-grey on near-black). **Scrollback** is an in-memory grid
(256 cols × 1024 lines, circular), driven by PageUp/PageDown and the mouse wheel. A blinking
underline cursor toggles every 50 timer ticks (polled from the shell loop, not IRQ).
**Not yet:** scalable/TrueType fonts, graphics primitives beyond glyph/fill, double-buffering,
multiple colors.

PS/2 keyboard (``drivers/keyboard.zig``)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

8042 controller, data ``0x60`` / status ``0x64``, **IRQ1**. Scancode set 1, comptime
translation tables, Shift + Caps Lock handling (letters upper when Shift XOR Caps). Extended
(``0xE0``) keys are emitted as ANSI escapes (arrows, Home/End, Delete ``ESC[3~``, PageUp
``ESC[5~``, PageDown ``ESC[6~``) so keyboard and serial input parse identically. The IRQ
handler drains all queued bytes (stopping at an AUX/mouse byte). Decoded characters go to a
``sink`` (the shell). Has host unit tests.

PS/2 mouse (``drivers/mouse.zig``)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Shares the 8042 (AUX channel), **IRQ12**. Only the **scroll wheel** is used (no on-screen
cursor yet): wheel notches drive ``console.scrollUpBy`` / ``scrollDownBy``, capped at
``MAX_WHEEL_LINES = 3`` lines/notch. Init runs with interrupts off and **protects the
keyboard's command-byte bits** so enabling the mouse can never disable the keyboard; performs
the IntelliMouse handshake (sample rates 200/100/80) to get 4-byte wheel packets.

ATA PIO disk (``drivers/ata.zig``)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Legacy primary-bus master, 28-bit LBA, ports ``0x1F0–0x1F7`` + alt-status ``0x3F6``, polled
(no IRQ). Exists only on QEMU's i440fx (``-M pc``, PIIX3 IDE); absent on q35.
**Read and write:** ``init`` probes via IDENTIFY (rejects ATAPI/SATA), ``read(lba, count,
dst)`` (``rep insw``), ``write(lba, count, src)`` (``rep outsw`` + cache flush);
``SECTOR_SIZE = 512``; bounds-checked; spin loops are capped so a stuck controller can't hang
the kernel. The installer uses ``write`` to lay down a system image.

AHCI / SATA (``drivers/ahci.zig``)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

PCI class ``0x01`` subclass ``0x06``; ABAR = BAR5, mapped **uncacheable** at
``0xffffffffe1000000``. Structures (command list, received-FIS, one command table, data
buffer) come from ``dma.alloc``. Bring-up: AHCI-enable → HBA reset → re-enable → pick the
first implemented port with link up → confirm a plain SATA disk signature (``0x101``) → hook
the PCI INTx → start the engine. Supports **IDENTIFY** (``0xEC``) and **READ DMA EXT**
(``0x25``, 48-bit LBA). Completion is a hybrid wait (block on a ``WaitQueue`` woken by the IRQ,
with a poll/timeout fallback). **Read-only today** — the write command constant and W-flag
plumbing exist but no ``write()`` is exported.

AC'97 audio (``drivers/ac97.zig``)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

PCI class ``0x04`` subclass ``0x01``; NAM mixer = BAR0 (I/O), NABM bus-master = BAR1 (I/O);
PCI INTx hooked. ``init`` does a cold reset, waits for the primary codec ready, max volume,
enables VRA (variable rate, 48 kHz DAC), generates a 440 Hz **square wave** (no FP), starts
DMA, and verifies the buffer position advances. ``play(rate, ctx, fill)`` streams 16-bit
stereo PCM over an 8-buffer DMA ring (``RING_FRAMES = 2048``), refilled on the
buffer-completion IRQ (hybrid ``WaitQueue`` wait), with VRA rate-matching and mono→stereo
expansion. **Playback only** — no capture.

RTC / CMOS clock (``drivers/rtc.zig``)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

CMOS index ``0x70`` / data ``0x71``, no IRQ. ``now()`` waits for UIP clear, reads all six
fields twice requiring two agreeing snapshots (rollover guard), decodes BCD↔binary and
12h↔24h per Status B, and adds ``CENTURY_BASE = 2000``. Returns a ``DateTime`` (labeled UTC).
Backs the shell ``date`` command. **Read-only** — cannot set the clock.

PCI bus (``drivers/pci.zig``)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Legacy **config mechanism #1** (address ``0xCF8`` / data ``0xCFC``). ``init`` brute-force
scans all buses × slots (probing functions 1–7 only on multifunction devices), records up to
``MAX_DEVICES = 32`` devices, logs the class name, and decodes/sizes each BAR (I/O vs MMIO32/
64, prefetch) via the quiesce-write-ones-readback-restore dance. API: ``list`` and
``findByClass`` (used by the AHCI and AC'97 drivers). **Not yet:** ECAM/PCIe MCFG, capability
walking, MSI/MSI-X.

3.5 Filesystems
---------------

FAT32 (``fs/fat32.zig``) — read **and** write
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Mounts a raw FAT32 volume — ``mount()`` (whole disk) or ``mountAt(start)`` (a partition, e.g.
the ESP at LBA 2048) — over the ATA PIO driver, validating the BPB (``0xAA55`` signature,
512-byte sectors). 512-byte sectors only.

* **Read:** ``resolve(path)`` → ``Node{cluster, size, is_dir}`` (case-insensitive path walk);
  ``ls`` / ``cat``; ``readFile(path, dst)``; ``open(path)`` → a ``FileReader`` streaming
  cursor (constant memory, used by WAV playback). **LFN (long filenames)** are assembled from
  ``ATTR_LFN`` runs (13 UTF-16 chars each, bounds-hardened; non-ASCII → ``?``); 8.3 names
  honor the NT lowercase flags.
* **Write** (enough for the editor and installer to save): a write-back one-sector FAT cache;
  ``allocCluster`` (with a next-free hint), ``freeChain``, ``mkdir`` (writes ``.``/``..``),
  ``writeFile(path, data)`` (create or overwrite — grows/shrinks the chain, batches contiguous
  clusters into multi-sector PIO writes, flushes the FAT before the directory entry for
  crash-safety, and emits a full LFN run for non-8.3 names such as ``limine.conf``).
* **Robustness:** every cluster-chain walk is capped at ``total_clusters + 2`` hops to defeat a
  circular/corrupt FAT; a FAT read error is treated as end-of-chain.
* **Not supported:** file deletion, rename, FSInfo maintenance on write.

FAT32 formatter (``fs/fatformat.zig``)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

A pure ``mkfs`` over an ``anytype`` block sink (so it is host-testable against RAM).
``run(dev, volume_lba, total_sectors)`` writes the boot sector/BPB, FSInfo, backup boot +
FSInfo (sectors 6/7), two FATs, and an empty root cluster (32 reserved sectors, 2 FATs, 1
sector/cluster, root cluster 2). Rejects regions yielding fewer than ``65525`` clusters.

GPT writer (``fs/gpt.zig``)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

``write(dev, total_sectors, part_first_lba)`` lays a protective MBR, a primary GPT header
(``"EFI PART"``), a 128 × 128-byte entry array with one **EFI System Partition** entry, and a
backup array + header at the disk end. CRC-32 is computed over the header and the full 16 KiB
array (incrementally, without materializing it).

LFN encoding (``fs/lfn.zig``)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Pure, host-tested long-filename helpers: ``entryCount``, the 8.3 short-name ``checksum``,
``buildAlias`` (``BASE~n``), and ``fillEntry`` (one 32-byte LFN entry).

WAV / RIFF (``fs/wav.zig``)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

``parse(FileReader)`` → ``Format{channels, sample_rate, bits, data_bytes}`` for AC'97
playback: validates RIFF/WAVE, requires PCM 16-bit mono/stereo, and stops at the ``data``
chunk. **Hardened** — every chunk size is checked against the bytes remaining so a bogus
~2 GiB ``data`` size on a tiny file is rejected (no over-read or hang). ``Stream.fill`` feeds
16-bit stereo to AC'97, expanding mono → interleaved stereo on the fly.

3.6 Program loader (``loader.zig``)
-----------------------------------

Loads an init program off the FAT32 disk, auto-detecting the format by sniffing the first
four bytes (``\x7fELF`` → ELF, else flat). The file is slurped into a static 1 MiB buffer
(short reads — truncated chains — are rejected).

* **Two address-space modes:** ring-0 (map live in kernel space, run as a C function) or a
  process PML4 from ``vmm.createAddressSpace`` (map USER pages, run at ring 3).
* **Three-stage W^X for every page, both formats:** (1) map RW + NX from a zeroed frame (so
  the ``.bss`` tail is zero), (2) copy bytes in, (3) remap to final permissions before the
  jump — a page is never simultaneously writable and executable.
* **ELF path:** validates the 64-bit LE x86-64 header (``ET_EXEC`` or ``ET_DYN``), walks
  ``PT_LOAD`` with overflow-safe arithmetic and **per-segment bounds checks** against
  ``USER_LIMIT`` (ring 3: the whole segment strictly below it; ring 0: in the higher half).
  Per-segment final permissions come from ``p_flags`` (W ⇒ RW+NX, X-only ⇒ RX, else RO+NX),
  and **W^X is enforced even if a broken header requests W+X** (the execute bit is stripped).
  ET_DYN/PIE is slid to the load base (RIP-relative only; no relocations applied). An ELF with
  no ``PT_LOAD`` is rejected.
* **Flat path:** raw code at a fixed base, entered at byte 0.
* **Entry points:** ``exec(path)`` (legacy ring-0 contract: entered as ``fn() callconv(.C)
  u64`` and must return ``INIT_MAGIC = 0xB017B007``); ``execUser(path)`` (ring-3 process via
  ``scheduler.runUser``, true iff exit code 0); ``execUserCtx(path, standalone)``.
  Layout: ring-3 flat load base ``0x400000``, user stack top ``0x800000`` (16 KiB, RW+NX+USER).
* Teardown unmaps and frees every tracked page and destroys the process address space.
  ``selfTest()`` prefers ``/INIT.ELF``, falls back to ``/INIT``, runs it as a standalone
  ring-3 process, and skips quietly with no disk.

3.7 Authentication (``auth.zig``)
---------------------------------

Real password hashing with **scrypt** in PHC string format
(``$scrypt$ln=...,r=...,p=...$salt$hash``). Hashes we create use ``PARAMS = {ln = 12 (N =
2^12), r = 8, p = 1}`` — roughly 4 MiB of memory-hard work.

.. note::

   The source (``src/auth.zig``) uses ``ln = 12``; the prose ``README.rst`` / ``docs/auth.rst``
   say ``ln = 14``. The integer-only, single-threaded scrypt was chosen over Argon2id because
   Zig's Argon2 spawns threads, which have no implementation on a freestanding target.

``verify(allocator, phc, password)`` reads the cost from the stored hash (so raising
``PARAMS`` later does not invalidate existing credentials); ``hash(allocator, password,
out)``. The module takes an allocator parameter rather than importing the kernel heap, so it
compiles for the host and is covered by a unit test. The same code runs in the host
``tools/mkpasswd.zig`` and in the kernel login.

3.8 Editor (``editor.zig``)
---------------------------

A tiny nano-style editor: loads a file into a fixed 8 KiB buffer (missing file → new/empty),
supports arrow movement (line-aware, column-preserving), Backspace/Enter/printable editing,
**Ctrl-S** to save via ``fat32.writeFile``, and **Ctrl-X / Ctrl-Q** to exit. Renders with
plain ANSI (clear/home/absolute cursor — full on serial; the framebuffer console handles
clear+text but not absolute positioning). Reads input one byte at a time from a ``getKey``
callback the shell supplies.

3.9 Installer (``install.zig``)
-------------------------------

An in-guest installer with two modes, with payloads handed in by ``main`` before the shell
starts. The ``install`` command appears only when a payload is present.

* **Option B — construct the disk in-kernel (preferred when the construct payload is
  present).** Prompts for a username (echoed) + password (masked), hashes with ``auth.hash``
  **before touching the disk** (then zeroes the plaintext), and builds the target disk:
  ``gpt.write`` (ESP from LBA 2048), ``fatformat.run`` the ESP, ``fat32.mountAt(2048)``,
  ``mkdir`` the ``/EFI/BOOT`` + ``/boot/limine`` + ``/OBSIDIA`` tree, and ``writeFile`` the
  kernel (``/boot/kernel.elf``), ``BOOTX64.EFI``, ``limine.conf`` (LFN), and ``/OBSIDIA/AUTH``
  (``user:phc``). The result boots standalone under UEFI.
* **Option A — clone a prebuilt image.** Copies a host-assembled GPT system image
  (delivered as the Limine module ``system.img``) sector-by-sector in 256-sector chunks,
  **skipping all-zero chunks** so a 64 MiB clone writes only the few MiB actually in use.

.. note::

   The prose ``docs/install.rst`` describes only Option A as current and calls Option B a
   future feature; the source implements **both**, and the integration harness exercises the
   in-kernel Option B end to end.

3.10 Shell (``shell.zig``)
--------------------------

An interrupt-driven REPL over COM1 and the framebuffer console. Both input producers — the
UART RX IRQ (IRQ4, ``onSerialIrq``) and the keyboard IRQ (via ``feed``) — push bytes into a
single SPSC ring (256 bytes); the run loop drains it and ``hlt``\ s when idle. It is itself a
scheduled kernel thread. Features a full line editor (insert/backspace/delete-forward, cursor
movement, a 16-entry deduplicating history with Up/Down recall, an ANSI/CSI parser for
arrows/Home/End/Delete/PageUp/PageDown), a working directory (``cwd`` with ``.``/``..``
normalization and relative-path resolution), and PageUp/PageDown scrollback.

.. list-table:: Built-in commands
   :header-rows: 1
   :widths: 22 78

   * - Command
     - Action
   * - ``help``
     - List commands (shows ``play`` only if AC'97 present, ``install`` only with a payload).
   * - ``clear``
     - ANSI erase + home.
   * - ``echo <text>``
     - Echo the argument.
   * - ``mem``
     - Free / total frames (and MiB) from the PMM.
   * - ``uptime``
     - ``pic.ticks()`` at 100 Hz.
   * - ``history``
     - List recent commands.
   * - ``ps``
     - ``scheduler.dump()`` — the thread table.
   * - ``cd [dir]``
     - Change ``cwd`` (validated via ``fat32.resolve``; no arg → ``/``).
   * - ``ls [path]``
     - Directory listing (8.3 + LFN).
   * - ``cat <path>``
     - Stream a file to output.
   * - ``edit <path>``
     - Launch the editor (creates the file on save → FAT32 write).
   * - ``exec <path>``
     - Run an ELF64/flat binary as a **ring-3** process.
   * - ``exec0 <path>``
     - Run a flat binary via the legacy **ring-0** contract.
   * - ``play <file>``
     - AC'97 playback: ``.wav`` parsed + streamed (mono → stereo); else raw 16-bit stereo
       48 kHz PCM.
   * - ``date``
     - ``YYYY-MM-DD HH:MM:SS UTC`` from the RTC.
   * - ``install``
     - Run the installer (construct or clone).
   * - ``sleep``
     - Full-system sleep: mask the LAPIC timer, deep-halt until an input IRQ, resume, discard
       the waking key.
   * - ``restart`` / ``reboot``
     - ``power.reboot``.
   * - ``shutdown`` / ``poweroff``
     - ``power.shutdown``.
   * - ``crash``
     - Write to ``0xdeadbeef`` to demonstrate the ``#PF`` crash dump.

**Login gate:** the credential is ``user:phc``, sourced first from the Limine **auth module**
(preferred — works on GPT without partition parsing), else ``/OBSIDIA/AUTH`` via
``fat32.readFile``. Prompts username + masked password and verifies both (username equality +
``auth.verify``), looping until correct. **No credential ⇒ an open shell** (for disk-less
development boots).


4. Build / Run / Install / Test
===============================

Prerequisites
-------------

* **Zig 0.14.0** (pinned; the minimum in ``build.zig.zon``). For building the kernel only Zig
  is needed.
* For assembling and booting the ISO: ``xorriso``, ``mtools``, ``qemu-system-x86``, and OVMF
  (UEFI firmware for QEMU).
* The **Limine** binaries (``v8.x-binary`` branch; ``make -C limine`` builds the small host
  installer utility — the ``limine/`` directory is git-ignored).
* The Limine Zig bindings (``48cf/limine-zig``, API revision 3) are fetched into the Zig
  cache on first build.

Build
-----

.. code-block:: sh

   zig build            # produces zig-out/bin/kernel.elf

The freestanding x86-64 target disables SSE/AVX/MMX and uses soft-float; the kernel uses the
custom ``linker-x86_64.lds`` higher-half script.

Run
---

.. code-block:: sh

   ./run.sh

``run.sh`` compiles, assembles ``obsidia.iso``, installs the Limine BIOS stage, and boots in
QEMU with serial routed to the terminal (KVM-accelerated). It boots the **i440fx** machine
(``-M pc``) — required for the PIIX3 IDE controller the ATA PIO driver needs (q35 has only
AHCI/SATA) — and attaches a persistent 64 MiB FAT32 disk (``obsidia-disk.img``), seeded with
sample files and three init programs (``/INIT`` flat ring-3, ``/INIT0`` flat ring-0,
``/INIT.ELF`` a real linked ELF64). ``-boot d`` forces CD boot (a FAT32 disk carries a
``0x55AA`` signature the BIOS would otherwise try to boot).

Headless boot test (the CI method)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

.. code-block:: sh

   qemu-system-x86_64 -M q35 -m 512M -cdrom obsidia.iso \
     -chardev stdio,id=char0,logfile=boot.log,signal=off \
     -serial chardev:char0 -display none -no-reboot
   grep -q BOOT_OK boot.log && echo "BOOT OK" || echo "BOOT FAILED"

Install (in QEMU)
-----------------

.. code-block:: sh

   ./install.sh           # build the installer + boot it; type `install`, then `shutdown`
   ./install.sh boot      # boot the installed disk; log in

Sub-commands include ``build`` / ``install`` / ``boot`` (Option A) and ``construct-build`` /
``construct`` / ``construct-boot`` (Option B). Credentials are prompted, or set via
``OBSIDIA_USER`` / ``OBSIDIA_PASS``. Passwords are never stored in plaintext — only the scrypt
PHC hash is written.

Test harness
------------

.. code-block:: sh

   zig build test     # host unit tests
   tests/run.sh       # full integration harness (boots in QEMU)

* **Host unit tests** (``src/tests.zig``, compiled for the native target) cover keyboard
  scancode translation + escape sequences, console PSF font parsing, scrypt hash/verify,
  GPT layout + CRC, FAT32 ``mkfs`` layout, and LFN encoding. (The prose ``docs/tests.rst``
  lists only keyboard + console; the source aggregates all six.)
* **Integration harness** (``tests/run.sh``) builds the kernel, runs the unit tests, assembles
  the ISO, then boots headless under **both legacy BIOS and UEFI**, asserting every subsystem
  success marker — GDT/TSS, IDT + ``int3`` self-test, PIC/PIT, PMM + self-test, VMM + W^X +
  uncacheable MMIO + guard page, SMEP/SMAP, heap, console + scrollback, keyboard, mouse,
  ``BOOT_OK``, ACPI/MADT, APIC/I-O APIC/LAPIC timer, scheduler round-robin / preemption /
  blocking sleep / mutex, ring-3 + syscall/sysret/write/exit, per-process address space, PCI
  enumeration, and DMA. It then runs dedicated boots for: ATA PIO (IDENTIFY size + read/write,
  no-disk graceful), AC'97 (codec ready, mixer, BDL/DMA, completion IRQs), AHCI/SATA (enable,
  signature, IDENTIFY, sector-0 DMA read), FAT32 (mount / ``ls`` 8.3+LFN / ``cat`` / nested
  path), AC'97 ``play`` (raw PCM + stereo/mono WAV + malformed-WAV rejection), the init loader
  (ring-3 flat + ELF with per-segment W^X, an **out-of-bounds ``/EVIL.ELF`` that must be
  rejected and never run**, the legacy ring-0 path), ``cd`` + editor FAT32 write (verified
  independently with ``mtools``), shell commands, RTC ``date`` format, scrypt login
  (wrong-then-right), history recall, full-system sleep, power commands, optional framebuffer
  render + scrollback screenshots, and the in-kernel installer (Option B) building a disk that
  is then booted under UEFI and logged into. Exit status is non-zero if any check fails.
* **CI** (``.github/workflows/build.yml``) builds with Zig 0.14.0, assembles the ISO, boots
  under both UEFI and legacy BIOS, and asserts ``BOOT_OK``; the ISO is uploaded as an artifact.


5. Security and hardening posture
=================================

.. list-table::
   :header-rows: 1
   :widths: 26 74

   * - Mechanism
     - What it provides today
   * - **W^X (write XOR execute)**
     - The kernel image is mapped per-section (``.text`` R+X, everything else NX); the heap
       and kernel stacks are RW+NX; the loader maps every user/kernel page through a
       three-stage RW→copy→final-perm cycle so no page is ever writable and executable at once,
       and it strips the execute bit even from a broken ELF header requesting W+X. ``EFER.NXE``
       is enabled before any NX entry.
   * - **SMEP / SMAP**
     - ``CR4.SMEP`` (ring 0 cannot execute USER pages) and ``CR4.SMAP`` (ring 0 cannot read/
       write USER pages) are enabled when CPUID advertises them. The only legitimate kernel →
       user data access (``SYS_write``) brackets itself with ``STAC``/``CLAC``.
   * - **ELF / segment bounds checks**
     - Every ``PT_LOAD`` is validated with overflow-safe arithmetic against ``USER_LIMIT``
       (ring 3) or the higher half (ring 0); file offsets and sizes are checked within the
       file; an ELF with no ``PT_LOAD`` is rejected.
   * - **Syscall hardening**
     - ``FMASK = 0x700`` clears IF/DF/TF on entry; user buffers are range- and
       page-permission-checked (``userRangeAccessible``) before any access; a canonical-RIP
       guard on ``sysret`` mitigates CVE-2012-0217.
   * - **Guard pages**
     - Each kernel stack has an unmapped guard page below it, turning an overflow into a
       ``#PF`` crash dump rather than silent corruption.
   * - **Uncacheable MMIO**
     - Device MMIO (e.g. the AHCI ABAR) is mapped with PCD set (UC memory type) via
       ``mapUncacheable``.
   * - **Hardware RNG**
     - ``RDRAND`` seeds the crypto RNG when available, with a TSC-stirred xorshift64 fallback.
   * - **Crash dumps**
     - The IDT turns otherwise-silent faults into a full register/control-register dump on
       serial (mirrored to the framebuffer) instead of a triple fault and silent reset.
   * - **Memory-hard login**
     - scrypt (PHC format), with the plaintext password zeroed after hashing in the installer.


6. Remaining work toward a basic desktop environment
====================================================

This is the principal gap analysis: everything not yet built, grouped and **dependency-
ordered**. Each later layer assumes the earlier ones. The kernel today is a single-core,
single-user-process-at-a-time system with no VFS, no demand paging, no fork/exec/wait, no
signals, no TTY layer, no networking, and a text-only console — all of which precede any GUI.

6.1 Process and file foundations (hard prerequisites for everything above)
--------------------------------------------------------------------------

#. **Per-process file-descriptor table.** Today ``SYS_write`` accepts only fds 1/2 and writes
   to serial; there is no FD table, no ``open``/``close``/``read``/``lseek``. *Prerequisite
   for:* a VFS, real I/O syscalls, shells/programs reading files.
#. **Virtual File System (VFS) layer.** A mount/inode/dentry abstraction so multiple backends
   (FAT32, devfs, procfs, a future ext-like FS) sit behind one path namespace. FAT32 exists as
   a concrete driver but is called directly, not through a VFS. *Depends on:* the FD table.
#. **Block / buffer cache.** A cache between filesystems and the disk drivers so reads/writes
   are not raw single-sector PIO every time, with write-back and eviction. *Depends on:* a
   unified block-device interface (ATA + AHCI behind one ``read``/``write``). AHCI also needs
   its **write** path finished (currently read-only).
#. **File I/O syscalls.** ``open``/``close``/``read``/``write``/``lseek``/``stat``/``mkdir``/
   ``unlink`` routed through the VFS. *Depends on:* FD table + VFS. FAT32 still needs
   **delete/rename** for a usable writable filesystem.

6.2 Memory model for real programs
----------------------------------

#. **Demand paging.** Map pages lazily on first fault (the loader currently maps every
   segment eagerly). *Depends on:* a page-fault handler that resolves rather than dumps (the
   IDT currently only dumps + halts).
#. **``brk`` / ``mmap`` / ``munmap``.** A user heap and file/anonymous mappings, with the
   user-half VMM bookkeeping per process. *Depends on:* demand paging + per-process VMAs
   (virtual-memory-area tracking, which does not exist yet).
#. **Copy-on-write.** Needed for an efficient ``fork``. *Depends on:* demand paging + a frame
   reference-count in the PMM (the bitmap allocator has no refcounts today).

6.3 Process lifecycle and IPC
-----------------------------

#. **``fork`` / ``exec`` / ``wait`` / process IDs and a process table.** Today there is a
   single global "run one ring-3 process at a time" slot and no PID space, parent/child links,
   or exit-status reaping. *Depends on:* per-process address spaces (exist), FD tables, COW
   (for ``fork``), and the loader generalized from "run init" to "exec arbitrary program".
#. **Signals.** Delivery, default actions, handlers, masks; ``kill``. *Depends on:* the process
   table + a per-process trap-return path that can run a handler.
#. **TTY / PTY layer + job control.** A line discipline (canonical/raw modes, echo, signal
   keys like Ctrl-C/Ctrl-Z), controlling terminals, process groups, and sessions. The shell
   currently owns the serial/keyboard ring directly; a desktop terminal emulator needs PTYs.
   *Depends on:* signals (for Ctrl-C → SIGINT) + the FD/VFS layer (a TTY is a device file).

6.4 Kernel infrastructure for responsiveness and devices
--------------------------------------------------------

#. **SMP + spinlocks.** Bring up application processors (the MADT already enumerates CPU
   count), per-CPU LAPIC timers, and real spinlocks. Today everything is single-core and
   mutual exclusion is "mask interrupts" / "disable preemption", which does not scale to
   multiple cores. *Prerequisite for:* a responsive multi-core desktop; many later subsystems
   become much easier to keep correct once locking is real.
#. **FPU / SSE enable + lazy FP context.** The toolchain currently forbids SSE/AVX/MMX because
   the FPU is never configured. A desktop needs floating point (graphics math, audio resampling,
   font rasterization). This requires ``CR0``/``CR4`` setup (``FXSAVE``/``XSAVE``), per-thread
   FP state save/restore, and **re-enabling the disabled target features in ``build.zig``**.
   *Prerequisite for:* TrueType/scalable fonts, alpha blending, most graphics and audio DSP.
#. **Timer / callout subsystem.** A general timer wheel / callout queue (one-shot and periodic
   callbacks, high-resolution sleeps) beyond the single 100 Hz tick. *Depends on:* the LAPIC
   timer (exists) generalized; underpins animation, input timing, and timeouts.
#. **MSI / MSI-X.** Message-signalled interrupts (and PCIe ECAM/MCFG + capability walking in
   the PCI driver) so modern devices (NICs, NVMe, GPUs) can deliver interrupts without sharing
   INTx lines. *Depends on:* the PCI driver gaining capability enumeration.
#. **Deferred work (softirqs / tasklets / workqueues).** A bottom-half mechanism so IRQ
   handlers stay short and heavy work runs in thread context. *Depends on:* the scheduler
   (exists) + per-CPU state (from SMP).

6.5 Networking (optional for a local desktop, required for a useful one)
------------------------------------------------------------------------

#. **NIC driver** — virtio-net (easiest under QEMU) and/or Intel e1000. *Depends on:* PCI
   (exists), DMA (exists), MSI/MSI-X (preferred) or INTx, and the deferred-work mechanism.
#. **Network stack** — Ethernet/ARP, IPv4, ICMP, UDP, TCP, plus sockets and a DNS/DHCP client.
   *Depends on:* the NIC driver + the FD/socket layer + the buffer-management/deferred-work
   infrastructure.

6.6 Graphics and the GUI path (the desktop itself)
--------------------------------------------------

Everything below depends on the **FPU/SSE enable** (6.4.2) for practical font rasterization
and blending, and benefits from the **timer/callout** subsystem (6.4.3) for animation/vsync
pacing. The current console writes glyphs directly to Limine's framebuffer with a fixed bitmap
font, a single color, and no double-buffering — it is a debugging console, not a graphics
stack.

#. **Framebuffer graphics layer.** Promote the framebuffer from "text console" to a real 2-D
   surface: a backbuffer with **double-buffering**, **write-combining (WC) mapping** of
   framebuffer memory (the VMM has ``mapUncacheable``/PCD but not a WC/PAT entry, which is what
   a framebuffer wants for fast linear writes), blits, fills, line/rect primitives, and alpha
   blending. *Prerequisite for:* everything else here.
#. **Mouse cursor + input event routing.** Use the PS/2 mouse's **motion and buttons** (today
   only the wheel is consumed, with no on-screen pointer), draw and move a hardware-independent
   software cursor, and build a unified input-event queue (key + pointer events with focus
   routing) feeding clients. *Depends on:* the graphics layer (to draw the cursor) + an
   event-delivery path (sockets/pipes or a kernel input device).
#. **Windowing / compositor layer.** A surface/window abstraction with a compositor that
   composes client buffers onto the screen (clipping, z-order, damage tracking, redraw).
   *Depends on:* the graphics layer + input routing + an IPC channel to clients (pipes/sockets
   from 6.3/6.5).
#. **Font rendering.** At minimum a scalable rasterizer (the project already ships the Tamzen
   bitmap PSF font under ``src/fonts`` / ``docs/fonts``; a desktop wants antialiased,
   variable-size text). *Depends on:* the FPU/SSE enable + the graphics layer's alpha
   blending.
#. **Widget toolkit.** Buttons, labels, text fields, lists, layout — the building blocks
   applications draw with. *Depends on:* the compositor + font rendering + input events.
#. **Window manager.** Window decorations, move/resize, focus policy, stacking/tiling.
   *Depends on:* the compositor + the toolkit + input routing.
#. **Basic desktop shell.** A wallpaper/root window, a launcher/taskbar, and a first set of
   GUI applications (a graphical terminal emulator backed by a **PTY** from 6.3, a file
   manager backed by the **VFS** from 6.1). *Depends on:* essentially all of the above —
   the desktop shell is the integration point, not a standalone unit.

Dependency summary
------------------

* The **process/file foundations (6.1)** and the **memory model (6.2)** gate the **process
  lifecycle (6.3)**, which gates a real **TTY/PTY** layer — without which a desktop terminal
  cannot exist.
* **FPU/SSE (6.4.2)** is a hard prerequisite for practical **font rendering (6.6.4)** and
  blending, and therefore for the toolkit and desktop shell.
* The **graphics layer (6.6.1)** gates the cursor, compositor, toolkit, WM, and shell — in
  that order.
* **SMP + real locking (6.4.1)** is not strictly required to *draw* a desktop, but is required
  for it to be *responsive* and is the right foundation before the system grows many
  concurrent GUI clients.
* **Networking (6.5)** is optional for a purely local desktop but required for any networked
  application.


Appendix A. Source map
======================

.. list-table::
   :header-rows: 1
   :widths: 34 66

   * - Path
     - Purpose
   * - ``src/main.zig``
     - Entry ``_start``, Limine requests, ordered init, panic handler, RNG seed.
   * - ``src/shell.zig``
     - Interactive REPL + login gate.
   * - ``src/auth.zig``
     - scrypt password hashing / verification (PHC).
   * - ``src/install.zig``
     - In-guest installer (construct in-kernel / clone an image).
   * - ``src/loader.zig``
     - ELF64 + flat program loader (ring 3 + legacy ring 0).
   * - ``src/editor.zig``
     - Nano-style text editor (FAT32 write).
   * - ``src/arch/{gdt,idt,pic,apic,cpu,syscall,usermode,power}.zig``
     - Segmentation/TSS, interrupts, legacy + modern interrupt controllers, CPU features,
       syscall ABI, ring-3 entry, reboot/shutdown.
   * - ``src/acpi/acpi.zig``
     - RSDP → RSDT/XSDT → MADT parsing.
   * - ``src/mm/{pmm,vmm,heap,dma}.zig``
     - Frame allocator, page tables + address spaces, kernel heap, DMA buffers.
   * - ``src/sched/{scheduler,kstack,waitqueue,mutex,sync}.zig``
     - Scheduler, guarded stacks, device wait queues, sleeping mutex, print lock / IF helpers.
   * - ``src/drivers/{serial,console,keyboard,mouse,ata,ahci,ac97,rtc,pci}.zig``
     - UART, framebuffer console, PS/2 keyboard + mouse, ATA PIO, AHCI/SATA, AC'97 audio, RTC,
       PCI bus.
   * - ``src/fs/{fat32,fatformat,gpt,lfn,wav}.zig``
     - FAT32 (read+write), FAT32 mkfs, GPT writer, LFN encoding, WAV parsing.
   * - ``src/fonts/Tamzen8x16.psf``
     - Embedded bitmap font (Tamzen, freely licensed).
   * - ``build.zig`` / ``linker-x86_64.lds`` / ``limine.conf``
     - Freestanding target (SSE/AVX/MMX off, soft-float), higher-half layout, Limine boot
       entry.
   * - ``run.sh`` / ``install.sh`` / ``tests/run.sh``
     - Build + boot, installer driver, integration harness.
   * - ``tools/mkpasswd.zig``
     - Host helper to produce a ``user:phc`` credential line.
