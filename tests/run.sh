#!/bin/bash
# Integration test harness for Obsidia.
#
# Builds the kernel, runs the host unit tests, assembles the ISO, then boots it
# headless in QEMU (both legacy BIOS and UEFI) and asserts that every subsystem
# logged its success markers. It also drives the interactive shell over serial
# and checks the command responses, and (if the tools are present) screenshots
# the framebuffer to confirm something was actually drawn.
#
# Usage:  tests/run.sh        (run from anywhere; it cd's to the repo root)
# Exit status is non-zero if any check fails.

set -u
cd "$(dirname "$0")/.." || exit 1   # repo root

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  \033[31m✗\033[0m %s\n' "$1"; }

# assert_in <logfile> <substring> <label> : pass if the substring is in the log.
assert_in() {
    if grep -qaF -- "$2" "$1"; then ok "$3"; else bad "$3"; fi
}

# Locate OVMF UEFI firmware. Distros ship it either as a single combined image
# (use -bios) or split into CODE + VARS files (use two pflash drives). Override
# the combined path with the OVMF env var. If neither is found, UEFI is skipped.
OVMF="${OVMF:-}"; OVMF_CODE=""; OVMF_VARS=""
if [ -z "$OVMF" ]; then
    for p in /usr/share/ovmf/OVMF.fd /usr/share/OVMF/OVMF.fd \
             /usr/share/qemu/OVMF.fd /usr/share/edk2-ovmf/x64/OVMF.fd; do
        [ -f "$p" ] && { OVMF="$p"; break; }
    done
fi
if [ -z "$OVMF" ]; then # fall back to split CODE + VARS
    for c in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd; do
        [ -f "$c" ] && { OVMF_CODE="$c"; break; }
    done
    for v in /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_VARS.fd; do
        [ -f "$v" ] && { OVMF_VARS="$v"; break; }
    done
fi
ISO=obsidia.iso
TMP=$(mktemp -d)
trap 'rm -rf "$TMP" iso_root' EXIT

command -v qemu-system-x86_64 >/dev/null || { echo "qemu-system-x86_64 not found"; exit 1; }

# --- Build -------------------------------------------------------------------
echo "== Build + unit tests =="
zig build              || { echo "kernel build failed"; exit 1; }
if zig build test 2>"$TMP/ut.log"; then ok "host unit tests"; else bad "host unit tests"; cat "$TMP/ut.log"; fi

# --- Assemble the bootable ISO -----------------------------------------------
build_iso() {
    rm -rf iso_root "$ISO"
    mkdir -p iso_root/boot/limine iso_root/EFI/BOOT
    cp zig-out/bin/kernel.elf iso_root/boot/
    cp limine.conf            iso_root/boot/limine/
    cp limine/limine-bios.sys limine/limine-bios-cd.bin limine/limine-uefi-cd.bin iso_root/boot/limine/
    cp limine/BOOTX64.EFI limine/BOOTIA32.EFI iso_root/EFI/BOOT/
    xorriso -as mkisofs -R -r -J -b boot/limine/limine-bios-cd.bin \
        -no-emul-boot -boot-load-size 4 -boot-info-table -hfsplus -apm-block-size 2048 \
        --efi-boot boot/limine/limine-uefi-cd.bin \
        -efi-boot-part --efi-boot-image --protective-msdos-label \
        iso_root -o "$ISO" >/dev/null 2>&1
    ./limine/limine bios-install "$ISO" >/dev/null 2>&1
}
echo "== Assembling ISO =="
build_iso || { echo "ISO assembly failed (need xorriso + limine/)"; exit 1; }

# --- Boot helpers ------------------------------------------------------------
# How long to let the kernel boot before feeding shell input (TCG in CI is
# slower than KVM, so allow a margin).
BOOT_WAIT="${BOOT_WAIT:-3}"

# Capture a plain boot (no input) to a log file.
boot_capture() { # boot_capture <log> <mem> [extra qemu args...]
    local log="$1" mem="$2"; shift 2
    timeout 15 qemu-system-x86_64 -M q35 -m "$mem" "$@" -cdrom "$ISO" \
        -serial "file:$log" -display none -no-reboot >/dev/null 2>&1 || true
}
# Boot and feed the shell some input over serial, capturing output.
boot_shell() { # boot_shell <log> <mem> <input> [extra qemu args...]
    local log="$1" mem="$2" input="$3"; shift 3
    ( sleep "$BOOT_WAIT"; printf '%b' "$input"; sleep 2 ) | timeout 15 qemu-system-x86_64 \
        -M q35 -m "$mem" "$@" -cdrom "$ISO" \
        -chardev stdio,id=c0,logfile="$log",signal=off -serial chardev:c0 \
        -display none -no-reboot >/dev/null 2>&1 || true
}

# The subsystem success markers we expect on every boot.
check_markers() { # check_markers <log> <prefix-label>
    local log="$1" p="$2"
    assert_in "$log" "[GDT] GDT initialized."                     "$p GDT init"
    assert_in "$log" "ltr done; TSS selector=0x28"                "$p GDT TSS loaded"
    assert_in "$log" "[IDT] IDT initialized."                     "$p IDT init"
    assert_in "$log" "recovered from #BP cleanly"                 "$p IDT self-test (int3 dump+recover)"
    assert_in "$log" "[PIC] PIC + PIT initialized."               "$p PIC/PIT init"
    assert_in "$log" "[PMM] Physical memory manager initialized." "$p PMM init"
    assert_in "$log" "free-count restored: true"                  "$p PMM self-test (alloc/free)"
    assert_in "$log" "[VMM] Virtual memory manager initialized."  "$p VMM init"
    assert_in "$log" "HHDM alias of that frame agrees: OK"        "$p VMM self-test (mapping)"
    assert_in "$log" "W^X enforced: OK"                           "$p W^X enforced"
    assert_in "$log" "[HEAP] Kernel heap initialized."            "$p heap init"
    assert_in "$log" "create/destroy=true, slice=true, ArrayList=true" "$p heap self-test (std allocator)"
    assert_in "$log" "[CON] Framebuffer console initialized."     "$p framebuffer console init"
    assert_in "$log" "[KBD] Keyboard ready (IRQ1)."               "$p PS/2 keyboard init"
    assert_in "$log" "BOOT_OK"                                    "$p BOOT_OK"
    assert_in "$log" "Reclaiming bootloader-reclaimable memory"   "$p reclaim bootloader memory"
    assert_in "$log" "APIC @ 0x"                                  "$p ACPI MADT table found"
    assert_in "$log" "[ACPI] ACPI parsed."                        "$p ACPI parsing complete"
    assert_in "$log" "8259 PIC disabled."                         "$p PIC retired"
    assert_in "$log" "IRQ0 -> GSI"                                "$p APIC routes timer via I/O APIC"
    assert_in "$log" "[APIC] APIC initialized."                   "$p APIC initialized"
    assert_in "$log" "PIT retired; LAPIC timer periodic"          "$p LAPIC timer (PIT retired)"
}

# --- Boot-marker tests, both firmwares ---------------------------------------
echo "== Boot markers: legacy BIOS (512 MiB) =="
boot_capture "$TMP/bios.log" 512M
check_markers "$TMP/bios.log" "BIOS:"

# Assemble the QEMU firmware args for whichever OVMF layout we found.
uefi_args=()
if [ -n "$OVMF" ]; then
    uefi_args=(-bios "$OVMF")
elif [ -n "$OVMF_CODE" ] && [ -n "$OVMF_VARS" ]; then
    cp "$OVMF_VARS" "$TMP/vars.fd" # writable copy of the vars store
    uefi_args=(-drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE"
               -drive "if=pflash,format=raw,file=$TMP/vars.fd")
fi
if [ "${#uefi_args[@]}" -gt 0 ]; then
    echo "== Boot markers: UEFI (2 GiB) =="
    boot_capture "$TMP/uefi.log" 2G "${uefi_args[@]}"
    check_markers "$TMP/uefi.log" "UEFI:"
else
    echo "  (skipping UEFI: no OVMF firmware found)"
fi

# --- Shell interaction -------------------------------------------------------
echo "== Shell commands =="
boot_shell "$TMP/shell.log" 512M 'help\rmem\ruptime\recho test123\rbogus\r'
assert_in "$TMP/shell.log" "commands: help, clear"        "shell: help"
assert_in "$TMP/shell.log" "frames free"                  "shell: mem"
assert_in "$TMP/shell.log" "ticks @ 100 Hz"               "shell: uptime"
assert_in "$TMP/shell.log" "test123"                      "shell: echo"
assert_in "$TMP/shell.log" "unknown command: bogus"       "shell: unknown command"

# --- History recall (Up arrow re-runs a command) -----------------------------
echo "== Shell history (Up arrow) =="
boot_shell "$TMP/hist.log" 512M 'echo zqx\r\x1b[A\r'
# "zqx" is printed once per run; history recall + Enter runs it a second time.
runs=$(tr -d '\r' < "$TMP/hist.log" | grep -c '^zqx$')
if [ "$runs" -ge 2 ]; then ok "history: Up arrow recalled + re-ran command (zqx printed ${runs}x)"; else bad "history: recall (zqx printed ${runs}x, expected >=2)"; fi

# --- Power commands ----------------------------------------------------------
echo "== Power commands =="
# sleep: a 1-second low-power halt that then resumes the shell.
boot_shell "$TMP/sleep.log" 512M 'sleep 1\r'
assert_in "$TMP/sleep.log" "awake." "sleep: low-power halt resumes"

# shutdown: QEMU should power off (qemu exits cleanly, not killed by timeout=124).
( sleep "$BOOT_WAIT"; printf 'shutdown\r'; sleep 4 ) | timeout 15 qemu-system-x86_64 \
    -M q35 -m 512M -cdrom "$ISO" -chardev stdio,id=c0,signal=off -serial chardev:c0 \
    -display none -no-reboot >/dev/null 2>&1
if [ "$?" -ne 124 ]; then ok "shutdown: machine powered off"; else bad "shutdown: qemu did not exit"; fi

# restart: WITHOUT -no-reboot, the reset reboots and the kernel runs a 2nd time.
( sleep "$BOOT_WAIT"; printf 'restart\r'; sleep 4 ) | timeout 15 qemu-system-x86_64 \
    -M q35 -m 512M -cdrom "$ISO" -chardev stdio,id=c0,logfile="$TMP/restart.log",signal=off \
    -serial chardev:c0 -display none >/dev/null 2>&1 || true
boots=$(grep -ac "Kernel entered _start" "$TMP/restart.log")
if [ "$boots" -ge 2 ]; then ok "restart: machine rebooted (booted ${boots}x)"; else bad "restart: booted ${boots}x (expected >=2)"; fi

# --- Framebuffer actually drew something (optional) --------------------------
if command -v socat >/dev/null && command -v convert >/dev/null; then
    echo "== Framebuffer render =="
    sock="$TMP/mon.sock"; ppm="$TMP/fb.ppm"
    ( sleep "$((BOOT_WAIT + 2))" ) | qemu-system-x86_64 -M q35 -m 512M -vga std -cdrom "$ISO" \
        -monitor "unix:$sock,server,nowait" \
        -chardev stdio,id=c0,signal=off -serial chardev:c0 \
        -display none -no-reboot >/dev/null 2>&1 &
    qpid=$!
    sleep "$((BOOT_WAIT + 1))"
    echo "screendump $ppm" | socat - "unix-connect:$sock" >/dev/null 2>&1
    sleep 0.5; kill $qpid 2>/dev/null; wait $qpid 2>/dev/null
    if [ -f "$ppm" ]; then
        # Mean brightness > 0 means text (non-black pixels) was drawn.
        mean=$(convert "$ppm" -colorspace Gray -format '%[fx:mean*1000]' info: 2>/dev/null | cut -d. -f1)
        if [ "${mean:-0}" -gt 0 ]; then ok "framebuffer drew text (mean brightness ${mean}/1000)"; else bad "framebuffer appears blank"; fi
    else
        bad "framebuffer screendump failed"
    fi
else
    echo "  (skipping framebuffer render test: needs socat + imagemagick)"
fi

# --- Summary -----------------------------------------------------------------
echo ""
echo "================ RESULTS: $PASS passed, $FAIL failed ================"
if [ "$FAIL" -ne 0 ] && [ -f "$TMP/bios.log" ]; then
    echo ""
    echo "--- BIOS serial log (for debugging) ---"
    cat "$TMP/bios.log"
fi
[ "$FAIL" -eq 0 ]
