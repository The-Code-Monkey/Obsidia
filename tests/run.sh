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

# CPU model for every QEMU boot below. The kernel turns on SMEP/SMAP (CR4.20/21)
# when CPUID advertises them, but QEMU's default TCG CPU (qemu64) does NOT expose
# those bits — so we explicitly add +smep,+smap to exercise (and assert) that
# path. This also proves SMAP doesn't break the ring-3/syscall flow: the only
# kernel->user dereference (sysWrite) brackets itself with STAC/CLAC, every other
# boot here runs with SMAP armed. Override with QEMU_CPU=... if needed.
QEMU_CPU="${QEMU_CPU:-qemu64,+smep,+smap}"
QEMU="qemu-system-x86_64 -cpu $QEMU_CPU"

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
    timeout 15 $QEMU -M q35 -m "$mem" "$@" -cdrom "$ISO" \
        -serial "file:$log" -display none -no-reboot >/dev/null 2>&1 || true
}
# Boot and feed the shell some input over serial, capturing output.
boot_shell() { # boot_shell <log> <mem> <input> [extra qemu args...]
    local log="$1" mem="$2" input="$3"; shift 3
    ( sleep "$BOOT_WAIT"; printf '%b' "$input"; sleep 2 ) | timeout 15 $QEMU \
        -M q35 -m "$mem" "$@" -cdrom "$ISO" \
        -chardev stdio,id=c0,logfile="$log",signal=off -serial chardev:c0 \
        -display none -no-reboot >/dev/null 2>&1 || true
}

# waitfor <pattern> <log> <pid> : poll a log until the (egrep) pattern appears, the
# guest exits, or a ~150 s cap — so timed input never races the (slow, TCG) boot.
waitfor() { local p="$1" f="$2" pid="$3" n=0; until grep -qaE "$p" "$f" 2>/dev/null || ! kill -0 "$pid" 2>/dev/null; do sleep 0.5; n=$((n + 1)); [ "$n" -gt 300 ] && break; done; }

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
    assert_in "$log" "[CPU] SMEP enabled"                         "$p CPU SMEP enabled (CR4.SMEP)"
    assert_in "$log" "[CPU] SMAP enabled"                         "$p CPU SMAP enabled (CR4.SMAP)"
    assert_in "$log" "HHDM alias of that frame agrees: OK"        "$p VMM self-test (mapping)"
    assert_in "$log" "W^X enforced: OK"                           "$p W^X enforced"
    assert_in "$log" "uncacheable-MMIO self-test: round-trip OK, PCD set" "$p VMM: uncacheable MMIO mapping (PCD/UC)"
    assert_in "$log" "guarded-stack self-test: guard-unmapped=true stack-mapped=true rw=true" "$p kernel stacks: unmapped guard page below each (overflow -> #PF)"
    assert_in "$log" "[HEAP] Kernel heap initialized."            "$p heap init"
    assert_in "$log" "create/destroy=true, slice=true, ArrayList=true" "$p heap self-test (std allocator)"
    assert_in "$log" "[CON] Framebuffer console initialized."     "$p framebuffer console init"
    assert_in "$log" "lines retained"                             "$p console scrollback buffer ready"
    assert_in "$log" "[KBD] Keyboard ready (IRQ1)."               "$p PS/2 keyboard init"
    assert_in "$log" "[MOUSE] Mouse ready (IRQ12)"                "$p PS/2 mouse init (wheel scrollback)"
    assert_in "$log" "BOOT_OK"                                    "$p BOOT_OK"
    assert_in "$log" "Reclaiming bootloader-reclaimable memory"   "$p reclaim bootloader memory"
    assert_in "$log" "APIC @ 0x"                                  "$p ACPI MADT table found"
    assert_in "$log" "[ACPI] ACPI parsed."                        "$p ACPI parsing complete"
    assert_in "$log" "8259 PIC disabled."                         "$p PIC retired"
    assert_in "$log" "IRQ0 -> GSI"                                "$p APIC routes timer via I/O APIC"
    assert_in "$log" "[APIC] APIC initialized."                   "$p APIC initialized"
    assert_in "$log" "PIT retired; LAPIC timer periodic"          "$p LAPIC timer (PIT retired)"
    assert_in "$log" "B: iteration 3"                             "$p scheduler round-robin (threads interleave)"
    assert_in "$log" "back in main; all threads finished"         "$p scheduler returns to main"
    assert_in "$log" "Scheduler self-test complete."              "$p cooperative context switching"
    assert_in "$log" "preempt P1: finished"                      "$p preemption: worker P1 ran without yielding"
    assert_in "$log" "preempt P2: finished"                      "$p preemption: worker P2 ran without yielding"
    assert_in "$log" "Preemptive demo complete."                 "$p timer-driven preemption"
    assert_in "$log" "blocking-sleep self-test: slept, woke OK"  "$p blocking sleep (thread sleeps, timer wakes it)"
    assert_in "$log" "blocking mutex self-test: mutual exclusion held" "$p blocking mutex (two threads contend; mutual exclusion + handoff)"
    assert_in "$log" "Ring-3 self-test OK"                       "$p ring 3: ran user code at CPL3 + recovered from its #GP"
    assert_in "$log" "Syscall round-trip OK"                     "$p syscall/sysret: ring 3 -> kernel -> ring 3 round trip"
    assert_in "$log" "hello from ring 3 via syscall"             "$p write() syscall: ring 3 buffer reached serial"
    assert_in "$log" "exit syscall returned to the kernel"       "$p exit() syscall: returned control to the kernel"
    assert_in "$log" "Address-space self-test OK"                "$p VMM: per-process address space (create/switch/isolate/destroy)"
    assert_in "$log" "User-process self-test OK"                 "$p process model: ring-3 process + kernel thread co-scheduled across address spaces"
    assert_in "$log" "[PCI] Enumeration complete:"               "$p PCI: bus enumeration completed (config mechanism #1)"
    assert_in "$log" "class 01.06 prog-if 01"                    "$p PCI: decoded the AHCI controller (class/subclass/prog-if)"
    assert_in "$log" "BAR5: MMIO32"                              "$p PCI: decoded + sized a device BAR (MMIO)"
    assert_in "$log" "[DMA] DMA buffer allocator initialized."   "$p DMA: contiguous <4 GiB buffer allocator init"
    assert_in "$log" "aligned=true nonzero=true below-4G=true"   "$p DMA: buffer page-aligned, nonzero, 32-bit-addressable"
    assert_in "$log" "contiguous=true hhdm-round-trip=true"      "$p DMA: frames contiguous + HHDM alias round-trips"
    assert_in "$log" "[DMA]     freed; free-count restored: true" "$p DMA: free returns the whole run (no leak)"
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

