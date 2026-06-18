#!/bin/bash
# Canonical producer for the /SPIN flat test binary — a ring-3 user program that
# prints a marker and then loops FOREVER. Used by the harness to test Ctrl-C ->
# SIGINT: exec it from the shell, confirm it started, send Ctrl-C, and confirm the
# shell regains control (the otherwise-infinite program was terminated).
# Uses bash (not /bin/sh): its printf interprets the \xHH hex escapes; dash would
# emit them literally and corrupt the binary.
#
# Hand-assembled flat x86-64, ring-3 syscall ABI (number in RAX, args RDI/RSI/RDX;
# SYS_write=1). Position-independent via RIP-relative lea.
#
#   0:  b8 01 00 00 00         mov  eax, 1            ; SYS_write
#   5:  bf 01 00 00 00         mov  edi, 1            ; fd = 1 (stdout)
#   a:  48 8d 35 09 00 00 00   lea  rsi, [rip+0x9]    ; rsi = &msg (at 0x1a)
#  11:  ba 0e 00 00 00         mov  edx, 14           ; len = 14 bytes of msg
#  16:  0f 05                  syscall                ; write(1, msg, 14)
#  18:  eb fe                  jmp  $                 ; loop forever (never exits)
#  1a:  msg: "SPIN: running\n"                        ; 14 bytes (no NUL — len explicit)
#
# Usage: tests/make-spin.sh <output-path>
out="${1:?usage: make-spin.sh <output-path>}"
printf '\xb8\x01\x00\x00\x00\xbf\x01\x00\x00\x00\x48\x8d\x35\x09\x00\x00\x00\xba\x0e\x00\x00\x00\x0f\x05\xeb\xfe' > "$out"
printf 'SPIN: running\n' >> "$out"
