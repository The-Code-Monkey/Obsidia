#!/bin/bash
# Obsidia installer (Option A: clone a prebuilt system image, in-guest).
#
#   ./install.sh            build the installer, then boot it in QEMU
#   ./install.sh build      just (re)build the system image + installer ISO
#   ./install.sh install    boot the installer ISO (type `install` at the shell)
#   ./install.sh boot       boot the INSTALLED disk
#
# The flow: this script builds a real GPT + ESP + Limine + kernel disk image
# (obsidia-system.img) with your login credential baked into the ESP, wraps that
# image as a Limine *module* on an installer ISO, and boots QEMU with a blank
# target disk. Inside the guest you run `install`, which writes the image onto
# the disk with the kernel's own ATA driver. Then `./install.sh boot` boots the
# installed disk standalone, to a login.
#
# Credentials come from $OBSIDIA_USER / $OBSIDIA_PASS if set (for scripting),
# otherwise you're prompted. All dev/testing is against QEMU images — never real
# hardware.
set -e
cd "$(dirname "$0")"

SYS=obsidia-system.img        # the bootable GPT system image we assemble
ISO=obsidia-installer.iso     # installer ISO that carries $SYS as a module
DISK=obsidia-install.img      # the blank target disk the installer writes
                              # (kept separate from run.sh's obsidia-disk.img)
SIZE=64M                      # size of both the system image and the target disk
ESP_OFFSET=$((2048 * 512))    # ESP partition starts at LBA 2048 (1 MiB)

kvm_args=(); [ -e /dev/kvm ] && kvm_args=(-enable-kvm -cpu host)

build() {
    echo "== Building kernel =="
    zig build

    # --- credential ----------------------------------------------------------
    local user pass tmp
    user="${OBSIDIA_USER:-}"; pass="${OBSIDIA_PASS:-}"
    [ -n "$user" ] || read -r -p "Choose a username: " user
    [ -n "$pass" ] || { read -r -s -p "Choose a password: " pass; echo; }
    tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN
    zig run tools/mkpasswd.zig -- "$user" "$pass" > "$tmp/AUTH"

    # --- assemble the GPT + ESP + Limine system image ------------------------
    echo "== Assembling system image ($SYS) =="
    rm -f "$SYS"; truncate -s "$SIZE" "$SYS"
    sgdisk --zap-all "$SYS" >/dev/null 2>&1
    sgdisk -n 1:2048:0 -t 1:ef00 -c 1:ESP "$SYS" >/dev/null 2>&1   # one ESP partition
    mformat -i "$SYS@@$ESP_OFFSET" -F ::                            # FAT32 in the ESP
    mmd -i "$SYS@@$ESP_OFFSET" ::/EFI ::/EFI/BOOT ::/boot ::/boot/limine ::/OBSIDIA
    mcopy -i "$SYS@@$ESP_OFFSET" zig-out/bin/kernel.elf ::/boot/kernel.elf
    mcopy -i "$SYS@@$ESP_OFFSET" limine/BOOTX64.EFI ::/EFI/BOOT/BOOTX64.EFI
    mcopy -i "$SYS@@$ESP_OFFSET" limine/limine-bios.sys ::/boot/limine/limine-bios.sys
    mcopy -i "$SYS@@$ESP_OFFSET" "$tmp/AUTH" ::/OBSIDIA/AUTH
    cat > "$tmp/installed.conf" <<EOF
timeout: 0
serial: yes
/Obsidia
    protocol: limine
    kernel_path: boot():/boot/kernel.elf
    module_path: boot():/OBSIDIA/AUTH
EOF
    mcopy -i "$SYS@@$ESP_OFFSET" "$tmp/installed.conf" ::/boot/limine/limine.conf
    ./limine/limine bios-install "$SYS" >/dev/null 2>&1

    # --- wrap the system image as a module on an installer ISO ---------------
    echo "== Building installer ISO ($ISO) =="
    rm -rf iso_root "$ISO"
    mkdir -p iso_root/boot/limine iso_root/EFI/BOOT
    cp zig-out/bin/kernel.elf iso_root/boot/
    cp "$SYS" iso_root/boot/system.img
    cp limine/limine-bios.sys limine/limine-bios-cd.bin limine/limine-uefi-cd.bin iso_root/boot/limine/
    cp limine/BOOTX64.EFI limine/BOOTIA32.EFI iso_root/EFI/BOOT/
    cat > iso_root/boot/limine/limine.conf <<EOF
timeout: 0
serial: yes
/Obsidia Installer
    protocol: limine
    kernel_path: boot():/boot/kernel.elf
    module_path: boot():/boot/system.img
EOF
    xorriso -as mkisofs -R -r -J -b boot/limine/limine-bios-cd.bin \
        -no-emul-boot -boot-load-size 4 -boot-info-table -hfsplus -apm-block-size 2048 \
        --efi-boot boot/limine/limine-uefi-cd.bin \
        -efi-boot-part --efi-boot-image --protective-msdos-label \
        iso_root -o "$ISO" >/dev/null 2>&1
    ./limine/limine bios-install "$ISO" >/dev/null 2>&1
    rm -rf iso_root

    # --- blank target disk ---------------------------------------------------
    echo "== Creating blank target disk ($DISK, $SIZE) =="
    rm -f "$DISK"; truncate -s "$SIZE" "$DISK"
    echo "Build complete."
}

# Boot the installer ISO with the blank disk attached. -M pc for the legacy IDE
# the ATA driver uses; -boot d to boot the CD (the data disk has no OS yet).
run_installer() {
    echo "Booting the installer. At the obsidia> shell, type:  install"
    echo "Then power off (shutdown) and run:  ./install.sh boot"
    qemu-system-x86_64 -M pc "${kvm_args[@]}" -m 2G -boot d -cdrom "$ISO" \
        -drive file="$DISK",format=raw,if=ide -serial stdio
}

# Boot the INSTALLED disk standalone (no CD), to the login.
run_disk() {
    echo "Booting the installed disk ($DISK)..."
    qemu-system-x86_64 -M pc "${kvm_args[@]}" -m 2G -boot c \
        -drive file="$DISK",format=raw,if=ide -serial stdio
}

case "${1:-all}" in
    build) build ;;
    install) run_installer ;;
    boot) run_disk ;;
    all) build; echo; run_installer ;;
    *) echo "usage: $0 [build|install|boot]"; exit 2 ;;
esac
