# Obsidia

## What is this?

Obsidia is a small **operating system kernel** — the core program a computer runs
first, before any apps. It's what talks directly to the hardware: the CPU,
memory, screen, keyboard, mouse, and disk. It's written from scratch in the
[Zig](https://ziglang.org) language for 64-bit Intel/AMD PCs, as a learning
project, and it runs inside [QEMU](https://www.qemu.org) (a program that
pretends to be a whole PC) so you never need real hardware to try it.

When it starts, Obsidia brings the machine to life step by step and then gives
you a **shell** — a text prompt where you can type commands (`help`, `ls`,
`cat`, `mem`, and more). You can also **install** it onto a (virtual) disk and
log in with a username and password, just like a real OS.

**What works today, in plain terms:**

- Boots on both modern (UEFI) and old-style (BIOS) PCs, via the Limine bootloader.
- Manages memory, runs multiple tasks at once, and handles crashes by printing a
  readable report instead of freezing.
- Talks to the screen (text + a blinking cursor), the keyboard, and the mouse
  (the wheel scrolls back through old output).
- Reads files from a FAT32 disk and can run small programs off it.
- **Installs itself** onto a disk and gates the shell behind a real
  password login.

The rest of this page is the technical guide: how to set up the tools, build it,
run it, install it, and test it.

---

Obsidia is a Zig-based x86-64 kernel. It boots under both UEFI and legacy BIOS
via a [Limine](https://github.com/limine-bootloader/limine) hybrid ISO. Serial
(COM1) is the primary debugging channel — on a successful boot the kernel prints
a banner ending in `BOOT_OK`.

## Development environment setup

Obsidia targets **Zig 0.14.0** (this is pinned in CI and is the minimum in
`build.zig.zon`). Building the kernel only needs Zig; assembling and booting the
ISO additionally needs `xorriso`, `mtools`, QEMU, and OVMF.

The instructions below are for a Debian/Ubuntu-based distro (e.g. PikaOS) using
`apt`. Adapt the package step for other distros.

### 1. Install Zig 0.14.0

`apt`'s Zig is too old, so install the official toolchain. This drops it into
`~/.local` (no root required); make sure `~/.local/bin` is on your `PATH`.

```sh
# Download and verify
curl -fsSL -o /tmp/zig-0.14.0.tar.xz \
  https://ziglang.org/download/0.14.0/zig-linux-x86_64-0.14.0.tar.xz
echo "473ec26806133cf4d1918caf1a410f8403a13d979726a9045b421b685031a982  /tmp/zig-0.14.0.tar.xz" \
  | sha256sum -c -

# Extract and link onto PATH
mkdir -p ~/.local/lib ~/.local/bin
tar -xf /tmp/zig-0.14.0.tar.xz -C ~/.local/lib
mv ~/.local/lib/zig-linux-x86_64-0.14.0 ~/.local/lib/zig-0.14.0
ln -sf ~/.local/lib/zig-0.14.0/zig ~/.local/bin/zig

zig version   # should print 0.14.0
```

If `zig` isn't found afterwards, add `~/.local/bin` to your `PATH` (e.g. append
`export PATH="$HOME/.local/bin:$PATH"` to `~/.bashrc`).

### 2. Install ISO + emulation tooling

```sh
sudo apt-get update
sudo apt-get install -y xorriso mtools qemu-system-x86 ovmf
```

- `xorriso` / `mtools` — assemble the hybrid bootable ISO
- `qemu-system-x86` — run the kernel headless with serial captured
- `ovmf` — UEFI firmware for QEMU

### 3. Fetch the Limine bootloader binaries

These are committed-binary releases; the `make` step only builds the small host
`limine` installer utility (needs a C compiler — `gcc`/`cc`). The `limine/`
directory is git-ignored.

```sh
git clone https://github.com/limine-bootloader/limine.git --branch=v8.x-binary --depth=1
make -C limine
```

## Building

```sh
zig build
```

Produces `zig-out/bin/kernel.elf`. The Limine Zig bindings
([`48cf/limine-zig`](https://github.com/48cf/limine-zig)) are fetched
automatically into the Zig cache on first build.

> **Note:** `build.zig` disables SSE/AVX/MMX and enables soft-float on purpose —
> emitting SSE before the FPU is configured in-kernel triple-faults at boot.
> Leave those target features disabled until the FPU is explicitly enabled.

## Running

The `run.sh` script compiles, assembles `obsidia.iso`, installs the Limine BIOS
stage, and boots it in QEMU with serial routed to your terminal (KVM
accelerated):

```sh
./run.sh
```

> **Machine type & disk:** `run.sh` boots the **i440fx** machine (`-M pc`) rather
> than q35, and attaches a persistent 64 MiB disk (`obsidia-disk.img`, created on
> first run, git-ignored) as a legacy IDE drive. On first run it's formatted
> **FAT32** with a couple of sample files, so you can `ls` and `cat` from the
> shell; its contents persist across reboots. The ATA PIO disk driver needs the
> PIIX3 IDE controller that i440fx provides; q35 has only AHCI/SATA, where the
> driver finds no disk. The kernel itself boots identically on either machine —
> only the legacy disk requires `-M pc`. (`-boot d` forces CD boot, since a FAT32
> disk carries a 0x55AA signature the BIOS would otherwise try to boot.)

> **OVMF path:** `run.sh` points `-bios` at the combined `/usr/share/ovmf/OVMF.fd`
> (lowercase dir — the single-file image). The uppercase `/usr/share/OVMF/` dir
> holds only the split `*_4M.fd` code/vars files. If your `ovmf` package puts the
> firmware elsewhere, update the path in `run.sh`.

### Headless boot test (the CI / debugging method)

To boot with serial captured to a log and check for the success marker — the
same approach CI uses and the most convenient way to share crash dumps:

```sh
qemu-system-x86_64 \
  -M q35 -m 512M \
  -cdrom obsidia.iso \
  -chardev stdio,id=char0,logfile=boot.log,signal=off \
  -serial chardev:char0 \
  -display none -no-reboot
grep -q BOOT_OK boot.log && echo "BOOT OK" || echo "BOOT FAILED"
```

## Installing Obsidia (in QEMU)

`./run.sh` boots the *live* system straight off the CD every time — nothing is
kept. To get a **real install** — a disk you boot from, with your own login —
use `install.sh`. Everything happens inside QEMU; no real hardware is touched.

How it works, in plain terms: the script builds one complete, ready-to-boot disk
image (a real GPT partition layout with an EFI System Partition holding Limine,
the kernel, and your login credential). It puts that image on an *installer* CD.
You boot the installer in QEMU, and **the kernel itself writes the image onto a
blank disk** using its own disk driver — a genuine in-guest install. Then you
boot that disk on its own.

```sh
# 1. Build the installer and boot it (you'll be asked for a username + password).
./install.sh
#    At the  obsidia>  prompt, type:
install
#    Wait for "install: complete", then type:
shutdown

# 2. Boot the disk you just installed to.
./install.sh boot
#    Log in with the username/password you chose.
```

You can also run the steps separately: `./install.sh build` (just build the
files), `./install.sh install` (boot the installer), `./install.sh boot` (boot
the installed disk). To script the credentials instead of being prompted, set
`OBSIDIA_USER` and `OBSIDIA_PASS` before running.

### How the login works

Passwords are never stored in plain text. The installer runs them through
**scrypt**, a slow, memory-hard hashing function designed to resist
password-cracking, and saves only the resulting hash (in the standard PHC
format) on the disk. At boot, the bootloader hands that hash to the kernel as a
file; when you type your password, the kernel hashes what you typed the same way
and checks it matches. A disk with no credential simply opens the shell (handy
for development).

## Testing

Two layers of tests:

```sh
zig build test      # host unit tests (pure logic: scancode decode, PSF parsing)
tests/run.sh        # full integration harness (boots in QEMU, checks everything)
```

- **Unit tests** (`zig build test`) compile the host-testable modules for the
  native target and run their `test` blocks — currently the keyboard scancode
  translation and the PSF font parser.
- **Integration harness** (`tests/run.sh`) builds the kernel, runs the unit
  tests, assembles the ISO, then boots it headless under **both legacy BIOS and
  UEFI** and asserts that every subsystem logged its success marker (GDT, IDT +
  its int3 self-test, PIC/PIT, PMM, VMM + W^X, heap, console, keyboard, and
  `BOOT_OK`). It then drives the shell over serial (checking `help`/`mem`/
  `uptime`/`echo`/unknown-command and Up-arrow history recall) and, if `socat` +
  ImageMagick are present, screenshots the framebuffer to confirm text was drawn.
  Exit status is non-zero if any check fails.

## Continuous integration

`.github/workflows/build.yml` builds the kernel with Zig 0.14.0, assembles the
hybrid ISO, boots it under both UEFI (OVMF) and legacy BIOS in QEMU, and asserts
`BOOT_OK` appears on the serial log. The built `obsidia.iso` is uploaded as an
artifact.

## Project layout

| Path                      | Purpose                                                       |
| ------------------------- | ------------------------------------------------------------ |
| `src/main.zig`            | Entry point `_start`, exported Limine requests, init sequence |
| `src/shell.zig`           | Interactive shell (REPL) + password login gate              |
| `src/auth.zig`            | Password hashing/verification (scrypt, PHC format)          |
| `src/install.zig`         | In-guest installer: clones the system image onto the disk    |
| `src/loader.zig`          | Program loader (ELF64 + flat binaries) for the init program  |
| `src/arch/gdt.zig`        | Segment descriptors + TSS                                    |
| `src/arch/idt.zig`        | Interrupt/exception handlers (crash dumps)                   |
| `src/arch/pic.zig`        | 8259 PIC remap + 8254 PIT timer (IRQ dispatch)               |
| `src/mm/pmm.zig`          | Physical memory manager (bitmap frame allocator)             |
| `src/mm/vmm.zig`          | Virtual memory / paging (own page tables, W^X)               |
| `src/mm/heap.zig`         | Kernel heap (`std.mem.Allocator`)                            |
| `src/drivers/serial.zig`  | COM1 serial driver (`outb`/`inb`, `print`, RX)               |
| `src/drivers/console.zig` | Framebuffer text console (PSF font, ANSI, blinking cursor)   |
| `src/drivers/keyboard.zig`| PS/2 keyboard (IRQ1, scancode set 1, arrow keys)            |
| `src/drivers/ata.zig`     | ATA PIO disk driver (block read + write)                    |
| `src/drivers/mouse.zig`   | PS/2 mouse (IRQ12); wheel scrolls the console scrollback     |
| `src/fs/fat32.zig`        | FAT32 filesystem (read-only)                                |
| `src/fonts/`              | Embedded bitmap fonts (Tamzen PSF)                           |
| `src/tests.zig`           | Host unit-test aggregator (`zig build test`)                |
| `tools/mkpasswd.zig`      | Host helper: make a scrypt credential line for the installer |
| `tests/run.sh`            | Integration harness (QEMU boot + shell checks)              |
| `install.sh`              | Build + run the in-guest installer (`build`/`install`/`boot`) |
| `build.zig`               | Freestanding x86-64 target; disables SSE/AVX/MMX, soft-float |
| `build.zig.zon`           | Dependencies (`48cf/limine-zig`, api_revision 3)             |
| `linker-x86_64.lds`       | Higher-half layout `0xffffffff80000000` + per-section symbols |
| `limine.conf`             | Limine boot entry (serial logging enabled)                   |
| `run.sh`                  | Build → assemble ISO → boot in QEMU with serial              |
