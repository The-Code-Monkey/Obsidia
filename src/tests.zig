// Unit-test aggregator. `zig build test` compiles this for the host (not the
// freestanding kernel target) and runs the test blocks from each module that is
// host-testable — i.e. modules that don't pull in the `limine` build module or
// touch real hardware at module scope. Referencing a module with `_ = @import`
// inside a test pulls its test blocks into this build.
test {
    _ = @import("drivers/keyboard.zig"); // scancode translation, escape sequences
    _ = @import("drivers/console.zig"); // PSF font parsing
}
