#!/bin/bash
# Canonical producer for the /INIT flat test binary — the SINGLE source of truth
# for its bytes, shared by run.sh (interactive) and tests/run.sh (harness) so the
# code and its ABI can never drift between them.
# Uses bash (not /bin/sh): its printf interprets the \xHH hex escapes below;
# dash's printf would emit them literally and corrupt the binary.
#
# It is a hand-assembled flat x86-64 binary (no assembler needed) that runs as a
# RING-3 USER PROCESS under the syscall ABI: it makes a write() syscall to print a
# marker, then exit()s. (The old version used `out` to COM1 and returned a magic —
# but `out` is privileged and faults at CPL3, and ring-3 code signals completion
# with exit(), not a return value.) The syscall ABI: number in RAX, args in
# RDI/RSI/RDX; SYS_write=1, SYS_exit=3. Position-independent via RIP-relative lea.
#
#   0:  b8 01 00 00 00         mov  eax, 1            ; SYS_write
#   5:  bf 01 00 00 00         mov  edi, 1            ; fd = 1 (stdout)
#   a:  48 8d 35 12 00 00 00   lea  rsi, [rip+0x12]   ; rsi = &msg (at 0x23)
#  11:  ba 18 00 00 00         mov  edx, 24           ; len = 24 bytes of msg
#  16:  0f 05                  syscall                ; write(1, msg, 24)
#  18:  b8 03 00 00 00         mov  eax, 3            ; SYS_exit
#  1d:  31 ff                  xor  edi, edi          ; code = 0
#  1f:  0f 05                  syscall                ; exit(0) — does not return
#  21:  eb fe                  jmp  $                 ; safety: spin if exit returns
#  23:  msg: "INIT: hello from FAT32!\n"             ; 24 bytes (no NUL — len is explicit)
#
# Usage: tests/make-init.sh <output-path>
out="${1:?usage: make-init.sh <output-path>}"
printf '\xb8\x01\x00\x00\x00\xbf\x01\x00\x00\x00\x48\x8d\x35\x12\x00\x00\x00\xba\x18\x00\x00\x00\x0f\x05\xb8\x03\x00\x00\x00\x31\xff\x0f\x05\xeb\xfe' > "$out"
printf 'INIT: hello from FAT32!\n' >> "$out"
