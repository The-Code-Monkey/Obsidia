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

# Option B (construct) artifacts — the installer that BUILDS the disk in-kernel.
CISO=obsidia-construct.iso    # installer ISO carrying the payload as modules
CDISK=obsidia-construct.img   # the blank target disk the construct installer fills

kvm_args=(); [ -e /dev/kvm ] && kvm_args=(-enable-kvm -cpu host)

# Locate OVMF UEFI firmware (the constructed disk boots via UEFI). Sets uefi_args
# to the right QEMU flags, or leaves it empty (with a warning) if none is found.
uefi_args=()
find_ovmf() {
    local p c v
    for p in "${OVMF:-}" /usr/share/ovmf/OVMF.fd /usr/share/OVMF/OVMF.fd \
             /usr/share/qemu/OVMF.fd /usr/share/edk2-ovmf/x64/OVMF.fd; do
        [ -n "$p" ] && [ -f "$p" ] && { uefi_args=(-bios "$p"); return 0; }
    done
    for c in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd; do
        [ -f "$c" ] || continue
        for v in /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_VARS.fd; do
            [ -f "$v" ] || continue
            cp "$v" obsidia-ovmf-vars.fd
            uefi_args=(-drive "if=pflash,format=raw,readonly=on,file=$c"
                       -drive "if=pflash,format=raw,file=obsidia-ovmf-vars.fd")
            return 0
        done
    done
    echo "WARNING: no OVMF firmware found — the constructed disk needs UEFI to boot." >&2
    return 1
}

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

# === Option B: the construct installer (builds the disk in-kernel) ============
# Instead of a prebuilt image, carry the individual pieces as Limine modules. The
# in-kernel installer writes a GPT, formats an ESP, lays the tree, copies the
# pieces and writes a credential it hashes in-guest. The result boots under UEFI.
build_construct() {
    echo "== Building kernel =="
    zig build

    echo "== Building construct installer ISO ($CISO) =="
    rm -rf iso_root "$CISO"
    mkdir -p iso_root/boot/limine iso_root/EFI/BOOT
    cp zig-out/bin/kernel.elf iso_root/boot/kernel.elf      # also a module (copied to disk)
    cp limine/BOOTX64.EFI iso_root/EFI/BOOT/BOOTX64.EFI     # the bootloader we deploy
    cp limine/BOOTIA32.EFI iso_root/EFI/BOOT/ 2>/dev/null || true
    cp limine/limine-bios.sys limine/limine-bios-cd.bin limine/limine-uefi-cd.bin iso_root/boot/limine/
    # The config the INSTALLED system boots from (written to /boot/limine/limine.conf).
    cat > iso_root/installed.conf <<EOF
timeout: 0
serial: yes
/Obsidia
    protocol: limine
    kernel_path: boot():/boot/kernel.elf
    module_path: boot():/OBSIDIA/AUTH
EOF
    # The installer's OWN boot config (BIOS), exposing the payload as modules.
    cat > iso_root/boot/limine/limine.conf <<EOF
timeout: 0
serial: yes
/Obsidia Installer (construct)
    protocol: limine
    kernel_path: boot():/boot/kernel.elf
    module_path: boot():/boot/kernel.elf
    module_path: boot():/EFI/BOOT/BOOTX64.EFI
    module_path: boot():/installed.conf
EOF
    xorriso -as mkisofs -R -r -J -b boot/limine/limine-bios-cd.bin \
        -no-emul-boot -boot-load-size 4 -boot-info-table -hfsplus -apm-block-size 2048 \
        --efi-boot boot/limine/limine-uefi-cd.bin \
        -efi-boot-part --efi-boot-image --protective-msdos-label \
        iso_root -o "$CISO" >/dev/null 2>&1
    ./limine/limine bios-install "$CISO" >/dev/null 2>&1
    rm -rf iso_root

    echo "== Creating blank target disk ($CDISK, $SIZE) =="
    rm -f "$CDISK"; truncate -s "$SIZE" "$CDISK"
    echo "Build complete."
}

# Boot the construct installer (BIOS, -M pc for the legacy IDE the ATA driver
# needs) with the blank disk. Inside the guest, run `install` and pick a login.
run_construct() {
    echo "Booting the construct installer. At the obsidia> shell, type:  install"
    echo "Then power off (shutdown) and run:  ./install.sh construct-boot"
    qemu-system-x86_64 -M pc "${kvm_args[@]}" -m 2G -boot d -cdrom "$CISO" \
        -drive file="$CDISK",format=raw,if=ide -serial stdio
}

# Boot the constructed disk standalone under UEFI (OVMF), to the login.
run_construct_boot() {
    find_ovmf || exit 1
    echo "Booting the constructed disk ($CDISK) under UEFI..."
    qemu-system-x86_64 -M pc "${kvm_args[@]}" "${uefi_args[@]}" -m 2G -boot c \
        -drive file="$CDISK",format=raw,if=ide -serial stdio
}

case "${1:-all}" in
    build) build ;;
    install) run_installer ;;
    boot) run_disk ;;
    all) build; echo; run_installer ;;
    construct-build) build_construct ;;
    construct) build_construct; echo; run_construct ;;
    construct-boot) run_construct_boot ;;
    *) echo "usage: $0 [build|install|boot|construct|construct-build|construct-boot]"; exit 2 ;;
esac