# --- ATA PIO disk driver -----------------------------------------------------
# Legacy ATA PIO needs the i440fx machine (-M pc) for its PIIX3 IDE controller;
# the q35 machine used above has only AHCI/SATA, where this driver finds nothing.
# We attach a raw disk with a known marker at sector 0 and check the driver
# detects the disk (correct size) and reads that marker back.
echo "== ATA PIO disk (i440fx / -M pc) =="
ATADISK="$TMP/ata.img"
truncate -s 16M "$ATADISK"
printf 'OBSIDIA_ATA_OK\0\0' | dd of="$ATADISK" conv=notrunc bs=1 count=16 2>/dev/null
timeout 15 $QEMU -M pc -m 512M -boot d -cdrom "$ISO" \
    -drive file="$ATADISK",format=raw,if=ide \
    -serial "file:$TMP/ata.log" -display none -no-reboot >/dev/null 2>&1 || true
assert_in "$TMP/ata.log" "primary master present: 32768 sectors" "ATA: detects disk size via IDENTIFY (16 MiB)"
assert_in "$TMP/ata.log" "LBA0[0..16]='OBSIDIA_ATA_OK"           "ATA: reads sector 0 contents correctly"
assert_in "$TMP/ata.log" "self-test: read LBA 0 OK"              "ATA: PIO sector read succeeds"
assert_in "$TMP/ata.log" "write/read-back last sector OK"        "ATA: PIO sector write succeeds (non-destructive)"
# And confirm a disk-less boot stays graceful (the q35 BIOS marker boot has no
# disk attached, so the driver must report "no disk" there and still reach BOOT_OK).
assert_in "$TMP/bios.log" "no device (floating bus" "ATA: disk-less boot reports no disk and continues"

# --- AC'97 audio driver ------------------------------------------------------
# The default boot has no audio device, so attach an AC'97 codec on q35 and check
# the driver finds it, brings the codec ready, configures the mixer, and that the
# bus-master DMA engine actually streams the test tone (the PICB position falls).
echo "== AC'97 audio (-device AC97) =="
timeout 15 $QEMU -M q35 -m 512M -cdrom "$ISO" \
    -audiodev none,id=snd0 -device AC97,audiodev=snd0 \
    -serial "file:$TMP/ac97.log" -display none -no-reboot >/dev/null 2>&1 || true
assert_in "$TMP/ac97.log" "class 04.01"                          "AC97: PCI enum found a multimedia/audio controller"
assert_in "$TMP/ac97.log" "[AC97]   codec ready=true"           "AC97: codec came ready out of cold reset"
assert_in "$TMP/ac97.log" "DAC rate=48000 Hz"                   "AC97: mixer configured (VRA, 48 kHz DAC)"
assert_in "$TMP/ac97.log" "[AC97]   playback started:"          "AC97: BDL programmed + bus-master DMA started"
assert_in "$TMP/ac97.log" "self-test OK: DMA playback advanced" "AC97: DMA engine streamed the tone (PICB advanced)"
# And confirm the audio-less default boot stays graceful (no device -> skip).
assert_in "$TMP/bios.log" "no AC'97 device found"               "AC97: audio-less boot skips cleanly and continues"

# --- AHCI/SATA disk driver (read-only) ---------------------------------------
# q35 has a built-in ICH9 AHCI controller; we attach a SECOND ich9-ahci HBA with a
# raw SATA disk (a known marker at sector 0 plus an MBR 0x55AA boot signature) and
# check the driver enables the HBA, detects the disk + its SATA signature, runs
# IDENTIFY (model string), and reads sector 0 over bus-master DMA. -boot d forces
# CD boot since the disk carries a boot signature. The q35 built-in AHCI on the BIOS
# marker boot above (no disk) already proves the no-disk path; here we prove a real
# disk works end to end.
echo "== AHCI/SATA disk (-device ich9-ahci + ide-hd) =="
AHCIDISK="$TMP/ahci.img"
truncate -s 16M "$AHCIDISK"
printf 'OBSIDIA_AHCI_OK\0' | dd of="$AHCIDISK" conv=notrunc bs=1 count=16 2>/dev/null
printf '\x55\xaa' | dd of="$AHCIDISK" conv=notrunc bs=1 seek=510 count=2 2>/dev/null
timeout 30 $QEMU -M q35 -m 512M -boot d -cdrom "$ISO" \
    -drive id=hd0,file="$AHCIDISK",if=none,format=raw \
    -device ich9-ahci,id=ahci -device ide-hd,drive=hd0,bus=ahci.0 \
    -serial "file:$TMP/ahci.log" -display none -no-reboot >/dev/null 2>&1 || true
assert_in "$TMP/ahci.log" "class 01.06"                          "AHCI: PCI enum found a mass-storage/SATA controller"
assert_in "$TMP/ahci.log" "AHCI enabled, version"                "AHCI: HBA brought up (AHCI-enable + reset)"
assert_in "$TMP/ahci.log" "SATA disk confirmed on port"          "AHCI: detected the SATA disk + its device signature"
assert_in "$TMP/ahci.log" "model='QEMU HARDDISK'"                "AHCI: IDENTIFY DEVICE returned the model string"
assert_in "$TMP/ahci.log" "LBA0[0..16]='OBSIDIA_AHCI_OK"         "AHCI: read sector 0 contents correctly (DMA)"
assert_in "$TMP/ahci.log" "boot-signature=true"                  "AHCI: sector-0 MBR 0x55AA boot signature read back"
assert_in "$TMP/ahci.log" "self-test OK: IDENTIFY model present" "AHCI: IDENTIFY + sector-0 DMA read self-test passed"
# And confirm a controller-less boot stays graceful: the -M pc (i440fx) ATA boot
# above has no AHCI HBA, so the driver must report "no controller" and continue.
assert_in "$TMP/ata.log" "no AHCI controller found"             "AHCI: controller-less boot (-M pc) skips cleanly and continues"

# --- FAT32 filesystem (read-only) --------------------------------------------
# Format a FAT32 disk (mtools only — no root needed), seed known files including
# a subdirectory and a long-name file, then boot and drive `ls`/`cat` to confirm
# the kernel mounts it, lists directories (8.3 + LFN), and reads file contents.
# -boot d forces CD boot since a FAT32 disk carries a 0x55AA boot signature.
echo "== FAT32 filesystem (read-only, -M pc) =="
FATDISK="$TMP/fat.img"
truncate -s 64M "$FATDISK"
mformat -i "$FATDISK" -F -v OBSIDIA :: 2>/dev/null

