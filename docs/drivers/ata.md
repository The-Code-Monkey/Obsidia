# `src/drivers/ata.zig`

> ATA PIO disk driver for the primary bus / master drive using 28-bit LBA: the simplest possible block device, where the CPU moves every word through an I/O port.

## What it does
Reads a hard disk via legacy ATA "Programmed I/O" — no DMA, the CPU itself moves each 16-bit word through the data port. It talks to the primary ATA controller through the command block at ports `0x1F0..0x1F7` and the control block at `0x3F6`, supporting the master drive with 28-bit LBA. On init it probes the primary master with IDENTIFY DEVICE to detect presence and capacity, and exposes a `read` primitive that the filesystem layer builds on. It is safe to run on disk-less boots (it simply reports no device).

## Key components

Constants:
- `IO_BASE` (`0x1F0`) and register offsets: `DATA`, `FEATURES`, `SECCOUNT`, `LBA_LOW/MID/HIGH`, `DRIVE_HEAD`, `STATUS`/`COMMAND` (shared port `0x1F7`), `ALT_STATUS` (`0x3F6`).
- Status bits: `SR_BSY`, `SR_DRDY`, `SR_DF`, `SR_DRQ`, `SR_ERR`.
- Commands: `CMD_READ_PIO` (`0x20`), `CMD_IDENTIFY` (`0xEC`).
- `SECTOR_SIZE` (`512`) — public; bytes per sector.

State accessors:
- `isPresent()` — whether a usable disk was found on the primary master (checked by the filesystem layer before reading).
- `sectorCount()` — capacity in 512-byte sectors (0 if none).

Internal helpers:
- `repInsw(port, buf, words)` — move a whole sector via `cld; rep insw` (auto-incrementing IN).
- `delay400ns()` — ~400 ns settle delay by reading `ALT_STATUS` four times after drive select.
- `waitNotBusy()` — spin until BSY clears, capped (~100M spins) to avoid hanging on an absent/misbehaving controller.
- `waitDataRequest()` — wait for BSY clear + DRQ set; returns false on ERR/DF or timeout.

Public operations:
- `init()` — probe the primary master: select master, check for floating bus (`0xFF`) / status 0, issue IDENTIFY, reject ATAPI/SATA signatures, read 256 words, and derive `total_sectors` from words 60/61.
- `read(lba, count, dst)` — read `count` sectors (1..256) from `lba` into `dst`; validates presence, args, and buffer size; programs the registers, then waits for DRQ and moves 256 words per sector. Returns false on no-disk, bad args, or controller error.
- `selfTest()` — boot self-test that reads LBA 0 and prints its first 16 bytes (printable form); no-op without a disk.

## Depends on / used by
- **Imports:** `std` (`sliceAsBytes` for the sector copy), `serial.zig` (logging plus the `inb`/`outb` port helpers).
- **Used by:** The filesystem layer, which calls `isPresent()`/`sectorCount()` and builds on `read()` as its one block-device primitive. `init()` and `selfTest()` run during boot driver bring-up.

## Notes
- These legacy PATA ports only exist on QEMU's i440fx / `-M pc` machine; the q35 machine exposes only AHCI/SATA, where this driver finds nothing and leaves `present` false.
- Detection uses cheap heuristics: a floating bus reads `0xFF`, status `0` means no device, and non-zero LBA mid/high after IDENTIFY indicates a non-ATA (ATAPI/SATA) device, which is skipped.
- A sector count of 256 is passed as `0` in the SECCOUNT register (which the controller interprets as 256).
- Sectors are read into a word-aligned temporary buffer, then `@memcpy`'d into the caller's possibly-unaligned byte slice.
- The busy/DRQ wait loops are spin-capped so an absent or stuck controller can't hang the whole kernel.
