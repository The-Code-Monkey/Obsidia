#!/bin/bash
# Canonical producer for the /INIT flat test binary — the SINGLE source of truth.
# Uses bash (not /bin/sh): its printf interprets the \xHH hex escapes below;
# dash's printf would emit them literally and corrupt the binary.
# for its bytes, shared by run.sh (interactive) and tests/run.sh (harness) so the
# code, its entry contract, and the success magic can never drift between them.
#
# It is a hand-assembled flat x86-64 binary (no assembler needed). The kernel's
# loader contract: loaded at a fixed address, entered at byte 0, C calling
# convention, returns a magic in rax. This one prints a marker string straight to
# COM1 (port 0x3F8) and returns 0xB017B007. Position-independent via RIP-relative
# lea.
#
#   0:  48 8d 35 12 00 00 00   lea  rsi, [rip+0x12]   ; rsi = &msg (at 0x19)
#   7:  66 ba f8 03            mov  dx, 0x3f8         ; COM1 data port
#   b:  ac                     lodsb                  ; al = *rsi++
#   c:  84 c0                  test al, al            ; NUL terminator?
#   e:  74 03                  je   0x13              ; yes -> return
#  10:  ee                     out  dx, al            ; emit the byte
#  11:  eb f8                  jmp  0xb               ; next char
#  13:  b8 07 b0 17 b0         mov  eax, 0xb017b007   ; the success magic
#  18:  c3                     ret                    ; back into the kernel
#  19:  msg: "INIT: hello from FAT32!\n\0"
#
# Usage: tests/make-init.sh <output-path>
out="${1:?usage: make-init.sh <output-path>}"
printf '\x48\x8d\x35\x12\x00\x00\x00\x66\xba\xf8\x03\xac\x84\xc0\x74\x03\xee\xeb\xf8\xb8\x07\xb0\x17\xb0\xc3' > "$out"
printf 'INIT: hello from FAT32!\n\0' >> "$out"