# make_init_elf <file> : build the /INIT.ELF test program — a real, statically
# linked ELF64 ET_EXEC produced by the Zig toolchain (zig cc + zig ld.lld), so
# the ELF loader path is exercised end-to-end against a genuine linked binary
# rather than a hand-rolled header. The program is freestanding x86-64 asm that
# runs as a RING-3 user process: it write()s a marker via the syscall ABI, then
# exit()s (not the old privileged `out` + return-magic — `out` faults at CPL3).
# It is linked into the LOW (user) half with two PAGE-DISJOINT load segments —
# .text (R+X) and .rodata (R only, non-exec) — so the loader's PER-SEGMENT W^X
# mapping is tested: one segment must come out executable, the other not.
# Returns non-zero (and leaves "$1" absent) if the toolchain can't build it, so
# the caller can skip the ELF checks rather than fail spuriously.
make_init_elf() {
    local out="$1" d
    d=$(mktemp -d) || return 1
    cat > "$d/init.s" <<'ASM'
# Freestanding ELF init (ring 3): write() a marker, then exit(). Syscall ABI:
# number in RAX, args in RDI/RSI/RDX; SYS_write=1, SYS_exit=3.
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
    # Linker script: load into the low (user) half, .text and .rodata on separate
    # pages so they become two distinct PT_LOAD segments with different perms.
    cat > "$d/init.ld" <<'LDS'
ENTRY(_start)
SECTIONS {
    . = 0x400000;
    .text   : { *(.text*) }
    . = ALIGN(0x1000);
    .rodata : { *(.rodata*) }
}
LDS
    zig cc -target x86_64-freestanding-none -nostdlib -c "$d/init.s" -o "$d/init.o" 2>/dev/null || { rm -rf "$d"; return 1; }
    # -z max-page-size=0x1000 keeps the two load segments page-disjoint so each
    # gets its own permissions (rather than being merged into one R+E segment).
    zig ld.lld -o "$out" -T "$d/init.ld" --static -z max-page-size=0x1000 "$d/init.o" 2>/dev/null || { rm -rf "$d"; return 1; }
    rm -rf "$d"
    [ -s "$out" ]   # success only if a non-empty ELF was produced
}

# make_evil_elf <file> : build an OUT-OF-BOUNDS ELF whose first PT_LOAD segment is
# linked AT USER_LIMIT (0x0000_8000_0000_0000) — the first address above the user
# half. A correct loader must REFUSE to map it (the segment would escape user
# space and could land over the kernel half); a buggy loader would map and run it.
# Same freestanding-asm program as make_init_elf, but its marker is distinct so we
# can assert it NEVER prints (i.e. the evil code never executed). Returns non-zero
# (leaving "$1" absent) if the toolchain can't build it, so the caller can skip.
make_evil_elf() {
    local out="$1" d
    d=$(mktemp -d) || return 1
    cat > "$d/evil.s" <<'ASM'
# Same write()+exit() init, but with a marker that proves it ran if it ever does.
.section .text
.global _start
_start:
    movl    $1, %eax                # SYS_write
    movl    $1, %edi                # fd = 1 (stdout)
    lea     msg(%rip), %rsi         # rsi = &msg (RIP-relative)
    movl    $(msg_end - msg), %edx  # len
    syscall                         # write(1, msg, len)
    movl    $3, %eax                # SYS_exit
    xorl    %edi, %edi              # code = 0
    syscall                         # exit(0)
1:  jmp     1b
.section .rodata
msg:
    .ascii  "EVIL.ELF: out-of-bounds segment RAN!\n"
msg_end:
ASM
    # Linker script: place .text at USER_LIMIT itself, so the first PT_LOAD's
    # p_vaddr == 0x0000_8000_0000_0000 — at/above the user limit. The loader's
    # ring-3 bounds check (p_vaddr < USER_LIMIT) must reject this.
    cat > "$d/evil.ld" <<'LDS'
ENTRY(_start)
SECTIONS {
    . = 0x800000000000;
    .text   : { *(.text*) }
    . = ALIGN(0x1000);
    .rodata : { *(.rodata*) }
}
LDS
    zig cc -target x86_64-freestanding-none -nostdlib -c "$d/evil.s" -o "$d/evil.o" 2>/dev/null || { rm -rf "$d"; return 1; }
    zig ld.lld -o "$out" -T "$d/evil.ld" --static -z max-page-size=0x1000 "$d/evil.o" 2>/dev/null || { rm -rf "$d"; return 1; }
    rm -rf "$d"
    [ -s "$out" ]   # success only if a non-empty ELF was produced
}

fattmp=$(mktemp)
printf 'Hello from FAT32 on Obsidia!\n' > "$fattmp"; mcopy -i "$FATDISK" "$fattmp" ::/HELLO.TXT
mmd -i "$FATDISK" ::/docs 2>/dev/null
printf 'nested file contents ok\n'      > "$fattmp"; mcopy -i "$FATDISK" "$fattmp" ::/docs/NOTES.TXT
printf 'long names work too\n'          > "$fattmp"; mcopy -i "$FATDISK" "$fattmp" "::/a-long-filename.txt"
# /INIT (flat, ring-3 user ABI) is produced by the shared canonical helper (one
# source of truth for the binary's bytes, see tests/make-init.sh) so it can't
# drift from run.sh. /INIT0 is its ring-0-ABI counterpart for the legacy exec0
# path (see tests/make-init0.sh).
tests/make-init.sh "$fattmp";                        mcopy -i "$FATDISK" "$fattmp" ::/INIT
tests/make-init0.sh "$fattmp";                       mcopy -i "$FATDISK" "$fattmp" ::/INIT0
# Seed the real ELF init too (if the toolchain can build it). The boot self-test
# prefers /INIT.ELF when present, so it exercises the ELF path automatically; we
# also drive `exec /INIT.ELF` (ELF) and `exec /INIT` (flat) in ring 3 from the
# shell, plus `exec0 /INIT0` for the ring-0 path, to prove all are reachable and
# re-runnable.
HAVE_ELF=0
if make_init_elf "$fattmp"; then mcopy -i "$FATDISK" "$fattmp" ::/INIT.ELF; HAVE_ELF=1; else
    echo "  (note: could not build /INIT.ELF with the zig toolchain; ELF-path checks will be skipped)"
fi
# Seed the OUT-OF-BOUNDS "evil" ELF too (only meaningful if the ELF path works).
# Driving `exec /EVIL.ELF` proves the loader's vaddr bounds check rejects a
# segment that would escape user space. Tied to HAVE_ELF since it shares the path.
HAVE_EVIL=0
if [ "$HAVE_ELF" -eq 1 ] && make_evil_elf "$fattmp"; then mcopy -i "$FATDISK" "$fattmp" ::/EVIL.ELF; HAVE_EVIL=1; else
    [ "$HAVE_ELF" -eq 1 ] && echo "  (note: could not build /EVIL.ELF; the out-of-bounds rejection check will be skipped)"
fi
rm -f "$fattmp"
elf_cmd=""; [ "$HAVE_ELF" -eq 1 ] && elf_cmd="exec /INIT.ELF\r"
evil_cmd=""; [ "$HAVE_EVIL" -eq 1 ] && evil_cmd="exec /EVIL.ELF\r"
# Drive the cat/exec checks over a held-open FIFO, gating the start on the shell
# prompt and the end on exec0's unique success marker, with a generous timeout.
# (The old fixed-sleep + `timeout 15` form flaked under a loaded CI/TCG boot: the
# tail commands — exec /INIT, exec0 /INIT0 — were killed before they ran.)
ffifo="$TMP/fat.in"; rm -f "$ffifo"; mkfifo "$ffifo"
timeout 60 $QEMU -M pc -m 512M -boot d -cdrom "$ISO" \
    -drive file="$FATDISK",format=raw,if=ide \
    -chardev stdio,id=c0,logfile="$TMP/fat.log",signal=off -serial chardev:c0 \
    -display none -no-reboot <"$ffifo" >/dev/null 2>&1 &
