============
``src/mm/heap.zig``
============

   A ``std.mem.Allocator`` for the kernel, backed by an on-demand-growing virtual region over a sorted, coalescing free list.

What it does
============

The kernel heap reserves a dedicated virtual region (``HEAP_BASE``, PML4 slot 384, clear of the HHDM and kernel) and grows it on demand by allocating physical frames from the PMM and mapping them in via the VMM. Over that region it runs a first-fit, address-sorted free-list allocator with forward/backward coalescing. It bridges the ``std.mem.Allocator`` interface — which returns an arbitrarily-aligned pointer and, on free, gives back only the slice — by over-allocating a raw block, placing the aligned payload inside it, and stashing an ``AllocHeader`` just before the payload so ``free``/``resize``/``remap`` can recover the original block.

Key components
==============

Public API
----------

- ``allocator() std.mem.Allocator`` — returns a standard allocator any ``std`` code (containers, ``create``/``alloc``) can use.
- ``init() void`` — resets the free list, maps the initial 64 KiB (``INITIAL_HEAP``), runs ``selfTest``, and halts fatally if the initial mapping fails.

Allocator vtable bridge
-----------------------

- ``vtAlloc`` — gets a raw block sized for ``header + alignment padding + len``, grows the region if needed, places the aligned payload, and stashes the ``AllocHeader``.
- ``vtResize`` / ``vtRemap`` — answer whether the existing block can hold ``new_len`` in place, using ``capacityOf`` (payload-to-block-end slack).
- ``vtFree`` — recovers the raw block from its header and returns it to the free list.
- ``vtable`` — wires the four functions into ``std.mem.Allocator.VTable``.

Free list internals
--------------------

- ``rawAlloc(size) ?Block`` — first-fit allocation, splitting a block when the remainder can hold a ``Node``, else handing out the whole block.
- ``rawFree(addr, size) void`` — inserts a block keeping the list address-sorted, then coalesces with adjacent neighbours (never into the dummy head).
- ``grow(min_bytes) bool`` — maps fresh ``allocZeroed`` frames (RW + NX) at the top of the heap and donates the region via ``rawFree``.
- ``headerOf`` / ``capacityOf`` — recover an allocation's header and compute its usable slack.

Types and constants
--------------------

- ``Node`` — a free block header (``size``, ``next``) stored in the free memory itself.
- ``AllocHeader`` — ``block`` start and ``block_size``, written just before each payload.
- ``Block`` — an allocated raw block (``addr``, ``size``).
- ``HEAP_BASE`` (``0xffffc00000000000``), ``HEAP_MAX`` (4 GiB cap), ``INITIAL_HEAP`` (64 KiB), ``GROW_MIN`` (64 KiB), ``PAGE_SIZE``.

Depends on / used by
====================

- **Imports:** ``pmm.zig`` (``allocZeroed`` for backing frames), ``vmm.zig`` (``map``, ``FLAG_WRITE``, ``FLAG_NX``), ``std`` (``std.mem.Allocator``, containers in the self-test), ``../drivers/serial.zig`` (logging).
- **Used by:** any kernel subsystem needing dynamic allocation via ``allocator()``. The last of the core memory subsystems to come up (after PMM and VMM).

Notes
=====

- The free list is sorted by address specifically to make neighbour coalescing in ``rawFree`` cheap and correct.
- A split only happens when the remainder is at least ``@sizeOf(Node)``; otherwise the whole block is handed out (internal slack the caller can later reclaim via ``resize``/``remap``).
- Heap pages are mapped RW + NX — heap memory is data and must never be executable, consistent with the VMM's W^X policy.
- Growth is capped at ``HEAP_MAX`` (4 GiB above the base); ``grow`` returns ``false`` rather than exceeding it.
- Coalescing deliberately never merges into the dummy ``head`` node.
