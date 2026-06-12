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
# shell's `exec /INIT`). Hand-assembled — no assembler needed; see tests/run.sh
# for the annotated instruction listing. It prints a marker to COM1 and returns
# the magic 0xB017B007. Refreshed on every run so an existing disk image picks
# up contract changes.
tmpf=$(mktemp)
printf '\x48\x8d\x35\x12\x00\x00\x00\x66\xba\xf8\x03\xac\x84\xc0\x74\x03\xee\xeb\xf8\xb8\x07\xb0\x17\xb0\xc3' > "$tmpf"
printf 'INIT: hello from FAT32!\n\0' >> "$tmpf"
mcopy -o -i "$DISK" "$tmpf" ::/INIT
rm -f "$tmpf"

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