fpid=$!
exec 7>"$ffifo" # hold the input open so QEMU never sees EOF
waitfor "Type 'help'" "$TMP/fat.log" "$fpid"; sleep 0.3
printf 'ls /\rcat /HELLO.TXT\rcat /docs/notes.txt\rcat /a-long-filename.txt\r' >&7; sleep 0.5
[ -n "$elf_cmd" ] && { printf '%b' "$elf_cmd" >&7; sleep 0.5; }
[ -n "$evil_cmd" ] && { printf '%b' "$evil_cmd" >&7; sleep 0.5; }
printf 'exec /INIT\r' >&7; sleep 0.5
printf 'exec0 /INIT0\r' >&7
# exec0/INIT0's "init returned 0xb017b007" marker is produced ONLY by this shell
# command (the boot self-test never runs the ring-0 path), so waiting for it
# guarantees every earlier command was processed too (the shell is sequential).
waitfor "init returned 0xb017b007" "$TMP/fat.log" "$fpid"; sleep 0.5
exec 7>&-; kill $fpid 2>/dev/null; wait $fpid 2>/dev/null
assert_in "$TMP/fat.log" "[FAT32] mounted:"                "FAT32: mounts the volume (reads the BPB)"
assert_in "$TMP/fat.log" "HELLO.TXT"                       "FAT32: lists root directory (8.3 name)"
assert_in "$TMP/fat.log" "a-long-filename.txt"             "FAT32: assembles long file names (LFN)"
assert_in "$TMP/fat.log" "Hello from FAT32 on Obsidia!"    "FAT32: reads a file's contents (cat)"
assert_in "$TMP/fat.log" "nested file contents ok"         "FAT32: resolves a nested path (/docs/notes.txt)"
assert_in "$TMP/fat.log" "long names work too"             "FAT32: reads a long-name file by path"

# --- AC'97 play (raw PCM + WAV) (FAT32 + AC97, -M pc) ------------------------
# Stream audio from the FAT32 disk to the codec. Boot -M pc with both the IDE disk
# and an AC'97 device, then drive `play` for three files exercising every path:
#   - a raw 128 KiB .pcm (> one ring of 8x8 KiB buffers, so the ring refills),
#   - a stereo 48 kHz .wav (header parse + straight-through streaming),
#   - a mono 44.1 kHz .wav (header parse + variable-rate + mono->stereo expansion).
# Content is irrelevant to the streaming path, so random data suffices.

# le <value> <nbytes>: emit a little-endian integer as raw bytes.
le() { local v=$1 n=$2 i; for ((i = 0; i < n; i++)); do printf "\\$(printf '%03o' $((v & 255)))"; v=$((v >> 8)); done; }
# mkwav <out> <channels> <rate> <data_bytes>: a canonical 16-bit PCM WAV.
mkwav() {
    local out=$1 ch=$2 rate=$3 data=$4
    { printf 'RIFF'; le $((36 + data)) 4; printf 'WAVE'
      printf 'fmt '; le 16 4; le 1 2; le "$ch" 2; le "$rate" 4; le $((rate * ch * 2)) 4; le $((ch * 2)) 2; le 16 2
      printf 'data'; le "$data" 4; head -c "$data" /dev/urandom; } > "$out"
}
# mkbadwav <out>: a MALFORMED WAV — valid RIFF/WAVE + fmt, but the "data" chunk's
# size field claims 0x7FFFFFFF (~2 GiB) while the file is only a few bytes long.
# A parser that trusts the size would skip/read absurd byte counts (hang or read
# past EOF); a hardened one must reject it gracefully. We write a tiny 4-byte body
# so the file is unambiguously smaller than the claimed length.
mkbadwav() {
    local out=$1
    { printf 'RIFF'; le $((36 + 4)) 4; printf 'WAVE'
      printf 'fmt '; le 16 4; le 1 2; le 2 2; le 48000 4; le $((48000 * 2 * 2)) 4; le 4 2; le 16 2
      printf 'data'; le 2147483647 4; head -c 4 /dev/urandom; } > "$out"  # 0x7FFFFFFF size, 4-byte body
}
echo "== AC'97 play (raw PCM + WAV, -M pc) =="
head -c 131072 /dev/urandom > "$TMP/sound.pcm" # 128 KiB raw = 32768 stereo frames
mkwav "$TMP/st48.wav" 2 48000 65536           # stereo 48 kHz, 65536 data bytes
mkwav "$TMP/mono44.wav" 1 44100 32768          # mono 44.1 kHz, 32768 data bytes -> 65536 stereo
mkbadwav "$TMP/bad.wav"                         # bogus 2 GiB data size on a tiny file
mcopy -i "$FATDISK" "$TMP/sound.pcm" ::/sound.pcm
mcopy -i "$FATDISK" "$TMP/st48.wav" ::/st48.wav
mcopy -i "$FATDISK" "$TMP/mono44.wav" ::/mono44.wav
mcopy -i "$FATDISK" "$TMP/bad.wav" ::/bad.wav
pfifo="$TMP/play.in"; rm -f "$pfifo"; mkfifo "$pfifo"
$QEMU -M pc -m 512M -boot d -cdrom "$ISO" \
    -drive file="$FATDISK",format=raw,if=ide \
    -audiodev none,id=snd0 -device AC97,audiodev=snd0 \
    -chardev stdio,id=c0,logfile="$TMP/play.log",signal=off -serial chardev:c0 \
    -display none -no-reboot <"$pfifo" >/dev/null 2>&1 &
