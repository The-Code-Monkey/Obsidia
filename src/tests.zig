// Unit-test aggregator. `zig build test` compiles this for the host (not the
// freestanding kernel target) and runs the test blocks from each module that is
// host-testable — i.e. modules that don't pull in the `limine` build module or
// touch real hardware at module scope. Referencing a module with `_ = @import`
// inside a test pulls its test blocks into this build.
test {
    _ = @import("drivers/keyboard.zig"); // scancode translation, escape sequences
    _ = @import("tty.zig"); // terminal line discipline (Ctrl-C interrupt routing)
    _ = @import("drivers/console.zig"); // PSF font parsing
    _ = @import("auth.zig"); // Argon2id hash + verify round-trip
    _ = @import("fs/gpt.zig"); // GPT layout: protective MBR, headers, CRCs
    _ = @import("fs/fatformat.zig"); // FAT32 mkfs: BPB, FSInfo, FATs, root
    _ = @import("fs/lfn.zig"); // FAT32 long-name encoding: alias, checksum, entries
    _ = @import("fs/tmpfs.zig"); // tmpfs: in-memory create/write/read + VFS-backed reads
    _ = @import("arch/idt.zig"); // fault->signal vector mapping (pure default-action table)
}
