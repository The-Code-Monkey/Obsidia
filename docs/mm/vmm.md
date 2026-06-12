# `src/mm/vmm.zig`

> Builds the kernel's own x86-64 4-level page tables and takes over paging from Limine by loading CR3.

## What it does
The virtual memory manager (VMM) constructs a fresh PML4 (with frames from the PMM, accessed through the HHDM), replicates the two mappings the kernel cannot run without — the HHDM and the kernel image — and then switches `CR3` to run on its own tables. It enforces W^X (write XOR execute): `.text` is executable and read-only, while all other regions (data, rodata, HHDM, heap) are non-executable via the NX bit. After the swap it self-tests live translation and verifies the W^X bits actually landed.

## Key components

### Public mapping API
- `map(virt, phys, flags) void` — maps a 4 KiB page into the live tables and flushes its TLB entry.
- `unmap(virt) void` — clears a leaf mapping and flushes the TLB.
- `FLAG_WRITE` / `FLAG_NX` — re-exported entry flags so callers (e.g. the heap) can request writable / non-executable pages.

### Lifecycle
- `init(phys_base, virt_base, hhdm_offset) void` — checks 4-level paging (CR4.LA57 == 0), enables `EFER.NXE`, allocates the PML4, maps the HHDM with 2 MiB pages and the kernel image per-section with W^X, loads CR3 (interrupts masked across the swap), then runs `selfTest`.

### Internal table machinery
- `mapPage` / `map2MiB` — install a 4 KiB or 2 MiB (huge) leaf entry, creating intermediate tables as needed.
- `unmapPage` / `queryEntry` — non-creating walks that clear or read a leaf entry (`queryEntry` stops at huge pages and returns `null` if unmapped).
- `nextTable` — descends one level, allocating and linking a fresh zeroed table if absent.
- `tableAt` — views a physical table frame through the HHDM; `idx` extracts the 9-bit table index for a given shift (39/30/21/12).
- `mapKernelRange` — maps `[vstart, vend)` to slide-adjusted physical addresses (`phys = virt - virt_base + phys_base`).

### Low-level CPU access
- `rdmsr` / `wrmsr` / `enableNxe` — read/write MSRs; enable the NX bit in `IA32_EFER`.
- `readCr4`, `flushTlb` (`invlpg`), `fail` (fatal halt).

### Constants
- `PAGE_SIZE` (4 KiB), `TWO_MIB`, `FOUR_GIB` (minimum HHDM span).
- Entry flags `PRESENT`, `WRITE`, `HUGE`, `NX`, and `ADDR_MASK`.
- `IA32_EFER`, `EFER_NXE`.
- Linker-provided section bounds: `__kernel_start`, `__kernel_end`, `__text_start/end`, `__rodata_start/end`, `__data_start`.

## Depends on / used by
- **Imports:** `pmm.zig` (frames for page tables, `physToVirt`), `../drivers/serial.zig` (logging). Uses inline assembly for CR3/CR4/MSR access and `invlpg`. Relies on the linker script's page-aligned section symbols.
- **Used by:** `src/mm/heap.zig` (calls `map`, `FLAG_WRITE`, `FLAG_NX` to grow). Brought up after the PMM and before the heap.

## Notes
- The moment CR3 loads the MMU uses the new tables; a wrong HHDM or kernel mapping faults immediately, but the IDT (set up earlier in boot) turns that into a readable dump instead of a triple fault.
- `EFER.NXE` must be enabled before any NX-bearing entry is used, otherwise the NX bit is reserved and translation faults.
- The HHDM is mapped with 2 MiB pages spanning at least 4 GiB (`@max(FOUR_GIB, highestAddress)`) to cover RAM plus MMIO; 4 KiB would be wasteful there.
- Both Limine's tables and the new tables map the HHDM identically, so `tableAt`/`physToVirt` work before and after the CR3 swap, and interrupts are masked only to keep the transition clean.
- Assumes 4-level paging; 5-level (LA57) triggers a fatal `fail`.
- Kernel section ranges are page-aligned, so `[start, end)` ranges map with no partial pages.