ppid=$!
exec 6>"$pfifo" # hold the input FIFO open so QEMU never sees EOF
waitfor "Type 'help'" "$TMP/play.log" "$ppid"; sleep 0.3; printf 'play /sound.pcm\r' >&6
waitfor "streamed 131072 bytes of /sound.pcm" "$TMP/play.log" "$ppid"; sleep 0.2; printf 'play /st48.wav\r' >&6
waitfor "streamed .* of /st48.wav" "$TMP/play.log" "$ppid"; sleep 0.2; printf 'play /mono44.wav\r' >&6
waitfor "streamed .* of /mono44.wav" "$TMP/play.log" "$ppid"; sleep 0.2; printf 'play /bad.wav\r' >&6
# Malformed WAV: the parser must reject it (not hang). Once it does, prove the
# shell is still alive by echoing a marker — a crash/hang would never print it.
waitfor "not a playable WAV" "$TMP/play.log" "$ppid"; sleep 0.2; printf 'echo WAVOK\r' >&6
waitfor "WAVOK" "$TMP/play.log" "$ppid"
exec 6>&-; sleep 0.3; kill $ppid 2>/dev/null; wait $ppid 2>/dev/null
# Raw PCM path.
assert_in "$TMP/play.log" "play: streamed 131072 bytes of /sound.pcm"          "AC97: play streamed a raw .pcm file from FAT32"
assert_in "$TMP/play.log" "[AC97] play: streamed 131072 bytes (32768 frames)"  "AC97: DMA ring refilled across the raw file (frame count)"
assert_in "$TMP/play.log" "interrupt line IRQ"                                 "AC97: hooked the device's PCI interrupt line"
# Stereo WAV: header parsed, data streamed straight through.
assert_in "$TMP/play.log" "WAV 48000 Hz, 2 ch, 16-bit, 65536 data bytes"       "AC97: parsed a stereo 48 kHz WAV header"
assert_in "$TMP/play.log" "play: streamed 65536 bytes of /st48.wav"            "AC97: streamed the stereo WAV data chunk"
# Mono 44.1 kHz WAV: variable-rate + mono expanded to stereo (32768 -> 65536).
assert_in "$TMP/play.log" "WAV 44100 Hz, 1 ch, 16-bit, 32768 data bytes"       "AC97: parsed a mono 44.1 kHz WAV header"
assert_in "$TMP/play.log" "play: streamed 65536 bytes of /mono44.wav"          "AC97: mono WAV expanded to stereo (32768 -> 65536) at 44.1 kHz"
# Malformed WAV: bogus 2 GiB data size on a tiny file must be rejected (the parser
# logs a [WAV] reason and play falls back to "not a playable WAV"), and the shell
# must stay responsive afterwards — the echoed marker proves no hang/crash.
assert_in "$TMP/play.log" "[WAV] chunk size exceeds file"                      "WAV: rejected a chunk size larger than the file (no over-read)"
assert_in "$TMP/play.log" "play: not a playable WAV: /bad.wav"                 "WAV: play declined the malformed file gracefully"
assert_in "$TMP/play.log" "WAVOK"                                             "WAV: shell stayed responsive after rejecting the malformed WAV"
# Playback must be interrupt-driven: the completion IRQ fires once per buffer, so
# a multi-buffer file yields several. Assert the count is non-zero (not polled).
pirqs=$(grep -aoE "[0-9]+ completion IRQ" "$TMP/play.log" | grep -oE "^[0-9]+" | head -1)
if [ "${pirqs:-0}" -ge 1 ]; then ok "AC97: playback was interrupt-driven (${pirqs} completion IRQs)"; else bad "AC97: no completion IRQs (playback fell back to polling)"; fi

# --- Init loader (ELF64 + flat binary off the FAT32 disk) ---------------------
# Stage 5: the loader runs an init binary as a real RING-3 PROCESS — its own
# address space, USER pages, a user stack — that signals completion with the
# exit() syscall (not the old ring-0 return-magic). The boot self-test execs
# /INIT.ELF (preferred when present) in ring 3; the shell then runs `exec
# /INIT.ELF` (ELF) and `exec /INIT` (flat) in ring 3, plus `exec0 /INIT0` for the
# legacy RING-0 path that still exists alongside it. A marker can only appear if
# the loaded code itself executed (the string lives inside the binary and is
# printed by its own write() syscall / out loop). We assert every path
# independently so the auto-detect, ring-3, and ring-0 routes are all covered.
echo "== Init loader (ring-3 user process + legacy ring-0 path) =="

# Ring-3 flat path (shell `exec /INIT`): hand-assembled raw binary, auto-detected
# as non-ELF, loaded into a user address space at USER_LOAD_BASE, run at CPL3.
assert_in "$TMP/fat.log" "INIT: hello from FAT32!"                 "init(flat,ring3): the binary's own write() ran (marker on serial)"
assert_in "$TMP/fat.log" "flat binary -> "                        "init(flat): auto-detected as a flat binary"
assert_in "$TMP/fat.log" "user image ready:"                       "init(ring3): built a user address space (image + stack)"
assert_in "$TMP/fat.log" "user process exited with code 0"         "init(ring3): process exited cleanly via the exit() syscall"
assert_in "$TMP/fat.log" "[LOADER] init ran and exited cleanly."   "init: boot self-test ran /INIT.ELF in ring 3 end-to-end"
# Count clean ring-3 EXITS, not greetings: proves a process both ran and exited
# cleanly each time (boot self-test + the shell exec(s) of flat and/or ELF).
inits=$(grep -ac "user process exited with code 0" "$TMP/fat.log")
if [ "$inits" -ge 2 ]; then ok "init(ring3): re-runnable (boot self-test + shell exec = ${inits} runs)"; else bad "init(ring3): expected >=2 runs (boot + shell exec), saw ${inits}"; fi

# Legacy ring-0 path (shell `exec0 /INIT0`): the old binary contract — a flat
# binary entered as a C function in ring 0, printing via privileged `out`, and
# returning the magic 0xB017B007 to the kernel, which then unmaps the image.
assert_in "$TMP/fat.log" "INIT0: ring-0 binary contract OK!"       "init(ring0): the ring-0 binary's own code ran (marker on serial)"
assert_in "$TMP/fat.log" "calling entry point 0x"                  "init(ring0): entered the binary as a C function"
assert_in "$TMP/fat.log" "init returned 0xb017b007 (magic OK)"     "init(ring0): returned the success magic to the kernel"
assert_in "$TMP/fat.log" "image unmapped,"                         "init(ring0): image unmapped + frames freed after run"

if [ "$HAVE_ELF" -eq 1 ]; then
    # Ring-3 ELF path: a real linked ELF64 ET_EXEC. Assert it was parsed as ELF,
    # its two segments were mapped with PER-SEGMENT W^X (one R-X, one R--), the
    # .text ran at CPL3 (its marker reached serial), and the process exited.
    assert_in "$TMP/fat.log" "INIT.ELF: hello from a real ELF!"    "init(elf,ring3): the ELF's own write() ran (marker on serial)"
    assert_in "$TMP/fat.log" "ELF64 ET_EXEC, entry 0x"             "init(elf): parsed ELF64 header + entry point"
    assert_in "$TMP/fat.log" "R-X"                                 "init(elf): a segment mapped executable read-only (W^X)"
    assert_in "$TMP/fat.log" "R--"                                 "init(elf): a segment mapped non-executable read-only (W^X)"
    assert_in "$TMP/fat.log" "PT_LOAD seg"                         "init(elf): walked program headers + mapped PT_LOAD segments"
    # Re-runnable: boot self-test + shell `exec /INIT.ELF` = >=2 ELF runs.
    elfs=$(grep -ac "INIT.ELF: hello from a real ELF!" "$TMP/fat.log")
    if [ "$elfs" -ge 2 ]; then ok "init(elf): re-runnable (boot self-test + shell exec = ${elfs} runs)"; else bad "init(elf): expected >=2 runs (boot + shell exec), saw ${elfs}"; fi

    # Out-of-bounds ELF (shell `exec /EVIL.ELF`): a crafted ELF whose first PT_LOAD
    # is linked AT USER_LIMIT, so its segment would escape the user half. The loader
    # MUST reject it at the bounds check and the evil code MUST never execute. We
    # assert BOTH: the rejection marker appears, AND the evil marker never does.
    if [ "$HAVE_EVIL" -eq 1 ]; then
        assert_in "$TMP/fat.log" "ELF rejected: segment"             "init(elf): out-of-bounds PT_LOAD vaddr is rejected (bounds check)"
        if grep -qaF -- "EVIL.ELF: out-of-bounds segment RAN!" "$TMP/fat.log"; then
            bad "init(elf): SECURITY — the out-of-bounds ELF executed (loader mapped it)"
        else
            ok "init(elf): the out-of-bounds ELF never ran (its marker is absent)"
        fi
    else
        echo "  (skipping out-of-bounds ELF rejection check: /EVIL.ELF unavailable)"
    fi
