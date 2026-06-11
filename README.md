# Obsidia

Obsidia is a Zig-based x86-64 kernel for modern hardware. It boots under both
UEFI and legacy BIOS via a [Limine](https://github.com/limine-bootloader/limine)
hybrid ISO. Serial (COM1) is the primary debugging channel — on a successful
boot the kernel prints a banner ending in `BOOT_OK`.

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
> than q35, and attaches a persistent 64 MiB scratch disk (`obsidia-disk.img`,
> created on first run, git-ignored) as a legacy IDE drive. The ATA PIO disk
> driver needs the PIIX3 IDE controller that i440fx provides; q35 has only
> AHCI/SATA, where the driver finds no disk. The kernel itself boots identically
> on either machine — only the legacy disk requires `-M pc`.

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
| `src/shell.zig`           | Interactive serial command shell (REPL)                      |
| `src/arch/gdt.zig`        | Segment descriptors + TSS                                    |
| `src/arch/idt.zig`        | Interrupt/exception handlers (crash dumps)                   |
| `src/arch/pic.zig`        | 8259 PIC remap + 8254 PIT timer (IRQ dispatch)               |
| `src/mm/pmm.zig`          | Physical memory manager (bitmap frame allocator)             |
| `src/mm/vmm.zig`          | Virtual memory / paging (own page tables, W^X)               |
| `src/mm/heap.zig`         | Kernel heap (`std.mem.Allocator`)                            |
| `src/drivers/serial.zig`  | COM1 serial driver (`outb`/`inb`, `print`, RX)               |
| `src/drivers/console.zig` | Framebuffer text console (PSF font, ANSI, blinking cursor)   |
| `src/drivers/keyboard.zig`| PS/2 keyboard (IRQ1, scancode set 1, arrow keys)            |
| `src/fonts/`              | Embedded bitmap fonts (Tamzen PSF)                           |
| `src/tests.zig`           | Host unit-test aggregator (`zig build test`)                |
| `tests/run.sh`            | Integration harness (QEMU boot + shell checks)              |
| `build.zig`               | Freestanding x86-64 target; disables SSE/AVX/MMX, soft-float |
| `build.zig.zon`           | Dependencies (`48cf/limine-zig`, api_revision 3)             |
| `linker-x86_64.lds`       | Higher-half layout `0xffffffff80000000` + per-section symbols |
| `limine.conf`             | Limine boot entry (serial logging enabled)                   |
| `run.sh`                  | Build → assemble ISO → boot in QEMU with serial              |
