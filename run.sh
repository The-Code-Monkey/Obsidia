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

echo "Booting Obsidia..."
# Launch QEMU utilizing KVM and passing the host architecture straight through
qemu-system-x86_64 \
    -M q35 \
    -enable-kvm \
    -cpu host \
    -m 2G \
    -bios /usr/share/ovmf/OVMF.fd \
    -cdrom obsidia.iso \
    -serial stdio