else
    echo "  (skipping ELF-path checks: toolchain could not build /INIT.ELF)"
fi

# A disk-less boot must skip the loader gracefully (and still reach BOOT_OK,
# which the marker checks above already proved).
assert_in "$TMP/bios.log" "[LOADER] self-test skipped"             "init: disk-less boot skips the loader gracefully"

# --- cd + editor (FAT32 write) -----------------------------------------------
# Drive: cd into a subdir (prompt should show it), edit a file with a relative
# path (creating it via FAT32 write), save (Ctrl-S) + exit (Ctrl-X), then cat it
# back. Proves cd + relative paths + the editor + the FAT32 write/read round trip.
echo "== cd + editor (FAT32 write) =="
WRDISK="$TMP/wr.img"
truncate -s 32M "$WRDISK"
mformat -i "$WRDISK" -F -v OBSIDIA :: 2>/dev/null
mmd -i "$WRDISK" ::/docs 2>/dev/null
( sleep "$BOOT_WAIT"; printf 'cd docs\r'; sleep 0.5; \
  printf 'edit note.txt\r'; sleep 0.8; printf 'harness editor write\r'; sleep 0.4; \
  printf '\x13'; sleep 0.8; printf '\x18'; sleep 0.5; \
  printf 'cat note.txt\r'; sleep 0.8 ) \
    | timeout 20 $QEMU -M pc -m 512M -boot d -cdrom "$ISO" \
      -drive file="$WRDISK",format=raw,if=ide \
      -chardev stdio,id=c0,logfile="$TMP/wr.log",signal=off -serial chardev:c0 \
      -display none -no-reboot >/dev/null 2>&1 || true
assert_in "$TMP/wr.log" "obsidia:/docs>"        "cd: changed directory (prompt shows /docs)"
assert_in "$TMP/wr.log" "harness editor write"  "editor: created + saved a file; cat reads it back (FAT32 write)"
# Confirm the file really landed on the disk (independent host check via mtools).
if mtype -i "$WRDISK" ::/docs/note.txt 2>/dev/null | grep -qa "harness editor write"; then
    ok "editor: saved file is present on the disk (verified with mtools)"
else
    bad "editor: saved file not found on the disk"
fi

# --- Shell interaction -------------------------------------------------------
echo "== Shell commands =="
boot_shell "$TMP/shell.log" 512M 'help\rmem\ruptime\recho test123\rps\rbogus\r'
assert_in "$TMP/shell.log" "commands: help, clear"        "shell: help"
assert_in "$TMP/shell.log" "frames free"                  "shell: mem"
assert_in "$TMP/shell.log" "ticks @ 100 Hz"               "shell: uptime"
assert_in "$TMP/shell.log" "test123"                      "shell: echo"
assert_in "$TMP/shell.log" "unknown command: bogus"       "shell: unknown command"
assert_in "$TMP/shell.log" "running    shell"             "shell runs as a scheduled thread (ps)"
assert_in "$TMP/shell.log" "ready      idle"              "ps lists the idle thread"

# --- Login (scrypt) ----------------------------------------------------------
# Seed a disk with /OBSIDIA/AUTH (root:hunter2), then drive a WRONG password
# (rejected) followed by the correct one (accepted -> shell). Proves the shell
# is gated and the scrypt verify accepts/rejects correctly. Generous waits: the
# memory-hard scrypt verify takes a moment under TCG.
echo "== Login (scrypt) =="
LOGINDISK="$TMP/login.img"
truncate -s 64M "$LOGINDISK"
mformat -i "$LOGINDISK" -F -v OBSIDIA :: 2>/dev/null
mmd -i "$LOGINDISK" ::/OBSIDIA 2>/dev/null
zig run tools/mkpasswd.zig -- root hunter2 > "$TMP/authline" 2>/dev/null
mcopy -i "$LOGINDISK" "$TMP/authline" ::/OBSIDIA/AUTH
( sleep "$BOOT_WAIT"; printf 'root\r'; sleep 1; printf 'wrongpw\r'; sleep 8; \
  printf 'root\r'; sleep 1; printf 'hunter2\r'; sleep 8; printf 'mem\r'; sleep 3 ) \
    | timeout 90 $QEMU -M pc -m 512M -boot d -cdrom "$ISO" \
      -drive file="$LOGINDISK",format=raw,if=ide \
      -chardev stdio,id=c0,logfile="$TMP/login.log",signal=off -serial chardev:c0 \
      -display none -no-reboot >/dev/null 2>&1 || true
assert_in "$TMP/login.log" "Login incorrect."   "login: wrong password rejected (scrypt)"
assert_in "$TMP/login.log" "Welcome, root."     "login: correct password accepted (scrypt)"
assert_in "$TMP/login.log" "frames free"        "login: shell runs after a successful login"
# Non-regression: a disk-less boot has no credential, so it must open the shell.
assert_in "$TMP/bios.log" "no credential configured" "login: disk-less boot opens the shell (no credential)"

# --- History recall (Up arrow re-runs a command) -----------------------------
echo "== Shell history (Up arrow) =="
boot_shell "$TMP/hist.log" 512M 'echo zqx\r\x1b[A\r'
# "zqx" is printed once per run; history recall + Enter runs it a second time.
runs=$(tr -d '\r' < "$TMP/hist.log" | grep -c '^zqx$')
if [ "$runs" -ge 2 ]; then ok "history: Up arrow recalled + re-ran command (zqx printed ${runs}x)"; else bad "history: recall (zqx printed ${runs}x, expected >=2)"; fi

