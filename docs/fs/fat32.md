# `src/fs/fat32.zig`

> A read-only FAT32 driver that mounts a raw volume, walks paths, lists directories, and reads file contents over the ATA PIO driver.

## What it does
This module mounts a raw FAT32 volume (no partition table — the whole disk is one filesystem) by parsing the boot sector/BPB into a `BootInfo` geometry, then provides path resolution and file reads. It follows cluster chains through the File Allocation Table (with a one-sector FAT cache), scans directories handling both short 8.3 and long file names, and streams or copies file data. All disk access goes through the ATA PIO driver; the driver is read-only.

## Key components

### Types & state
- `Node` — a resolved path: starting `cluster`, `size`, and `is_dir` flag (public result type).
- `BootInfo` (`bi`) — geometry parsed from the boot sector plus the derived `first_data_sector`.
- `Entry` — one resolved directory entry (name, first cluster, size, is_dir) passed to scan callbacks; its `name` is only valid for the callback's duration.
- Constants: `SECTOR` (512), `EOC` (end-of-chain marker), `ATTR_DIRECTORY`, `ATTR_VOLUME_ID`, `ATTR_LFN`.

### Mount & helpers
- `mount()` — reads and validates the boot sector (signature, sector size, FAT32-ness), fills `bi`, invalidates the FAT cache, and sets `mounted`. Safe with no/unformatted disk (logs why and returns false).
- `isMounted()` — whether a volume is currently mounted.
- `rd16` / `rd32` — little-endian field readers for FAT structures.
- `nextCluster(cluster)` — FAT lookup for the next cluster in a chain, backed by the single-sector `fat_cache`.
- `clusterToSector(c)` / `isDataCluster(c)` — cluster-to-LBA mapping and in-use-cluster test.

### Directory scanning & names
- `scanDir(start_cluster, ctx, onEntry)` — walks every entry in a directory's cluster chain, assembling long names and invoking the comptime callback per real entry (callback returns true to stop early).
- `accumulateLfn(...)` — folds one `ATTR_LFN` entry's 13 UTF-16 chars into the assembly buffer at its sequenced slot (ASCII rendered, non-ASCII → `?`).
- `shortName(...)` — renders an 8.3 name (`"FOO     TXT"` → `"FOO.TXT"`), honoring the Windows/NT base/extension lowercase flags at offset 0x0C.
- `LFN_OFFSETS` — the scattered byte offsets of the 13 LFN chars within a 32-byte entry.

### Path resolution & operations
- `resolve(path)` — resolves an absolute path (e.g. `/docs/notes.txt`) to a `Node`, walking each `/`-separated component from the root; null if any component is missing.
- `findInDir` / `findCallback` / `FindCtx` — case-insensitive lookup of a single name within a directory.
- `ls(path)` — list a directory (or print a single file's size).
- `cat(path)` — stream a file's contents to serial (shell `cat`).
- `readFile(path, dst)` — read a whole file into a caller buffer; returns bytes read, or null on error / buffer too small.
- `selfTest()` — mounts, lists `/`, and `cat`s `/HELLO.TXT` to exercise the full read path.

## Depends on / used by
- **Imports:** `std`, `drivers/serial.zig` (logging/output), `drivers/ata.zig` (sector reads + presence check).
- **Used by:** the shell's `ls` / `cat` commands; `readFile` is the primitive a future milestone (loading an init binary) will build on; `selfTest` runs during boot bring-up.

## Notes
- Read-only: there are no write/allocate paths.
- Only 512-byte-sector disks are supported (`mount` rejects others).
- Assumes a raw FAT32 volume with no partition table — sector 0 is the boot sector itself.
- The FAT cache (`fat_cache_sector`/`fat_cache`) makes walking a chain that stays within one FAT sector free after the first lookup; `mount` must invalidate it per volume.
- FAT names are matched case-insensitively (`eqlIgnoreCase`); long names take precedence over the 8.3 name when present.
- A FAT read error is treated as end-of-chain (`EOC`) to stop a chain safely rather than loop.
