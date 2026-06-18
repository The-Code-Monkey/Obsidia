=================
``src/tests.zig``
=================

   Host-side unit-test aggregator that pulls in the test blocks from host-testable kernel modules.

What it does
============

``zig build test`` compiles this file for the **host** (not the freestanding kernel target) and runs it. The single top-level ``test {}`` block references the modules whose test blocks should run; referencing a module with ``_ = @import(...)`` inside a test pulls that module's test blocks into the build. Only modules that don't depend on the ``limine`` build module or touch real hardware at module scope are safe to include here.

Key components
==============

- Top-level ``test {}`` block — aggregates the test suites by importing:

  - ``drivers/keyboard.zig`` — scancode translation and escape-sequence tests.
  - ``drivers/console.zig`` — PSF font-parsing tests.

Depends on / used by
====================

- **Imports:** ``drivers/keyboard.zig`` and ``drivers/console.zig`` (for their test blocks only).
- **Used by:** the ``zig build test`` step in the build system; not referenced by the running kernel.

Notes
=====

- To add a module to the host test run, it must be host-compilable: no ``limine`` import and no hardware access at module (top-level) scope. Add a matching ``_ = @import("...")`` line here to include it.
