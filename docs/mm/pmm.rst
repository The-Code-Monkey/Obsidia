===========
``src/mm/pmm.zig``
===========

   A bitmap frame allocator that manages all of physical RAM in 4 KiB frames over Limine's memory map.

What it does
============

The physical memory manager (PMM) walks the memory map Limine provides and tracks every 4 KiB frame with a single bit in a bitmap (0 = free, 1 = used). Because paging is already on, it only ever touches physical memory through Limine's Higher-Half Direct Map (HHDM), where ``virtual = hhdm_offset + phys``. It bootstraps its own bitmap into the first usable region large enough to hold it, then serves as the foundation every higher memory subsystem (VMM, heap) allocates frames from.

Key components
==============

Allocation API
--------------

- ``alloc() ?u64`` — returns a free physical frame address (a multiple of ``PAGE_SIZE``), or ``null`` on out-of-memory. Uses a ``next_hint`` cursor and wraps around for a single full sweep. Never returns 0, since frame 0 is permanently reserved.
- ``allocZeroed() ?u64`` — like ``alloc()`` but zeroes the frame through the HHDM first; the form the VMM uses for page-table frames.
- ``free(phys: u64) void`` — returns a frame to the pool and biases the next scan toward the freed space.

Translation
-----------

- ``physToVirt(phys: u64) u64`` — converts a physical address to its HHDM virtual address (``inline``).

Stats
-----

- ``freeFrames()``, ``totalFrames()``, ``highestAddress()`` — accessors used for logging and by the VMM.

Lifecycle
---------

- ``init(memmap, hhdm_offset)`` — records the HHDM offset, dumps and tallies the memory map, sizes and bootstraps the bitmap, marks all frames used then frees the usable regions, reserves frame 0 and the bitmap's own frames, runs ``selfTest()``, and sets ``ready``.
- ``reclaimBootloader()`` — frees bootloader-reclaimable regions recorded at init time, then re-reserves frame 0 and the bitmap frames as a safeguard.

Constants / internals
----------------------

- ``PAGE_SIZE`` (4096) — one physical frame.
- ``Region`` / ``reclaim_regions`` / ``MAX_RECLAIM`` (64) — recorded reclaimable regions saved for later freeing.
- Bitmap primitives ``bitTest``/``bitSet``/``bitClear`` and the idempotent ``markFree``/``markUsed`` keep ``used_frames`` consistent.

Depends on / used by
====================

- **Imports:** ``limine`` (memory-map types: ``MemoryMapResponse``, ``MemoryMapType``), ``../drivers/serial.zig`` (logging).
- **Used by:** ``src/mm/vmm.zig`` (frames for page tables, HHDM translation), ``src/mm/heap.zig`` (frames backing the heap), ``src/acpi/acpi.zig`` (``physToVirt`` to reach physical tables). First memory subsystem brought up after the IDT/PIC in boot order.

Notes
=====

- The bitmap must cover every frame that could ever be handed out, so ``highest_addr`` (and thus ``total_frames``) also accounts for bootloader-reclaimable regions, one of which can sit *above* the highest usable region.
- The memory map lives in the very memory it describes, so it cannot be re-read later; reclaimable regions are copied into ``reclaim_regions`` during ``init``.
- ``reclaimBootloader()`` must only run after the kernel no longer touches anything Limine left behind — in particular after leaving Limine's boot stack, which lives in reclaimable memory.
- ``markFree``/``markUsed`` are idempotent so overlapping passes never double-count.
- Physical address 0 is permanently reserved so a valid ``alloc()`` result can never be confused with ``null``.
