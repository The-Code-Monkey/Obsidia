# `src/acpi/acpi.zig`

> Parses the firmware's ACPI tables — chiefly the MADT — to discover the Local APIC, CPU cores, I/O APIC(s), and interrupt source overrides.

## What it does
ACPI tables describe the hardware. Starting from the RSDP (provided by Limine), this module follows the pointer to the RSDT (32-bit entries) or XSDT (64-bit entries), enumerates every System Description Table, and parses the one with the `APIC` signature (the MADT). From the MADT it records the Local APIC base address, counts enabled CPU cores, and collects I/O APICs and interrupt source overrides — exactly the data the APIC driver needs next. All table addresses are physical and reached through the HHDM.

## Key components

### Parsed result types
- `IoApic` — `id`, `address` (physical MMIO base), `gsi_base` (first global system interrupt it handles).
- `Iso` — an interrupt source override: `source` (legacy ISA IRQ), `gsi` (the GSI it maps to), `flags` (polarity / trigger mode).

### Result accessors
- `lapicAddress() u64` — Local APIC MMIO base (default `0xFEE00000`, possibly overridden by the MADT).
- `ioApics() []const IoApic`, `isos() []const Iso`, `cpuCount() usize`, `isReady() bool`.

### Lifecycle
- `init(rsdp_phys: u64) void` — validates the RSDP signature/checksum, chooses XSDT over RSDT on ACPI 2.0+, enumerates all tables, and dispatches the MADT to `parseMadt`.

### Parsing internals
- `parseMadt(madt, len)` — reads the 32-bit Local APIC address then walks the variable-length entry stream, handling type 0 (Processor Local APIC, counted if enabled), 1 (I/O APIC), 2 (Interrupt Source Override), and 5 (64-bit Local APIC Address Override).
- `read(T, ptr, off)` — little-endian read of an unaligned field via `std.mem.readInt`.
- `checksum(ptr, len)` — 8-bit sum that must be 0 for a valid structure.
- `at(phys)` — maps a physical table address to a pointer through the HHDM.

## Depends on / used by
- **Imports:** `std` (`std.mem.readInt`, `std.mem.eql`), `../drivers/serial.zig` (logging), `../mm/pmm.zig` (`physToVirt` via `at` to reach physical tables).
- **Used by:** the APIC driver (consumes `lapicAddress`, `ioApics`, `isos`, `cpuCount`). Runs after the memory managers are up (it needs the HHDM/`physToVirt`) and before APIC bring-up.

## Notes
- ACPI tables are byte-packed and fields can be unaligned, so every multi-byte field is read with `read`/`std.mem.readInt` rather than relying on struct layout.
- `parseMadt` guards against a malformed entry length (`elen < 2`) to avoid an infinite loop.
- The XSDT is preferred only when `revision >= 2` and its address is non-zero; otherwise the 32-bit RSDT is used. Entry count is `(header_length - 36) / entry_size`.
- An invalid RSDP checksum is only warned about, not treated as fatal.
- Fixed-capacity storage: up to 16 I/O APICs and 48 interrupt source overrides; extras beyond capacity are silently dropped.
