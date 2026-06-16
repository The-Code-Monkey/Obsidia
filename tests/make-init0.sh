#!/bin/bash
# Canonical producer for the /INIT0 flat test binary — the SINGLE source of truth
# for its bytes, shared by run.sh (interactive) and tests/run.sh (harness).
# Uses bash (not /bin/sh): its printf interprets the \xHH hex escapes below;
# dash's printf would emit them literally and corrupt the binary.
#
# This is a flat RING-0-ABI binary: the LEGACY loader contract used by the shell's
# `exec0` command (and exercised by the test harness to cover the ring-0 path that
# still exists alongside the ring-3 one). Loaded at a fixed higher-half address,
# entered at byte 0 like a C function, it prints a marker to COM1 via `out` —
# which is PRIVILEGED and therefore only legal because this runs in ring 0 — and
# returns the magic 0xB017B007 in rax. (Ring-3 user programs use the syscall ABI
# and exit() instead; see make-init.sh.) Position-independent via RIP-relative lea.
#
#   0:  48 8d 35 12 00 00 00   lea  rsi, [rip+0x12]   ; rsi = &msg (at 0x19)
#   7:  66 ba f8 03            mov  dx, 0x3f8         ; COM1 data port
#   b:  ac                     lodsb                  ; al = *rsi++
#   c:  84 c0                  test al, al            ; NUL terminator?
#   e:  74 03                  je   0x13              ; yes -> return
#  10:  ee                     out  dx, al            ; emit the byte (ring 0 only)
#  11:  eb f8                  jmp  0xb               ; next char
#  13:  b8 07 b0 17 b0         mov  eax, 0xb017b007   ; the success magic
#  18:  c3                     ret                    ; back into the kernel
#  19:  msg: "INIT0: ring-0 binary contract OK!\n\0"
#
# Usage: tests/make-init0.sh <output-path>
out="${1:?usage: make-init0.sh <output-path>}"
printf '\x48\x8d\x35\x12\x00\x00\x00\x66\xba\xf8\x03\xac\x84\xc0\x74\x03\xee\xeb\xf8\xb8\x07\xb0\x17\xb0\xc3' > "$out"
printf 'INIT0: ring-0 binary contract OK!\n\0' >> "$out"