# --- Full-system sleep (sleep) -----------------------------------------------
echo "== Full-system sleep (sleep) =="
# `sleep` halts the whole machine (masks the LAPIC timer) until a key is pressed:
# preemption AND timekeeping stop, the CPU deep-halts, and only an input IRQ wakes
# it. We drive it over a FIFO and gate each step on a log marker (never a fixed
# delay), so input can neither race a slow TCG boot nor be swallowed by the sleep's
# stale-input drain: issue `sleep` once the shell is up, then send the wake key
# only once the guest reports it's actually asleep.
#
# We assert the observable behaviour: it halts on `sleep` and wakes on a keypress.
# We deliberately do NOT assert that the tick counter "froze" across the sleep.
# That freeze is real on hardware/KVM (a true halt with virtual time stopped), but
# under QEMU's TCG — what CI runs — the open input chardev keeps the event loop
# live, so virtual time (and the LAPIC tick count) advances during the halt
# regardless of the mask, making any wall-clock freeze comparison meaningless here.
sfifo="$TMP/sleep.in"; rm -f "$sfifo"; mkfifo "$sfifo"
timeout 30 $QEMU -M q35 -m 512M -cdrom "$ISO" \
    -chardev stdio,id=c0,logfile="$TMP/sleep.log",signal=off -serial chardev:c0 \
    -display none -no-reboot < "$sfifo" >/dev/null 2>&1 &
spid=$!
exec 5>"$sfifo" # hold the serial input open
waitfor "Type 'help'" "$TMP/sleep.log" "$spid"; sleep 0.3; printf 'sleep\r' >&5
waitfor "system sleep" "$TMP/sleep.log" "$spid"  # guest is now halted in the sleep loop
sleep 1; printf 'w' >&5                           # wake it (after the stale-input drain)
waitfor "awake." "$TMP/sleep.log" "$spid"; sleep 0.3
exec 5>&-; kill "$spid" 2>/dev/null; wait "$spid" 2>/dev/null
assert_in "$TMP/sleep.log" "system sleep" "sleep: halts the system"
assert_in "$TMP/sleep.log" "awake."       "sleep: a keypress wakes it"

# --- Power commands ----------------------------------------------------------
echo "== Power commands =="

# shutdown: QEMU should power off (qemu exits cleanly, not killed by timeout=124).
( sleep "$BOOT_WAIT"; printf 'shutdown\r'; sleep 4 ) | timeout 15 $QEMU \
    -M q35 -m 512M -cdrom "$ISO" -chardev stdio,id=c0,signal=off -serial chardev:c0 \
    -display none -no-reboot >/dev/null 2>&1
if [ "$?" -ne 124 ]; then ok "shutdown: machine powered off"; else bad "shutdown: qemu did not exit"; fi

# restart: WITHOUT -no-reboot, the reset reboots and the kernel runs a 2nd time.
( sleep "$BOOT_WAIT"; printf 'restart\r'; sleep 4 ) | timeout 15 $QEMU \
    -M q35 -m 512M -cdrom "$ISO" -chardev stdio,id=c0,logfile="$TMP/restart.log",signal=off \
    -serial chardev:c0 -display none >/dev/null 2>&1 || true
boots=$(grep -ac "Kernel entered _start" "$TMP/restart.log")
if [ "$boots" -ge 2 ]; then ok "restart: machine rebooted (booted ${boots}x)"; else bad "restart: booted ${boots}x (expected >=2)"; fi

# --- Framebuffer actually drew something (optional) --------------------------
if command -v socat >/dev/null && command -v convert >/dev/null; then
    echo "== Framebuffer render =="
    sock="$TMP/mon.sock"; ppm="$TMP/fb.ppm"
    ( sleep "$((BOOT_WAIT + 2))" ) | $QEMU -M q35 -m 512M -vga std -cdrom "$ISO" \
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

# --- Console scrollback (PageUp/PageDown) ------------------------------------
# The long boot log fills more than one screen, so there's history to scroll
# back into. We drive the scroll keys as the escape sequences a terminal sends
# (Page Up = ESC[5~, Page Down = ESC[6~) over the serial line — the same path the
# PS/2 keyboard feeds into (its 0xE0 0x49/0x51 emit those sequences; covered by a
# host unit test). Serial input arrives via a FIFO held open on fd 3, while the
# QEMU monitor (separate unix socket) screenshots before and after. PageUp must
# visibly redraw the screen (far more than the ~16 px a cursor blink could
# touch), and the serial log must show the scroll and the return to the bottom.
if command -v socat >/dev/null && command -v convert >/dev/null && command -v compare >/dev/null; then
    echo "== Console scrollback (PageUp/PageDown) =="
    sock="$TMP/sb.sock"; before="$TMP/sb_before.ppm"; after="$TMP/sb_after.ppm"
    log="$TMP/scroll.log"; fifo="$TMP/sb.in"
    rm -f "$fifo"; mkfifo "$fifo"
    $QEMU -M q35 -m 512M -vga std -cdrom "$ISO" \
        -chardev stdio,id=c0,logfile="$log",signal=off -serial chardev:c0 \
        -monitor "unix:$sock,server,nowait" \
        -display none -no-reboot <"$fifo" >/dev/null 2>&1 &
    qpid=$!
    exec 3>"$fifo" # hold the serial input FIFO open so QEMU never sees EOF
    # Gate every step on the kernel's own log markers rather than fixed sleeps:
    # under a loaded CI (TCG) the old fixed windows were too tight, so the
    # PageDown's "live" marker occasionally didn't land before we killed QEMU.
    waitfor "Type 'help'" "$log" "$qpid"; sleep 0.5 # shell up, console live
    echo "screendump $before" | socat - "unix-connect:$sock" >/dev/null 2>&1 # live screen
    sleep 0.3
    printf '\x1b[5~\x1b[5~\x1b[5~' >&3 # Page Up x3 (scroll back)
    waitfor "scrollback up:" "$log" "$qpid"; sleep 0.4 # wait until the scroll registered
    echo "screendump $after" | socat - "unix-connect:$sock" >/dev/null 2>&1 # scrolled screen
    printf '\x1b[6~\x1b[6~\x1b[6~\x1b[6~\x1b[6~' >&3 # Page Down x5 (back to live)
    waitfor "scrollback: live" "$log" "$qpid"; sleep 0.2 # wait until we reach the bottom
    exec 3>&-; sleep 0.3; kill $qpid 2>/dev/null; wait $qpid 2>/dev/null
    # Serial markers: at least one scroll-up happened, and a PageDown reached live.
    assert_in "$log" "scrollback up:"          "scrollback: PageUp scrolled the view back"
    assert_in "$log" "scrollback: live"        "scrollback: PageDown returned to the live bottom"
    # Visual proof: PageUp redrew the screen. AE (absolute pixel-difference count)
    # must be well above the ~16 px a cursor blink could cause.
    if [ -f "$before" ] && [ -f "$after" ]; then
        ae=$(compare -metric AE "$before" "$after" null: 2>&1); ae=${ae%%.*}; ae=${ae%% *}
        if [ "${ae:-0}" -gt 1000 ]; then
            ok "scrollback: PageUp visibly changed the screen (${ae} px differ)"
        else
            bad "scrollback: PageUp did not change the screen (${ae:-?} px differ)"
        fi
    else
        bad "scrollback: screendumps failed"
    fi
