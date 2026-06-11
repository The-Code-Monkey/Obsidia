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
    echo "Creating $DISK (64 MiB scratch disk)..."
    truncate -s 64M "$DISK"
    # A human-readable marker at sector 0 so the ATA self-test prints something
    # recognizable on first boot (the filesystem will overwrite this later).
    printf 'OBSIDIA_ATA_OK\0\0' | dd of="$DISK" conv=notrunc bs=1 count=16 2>/dev/null
fi

echo "Booting Obsidia..."
# Launch QEMU utilizing KVM and passing the host architecture straight through.
# -M pc (i440fx) gives us the legacy PIIX3 IDE controller our ATA PIO driver uses.
qemu-system-x86_64 \
    -M pc \
    -enable-kvm \
    -cpu host \
    -m 2G \
    -bios /usr/share/ovmf/OVMF.fd \
    -cdrom obsidia.iso \
    -drive file="$DISK",format=raw,if=ide \
    -serial stdio
