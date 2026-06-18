==================
``src/loader.zig``
==================

   Loads a small "init" program off the disk, makes it runnable in memory, runs it, and tears it down.

What it does
============

This module reads a program file from the FAT32 disk and runs it. It understands
two formats and picks one automatically by looking at the first few bytes of the
file:

- **ELF64** — a normal linked executable (starts with the bytes ``\x7fELF``),
  produced by a regular toolchain. The loader reads the ELF header, walks the
  program headers, and places each loadable segment at the exact address the
  linker chose, with that segment's own permissions.
- **flat** — raw machine code with no header: byte 0 is the first instruction.
  Loaded at a fixed address. Kept as a simple fallback.

The program contract (for now): it runs at full privilege, is entered like a C
function, and returns a value in ``rax``. A well-behaved init returns a known magic
value so the kernel can tell "finished cleanly" from "crashed".

**W^X is always preserved:** every page is mapped writable-but-not-executable
while bytes are copied in, then flipped to its final permissions before the
program runs — a page is never writable and executable at the same time.

Key components
==============

- ``exec(path)`` — the entry point: read the file, refuse a short read, detect the
  format, lay it out in memory, run it, and unmap it afterward (safe to call
  repeatedly).
- ELF path — validates the header (64-bit, little-endian, x86-64, EXEC/DYN),
  maps each ``PT_LOAD`` segment (copy file bytes, zero the ``.bss`` tail) with
  per-segment permissions, then jumps to the entry point.
- flat path — copies the raw bytes to the fixed load address and jumps to byte 0.
- ``selfTest()`` — at boot, runs ``/INIT.ELF`` (or the legacy ``/INIT``) if present,
  proving the whole disk → memory → run → return path; skips quietly if absent.

Related
=======

- `fs/fat32.rst <fs/fat32.rst>`_ — where the program file is read from.
- `mm/vmm.rst <mm/vmm.rst>`_ — the mapping/permission flags used to enforce W^X.