else
    echo "  (skipping console scrollback test: needs socat + imagemagick 'compare')"
fi

# --- In-kernel installer: construct a disk (Option B) ------------------------
# The installer carries the kernel, Limine's BOOTX64.EFI and an installed-system
# config as Limine modules, then BUILDS the target disk in-kernel: a GPT with one
# ESP, the ESP formatted as FAT32, the /EFI/BOOT//boot/limine//OBSIDIA tree, the
# files copied in, and a scrypt credential hashed in-guest. We drive `install`
# over a held-open FIFO (polling prompts, so we never race the slow TCG boot or
# the in-guest hash), verify the disk with host tools (independent of our FS
# code), then boot it under UEFI and log in to prove it is genuinely bootable.
echo "== In-kernel installer (construct a disk, -M pc) =="
CROOT="$TMP/croot"; CISO="$TMP/construct.iso"; CDISK="$TMP/construct.img"
rm -rf "$CROOT"; mkdir -p "$CROOT/boot/limine" "$CROOT/EFI/BOOT"
cp zig-out/bin/kernel.elf "$CROOT/boot/kernel.elf"          # also a module -> copied to disk
cp limine/BOOTX64.EFI "$CROOT/EFI/BOOT/BOOTX64.EFI"         # the bootloader we deploy
cp limine/BOOTIA32.EFI "$CROOT/EFI/BOOT/" 2>/dev/null || true
cp limine/limine-bios.sys limine/limine-bios-cd.bin limine/limine-uefi-cd.bin "$CROOT/boot/limine/"
printf 'timeout: 0\nserial: yes\n/Obsidia\n    protocol: limine\n    kernel_path: boot():/boot/kernel.elf\n    module_path: boot():/OBSIDIA/AUTH\n' > "$CROOT/installed.conf"
printf 'timeout: 0\nserial: yes\n/Obsidia Installer\n    protocol: limine\n    kernel_path: boot():/boot/kernel.elf\n    module_path: boot():/boot/kernel.elf\n    module_path: boot():/EFI/BOOT/BOOTX64.EFI\n    module_path: boot():/installed.conf\n' > "$CROOT/boot/limine/limine.conf"
if xorriso -as mkisofs -R -r -J -b boot/limine/limine-bios-cd.bin \
    -no-emul-boot -boot-load-size 4 -boot-info-table -hfsplus -apm-block-size 2048 \
    --efi-boot boot/limine/limine-uefi-cd.bin \
    -efi-boot-part --efi-boot-image --protective-msdos-label \
    "$CROOT" -o "$CISO" >/dev/null 2>&1; then
    ./limine/limine bios-install "$CISO" >/dev/null 2>&1
    truncate -s 64M "$CDISK"

    cfifo="$TMP/c.in"; rm -f "$cfifo"; mkfifo "$cfifo"
    timeout 240 $QEMU -M pc -m 2G -boot d -cdrom "$CISO" \
        -drive file="$CDISK",format=raw,if=ide \
        -chardev stdio,id=c0,logfile="$TMP/construct.log",signal=off -serial chardev:c0 \
        -display none -no-reboot < "$cfifo" >/dev/null 2>&1 &
    cpid=$!
    exec 4>"$cfifo" # hold the installer's serial input open
    waitfor "Type 'help'" "$TMP/construct.log" "$cpid"; sleep 0.5; printf 'install\r' >&4
    waitfor "Choose a username" "$TMP/construct.log" "$cpid"; sleep 0.3; printf 'cuser\r' >&4
    waitfor "Choose a password" "$TMP/construct.log" "$cpid"; sleep 0.3; printf 'cpass\r' >&4
    waitfor "install: complete|FAILED" "$TMP/construct.log" "$cpid"
    sleep 0.5; printf 'shutdown\r' >&4; sleep 2
    exec 4>&-; kill "$cpid" 2>/dev/null; wait "$cpid" 2>/dev/null

    assert_in "$TMP/construct.log" "install: complete" "construct: in-kernel installer built the disk"

    # Independent host verification of the freshly constructed disk.
    ESP=$((2048 * 512))
    if command -v sgdisk >/dev/null; then
        if sgdisk -p "$CDISK" 2>/dev/null | grep -qi "EF00"; then ok "construct: GPT carries an EFI System Partition (sgdisk)"; else bad "construct: no ESP in the GPT"; fi
    fi
    if mtype -i "$CDISK@@$ESP" ::/boot/limine/limine.conf 2>/dev/null | grep -qa "kernel_path"; then
        ok "construct: long-named limine.conf written + readable (LFN, via mtools)"
    else bad "construct: limine.conf missing or unreadable"; fi
    # Copy the kernel back out and byte-compare it (robust: no mdir column parsing).
    mcopy -i "$CDISK@@$ESP" ::/boot/kernel.elf "$TMP/kdump.elf" 2>/dev/null
    if cmp -s "$TMP/kdump.elf" zig-out/bin/kernel.elf; then ok "construct: kernel.elf copied byte-for-byte"; else bad "construct: kernel.elf differs from source"; fi
    if mtype -i "$CDISK@@$ESP" ::/OBSIDIA/AUTH 2>/dev/null | grep -qa "^cuser:"; then ok "construct: in-guest scrypt credential written (cuser:...)"; else bad "construct: AUTH credential missing"; fi

    # Boot the constructed disk under UEFI and log in (the real proof it boots).
    if [ "${#uefi_args[@]}" -gt 0 ]; then
        bfifo="$TMP/b.in"; rm -f "$bfifo"; mkfifo "$bfifo"
        timeout 150 $QEMU -M pc "${uefi_args[@]}" -m 2G -boot c \
            -drive file="$CDISK",format=raw,if=ide \
            -chardev stdio,id=c0,logfile="$TMP/construct_boot.log",signal=off -serial chardev:c0 \
            -display none -no-reboot < "$bfifo" >/dev/null 2>&1 &
        bpid=$!
        exec 5>"$bfifo"
        waitfor "obsidia login:" "$TMP/construct_boot.log" "$bpid"; sleep 0.5; printf 'cuser\r' >&5; sleep 1; printf 'cpass\r' >&5
        waitfor "Welcome|Login incorrect" "$TMP/construct_boot.log" "$bpid"; sleep 0.5; printf 'mem\r' >&5; sleep 2
        exec 5>&-; kill "$bpid" 2>/dev/null; wait "$bpid" 2>/dev/null
        assert_in "$TMP/construct_boot.log" "BOOT_OK"         "construct: the built disk boots under UEFI"
        assert_in "$TMP/construct_boot.log" "Welcome, cuser." "construct: login works with the in-guest credential"
    else
        echo "  (skipping construct UEFI boot: no OVMF firmware)"
    fi
else
    bad "construct: could not assemble the installer ISO (need xorriso + limine/)"
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
