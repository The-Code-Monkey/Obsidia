#!/bin/bash
set -e

echo "Compiling Obsidia..."
zig build

echo "Preparing ISO directory..."
# Layout must match limine.conf, which loads boot():/boot/kernel.elf
rm -rf iso_root
mkdir -p iso_root/boot/limine iso_root/EFI/BOOT
cp zig-out/bin/kernel.elf iso_root/boot/
cp limine.conf            iso_root/boot/limine/

# Copy the necessary Limine bootloader files into the ISO
cp limine/limine-bios.sys limine/limine-bios-cd.bin limine/limine-uefi-cd.bin iso_root/boot/limine/
cp limine/BOOTX64.EFI iso_root/EFI/BOOT/
cp limine/BOOTIA32.EFI iso_root/EFI/BOOT/

echo "Generating obsidia.iso..."
xorriso -as mkisofs -R -r -J \
        -b boot/limine/limine-bios-cd.bin \
        -no-emul-boot -boot-load-size 4 -boot-info-table -hfsplus \
        -apm-block-size 2048 \
        --efi-boot boot/limine/limine-uefi-cd.bin \
        -efi-boot-part --efi-boot-image --protective-msdos-label \
        iso_root -o obsidia.iso > /dev/null 2>&1

# Install Limine onto the generated ISO
./limine/limine bios-install obsidia.iso

# Persistent scratch disk for the ATA driver / filesystem. Created once (64 MiB)
# and kept across runs so its contents survive reboots. Attached as a legacy IDE
# disk, which is why we boot the i440fx machine (-M pc): the q35 chipset only has
# AHCI/SATA, so our legacy ATA PIO driver wouldn't find a disk there.
DISK=obsidia-disk.img
if [ ! -f "$DISK" ]; then
    echo "Creating $DISK (64 MiB FAT32 disk with sample files)..."
    truncate -s 64M "$DISK"
    # Format FAT32 and seed a few files (mtools only — no root / loop mounts).
    mformat -i "$DISK" -F -v OBSIDIA ::
    tmpf=$(mktemp)
    printf 'Hello from FAT32 on Obsidia!\n'                 > "$tmpf"; mcopy -i "$DISK" "$tmpf" ::/HELLO.TXT
    mmd -i "$DISK" ::/docs
    printf 'Files on the FAT32 disk persist across reboots.\n' > "$tmpf"; mcopy -i "$DISK" "$tmpf" ::/docs/NOTES.TXT
    rm -f "$tmpf"
fi

# /INIT: a flat x86-64 binary the kernel loads and runs at boot (and via the
# shell's `exec /INIT`) as a RING-3 user process. It write()s a marker, then
# exit()s (the user ABI; not a privileged `out` + return-magic). Its bytes come
# from the shared canonical producer (the single source of truth, also used by
# the test harness; see tests/make-init.sh for the annotated instruction
# listing). Refreshed on every run so an existing disk image picks up changes.
tmpf=$(mktemp)
tests/make-init.sh "$tmpf"
mcopy -o -i "$DISK" "$tmpf" ::/INIT
rm -f "$tmpf"

# /INIT0: a flat RING-0-ABI binary for the shell's legacy `exec0` command (the old
# loader contract — entered as a C function, prints via privileged `out`, returns
# a magic). Kept so the ring-0 load path stays exercisable now that /INIT is a
# ring-3 user program. Bytes from the shared producer; see tests/make-init0.sh.
tmpf=$(mktemp)
tests/make-init0.sh "$tmpf"
mcopy -o -i "$DISK" "$tmpf" ::/INIT0
rm -f "$tmpf"

# /INIT.ELF: a real, statically linked ELF64 ET_EXEC built with the Zig
# toolchain. The kernel's loader auto-detects the ELF magic and uses the ELF
# path (parse header -> walk program headers -> map each PT_LOAD segment at its
# linked address with per-segment W^X), and prefers this file over the flat
# /INIT at boot. Like the flat init it runs in ring 3: write() a marker, then
# exit(). Linked into the low (user) half. Built in a scratch dir; refreshed on
# every run.
elfd=$(mktemp -d)
cat > "$elfd/init.s" <<'ASM'
.section .text
.global _start
_start:
    movl    $1, %eax                # SYS_write
    movl    $1, %edi                # fd = 1 (stdout)
    lea     msg(%rip), %rsi         # rsi = &msg (RIP-relative: position-independent)
    movl    $(msg_end - msg), %edx  # len = number of bytes in msg
    syscall                         # write(1, msg, len)
    movl    $3, %eax                # SYS_exit
    xorl    %edi, %edi              # code = 0
    syscall                         # exit(0) — does not return
1:  jmp     1b                      # safety: spin if exit ever returns
.section .rodata
msg:
    .ascii  "INIT.ELF: hello from a real ELF!\n"
msg_end:
ASM
cat > "$elfd/init.ld" <<'LDS'
ENTRY(_start)
SECTIONS {
    . = 0x400000;
    .text   : { *(.text*) }
    . = ALIGN(0x1000);
    .rodata : { *(.rodata*) }
}
LDS
if zig cc -target x86_64-freestanding-none -nostdlib -c "$elfd/init.s" -o "$elfd/init.o" 2>/dev/null \
   && zig ld.lld -o "$elfd/init.elf" -T "$elfd/init.ld" --static -z max-page-size=0x1000 "$elfd/init.o" 2>/dev/null; then
    mcopy -o -i "$DISK" "$elfd/init.elf" ::/INIT.ELF
else
    echo "  (note: could not build /INIT.ELF with the zig toolchain; the kernel will fall back to flat /INIT)"
fi
rm -rf "$elfd"

echo "Booting Obsidia..."
# Launch QEMU utilizing KVM and passing the host architecture straight through.
# -M pc (i440fx) gives us the legacy PIIX3 IDE controller our ATA PIO driver uses.
# -boot d forces booting the CD-ROM: a FAT32-formatted disk carries a 0x55AA boot
# signature, so without this the BIOS may try to boot the (OS-less) data disk.
qemu-system-x86_64 \
    -M pc \
    -enable-kvm \
    -cpu host \
    -m 2G \
    -bios /usr/share/ovmf/OVMF.fd \
    -boot d \
    -cdrom obsidia.iso \
    -drive file="$DISK",format=raw,if=ide \
    -serial stdio
