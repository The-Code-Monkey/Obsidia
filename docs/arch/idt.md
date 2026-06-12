# `src/arch/idt.zig`

> Installs the Interrupt Descriptor Table and the CPU exception/interrupt handlers, turning otherwise-silent faults into readable serial crash dumps.

## What it does
This is the kernel's primary debugging tool: without it a CPU exception with no handler escalates to a double fault, then a triple fault, then a silent reset. With it, the offending vector, error code, and full register state are dumped to serial. The mechanism is 256 comptime-generated stubs that normalize the stack (pushing a dummy error code where the CPU doesn't), push their vector number, and jump to one shared trampoline (`isrCommon`) which saves all GP registers, calls the Zig handler, restores, and `iretq`s.

## Key components

Types and storage:
- `InterruptFrame` — `extern struct` mirroring the exact stack layout left by the stubs, `isrCommon`, and the CPU (all GPRs, `vector`, `error_code`, and the CPU-pushed `rip`/`cs`/`rflags`/`rsp`/`ss`).
- `IdtEntry` — `packed struct` for a 16-byte gate descriptor (handler offset split across three fields, selector, `ist`, `type_attr`).
- `Idtr` — `packed struct` operand for `lidt`.
- `idt` (256 gates) and `idtr` — the table and its pointer.
- `selftest_breakpoint` — when `true`, `init()` executes `int3` each boot to exercise the dump/recover path.

Stub generation:
- `hasErrorCode(vector)` — which vectors push a hardware error code (8, 10-14, 17, 21, 29, 30).
- `makeStub(vector)` — produce a per-vector naked function (comptime-built assembly).
- `stub_table` — the comptime 256-entry table of stub pointers.
- `isrCommon()` — exported naked trampoline that saves/restores all GPRs and calls `isrHandler`.

Handlers and dump:
- `isrHandler(frame)` — exported C-ABI handler: dumps and halts on fatal exceptions (vectors < 32), returns on `#BP` (vector 3, the self-test), dispatches vectors 32-47 to `pic.handleIrq`, ignores the LAPIC spurious vector (`0xFF`), and logs anything else.
- `dumpException(frame)` — prints the full machine state; decodes the `#PF` (vector 14) error-code bits and reads `CR2`.
- `exceptionName(v)` — maps a vector to its human-readable mnemonic (`#DE`, `#GP`, `#PF`, …).
- `readCr0`/`readCr2`/`readCr3`/`readCr4` — control-register reads for the dump.
- `hang()` — `cli; hlt` loop for unrecoverable faults.
- `setEntry(vector, handler, ist)` — fill one gate.
- `init()` — installs all 256 gates (routing `#DF`/vector 8 to IST1), runs `lidt`, and optionally runs the `int3` self-test.

## Depends on / used by
- **Imports:** `std` (for `comptimePrint`), `../drivers/serial.zig` (logging), `gdt.zig` (`KERNEL_CODE` selector), `pic.zig` (hardware IRQ dispatch).
- **Used by:** Called after `gdt.init()` in the boot sequence. Hardware IRQs (vectors 32-47) funnel from `isrHandler` into `pic.handleIrq`.

## Notes
- The push order in `isrCommon` is the exact reverse of `InterruptFrame`'s field order, so after the pushes `RSP` points at a fully-populated frame; `InterruptFrame` must stay an `extern struct` of `u64`s (no padding) to match.
- Every stub presents an identical stack layout because non-error-code vectors push a dummy `0`; `isrCommon` discards both `vector` and `error_code` with `add $16, %rsp` before `iretq`.
- Vector 3 (`#BP`) is treated as recoverable (the self-test returns); every other exception below 32 is fatal and halts. There is no fault recovery yet.
- `#DF` (vector 8) runs on IST1, giving it a known-good stack even if the kernel stack is corrupt.
