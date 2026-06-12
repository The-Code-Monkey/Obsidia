# `src/install.zig`

> In-guest installer: writes a complete, ready-to-boot system image onto the disk.

## What it does
This is the part of a real install that runs **inside** Obsidia: it takes a
prebuilt disk image and writes it onto the target disk with the kernel's own ATA
driver, so afterwards the machine can boot Obsidia on its own.

It is the simplest kind of installer (call it "Option A"): rather than building a
filesystem and bootloader from scratch in the kernel, it clones a finished image
that was assembled on the host (see [`install.sh`](../install.sh)). That image is
a real **GPT**-partitioned disk with an EFI System Partition holding Limine, the
kernel, the boot config, and the login credential.

How the image reaches the kernel: the host wraps it as a **Limine module** named
`system.img` on the installer CD. Limine loads it into memory at boot and hands
the kernel a pointer to it (see [`main.md`](main.md) `systemModule()`), so the
installer never has to read the CD's filesystem itself.

Writing is **sparse**: the image is mostly empty space (zeros), and a freshly
created target disk is already all zeros, so the installer skips all-zero chunks
and only writes the few megabytes actually in use. This matters because PIO disk
writes are slow.

## Key components
- `setImage(m)` — called by `main` before the shell starts, to hand the
  installer the `system.img` module bytes (or `null` if we didn't boot the
  installer medium).
- `available()` — `true` when a system image is present, i.e. we booted the
  installer. The shell only offers the `install` command when this is true.
- `run()` — the install itself: checks an image and a target disk exist and the
  disk is big enough, then writes the image in 256-sector chunks, skipping
  all-zero chunks, with progress logging. **This erases the target disk.**
- `isZero(buf)` — helper that reports whether a chunk is entirely zero (and can
  therefore be skipped).

## The full install flow
1. `install.sh` (host) builds the GPT system image with your scrypt credential
   baked into its ESP, and an installer ISO that carries the image as a module.
2. You boot the installer ISO in QEMU with a blank disk attached.
3. At the shell you type `install` → this module clones the image onto the disk.
4. You reboot from the disk; it boots Obsidia standalone to a password login.

## Related
- [`drivers/ata.md`](drivers/ata.md) — the disk `write()` primitive used here.
- [`auth.md`](auth.md) — the credential format the installed system logs in with.
- A future "Option B" will construct the disk in-kernel (partition + format +
  bootloader) instead of cloning a prebuilt image.
