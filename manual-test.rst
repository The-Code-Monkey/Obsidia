==========================================================
Obsidia — Manual Testing Guide
==========================================================

:Audience: Anyone who wants to check that Obsidia works — no operating-system or
   kernel knowledge required. If you can open a terminal and copy-paste a command,
   you can follow this.
:What this is: A step-by-step checklist for building Obsidia, starting it, and trying
   each feature by hand to confirm it behaves as described.
:What this is not: The automated test suite (``tests/run.sh``) does the exhaustive,
   machine-checked testing. This guide is for a human to *see* the system working.

.. contents:: Table of Contents
   :depth: 2
   :backlinks: none

.. note::

   Obsidia runs inside QEMU, a program that pretends to be a whole PC, so you never
   need real hardware and nothing you do here can touch your own machine's disk or
   files. Everything happens in a sandbox.


1. Before you start
===================

What you need installed
-----------------------

On a Linux machine, install these once (names are for Debian/Ubuntu; other distros
have equivalents):

- **zig** version 0.14.0 — the compiler the project is built with.
- **qemu-system-x86** — the PC emulator that runs Obsidia.
- **xorriso** and **mtools** — assemble the bootable CD image.
- **ovmf** — the firmware QEMU uses for the modern "UEFI" boot path.
- **socat** and **imagemagick** — only needed by the automated suite (screenshots).

You also need the **Limine** bootloader files, which the project fetches and builds:

.. code-block:: console

   $ git clone https://github.com/limine-bootloader/limine.git --branch=v8.x-binary --depth=1
   $ make -C limine

Run that from the top of the Obsidia checkout (it creates a ``limine/`` folder the
build expects).

A word on the keyboard
----------------------

You can drive Obsidia two ways, and it helps to know which you are using:

- **Over the serial line** — your terminal window is the keyboard and screen. This is
  what the automated tests use.
- **On the emulated screen** — a separate QEMU window with its own graphical console
  and a PS/2 keyboard (like a real PC). Some things (a blinking cursor, the mouse
  wheel) only make sense here.

Where it matters below, the guide says which one to use.


2. Building and starting Obsidia
================================

Build it
--------

.. code-block:: console

   $ zig build

This produces the kernel. A normal build is **quiet**: when it boots you will see
almost nothing until the shell prompt appears — that is intentional.

If you want to *see everything the kernel is doing* during boot (every subsystem
announcing itself, the self-tests, etc.), build with the diagnostic switch:

.. code-block:: console

   $ zig build -Ddebug-log=true

The two builds behave identically; the only difference is how chatty the boot is.
The automated test suite always uses the ``-Ddebug-log=true`` build because it checks
for those messages.

Start it the easy way
---------------------

.. code-block:: console

   $ ./run.sh

This builds, makes a small practice disk, and boots Obsidia in QEMU with the shell
connected to your terminal. When you see::

   obsidia:/>

the system is up and waiting for commands. To quit QEMU, press ``Ctrl-a`` then ``x``.

.. tip::

   If a normal ``./run.sh`` boot is too quiet and you want to watch the startup,
   build first with ``zig build -Ddebug-log=true`` and then run.


3. Running the automated test suite
===================================

Before testing by hand, it is worth running the full automated suite — it is the
authoritative check and tells you in one number whether the system is healthy:

.. code-block:: console

   $ ./tests/run.sh

It boots Obsidia many times (old "BIOS" firmware and modern "UEFI" firmware, with
and without disks and devices), exercises every subsystem, and ends with a line like::

   ================ RESULTS: 194 passed, 0 failed ================

**Pass criterion:** the "failed" count is ``0``. If a single run shows one or two
failures in timing-sensitive checks, re-run it — the emulator is much slower than a
real CPU and occasionally a step times out. A repeatable failure is a real problem.


4. Manual feature checklist
===========================

Boot once with ``./run.sh`` and work through these. Each item lists what to type and
what you should see. Treat anything that does **not** match as a bug worth reporting.

4.1 The shell and its commands
------------------------------

Type ``help`` and press Enter. You should see a list of commands. Then try each:

============  ===================================================================
Command       What you should see
============  ===================================================================
``help``      The list of available commands.
``echo hi``   The text ``hi`` printed back.
``mem``       A line like ``memory: 130345/131039 frames free (509/511 MiB)``.
``uptime``    How long the system has been running, plus the boot and current time.
``date``      The current date and time, like ``2026-06-18 10:55:03 UTC``.
``ps``        A small table of running tasks (an "idle" task and the "shell").
``clear``     The screen clears.
``history``   The commands you have typed so far (also reachable with the Up arrow).
============  ===================================================================

Also confirm **line editing** works: type some text, then use Left/Right arrows to
move, Backspace/Delete to erase, and the Up/Down arrows to recall previous commands.

4.2 Files and folders
----------------------

Obsidia can read a FAT32 disk (the kind a USB stick uses). With the practice disk
from ``./run.sh``:

- ``ls`` — list the files and folders in the current location.
- ``cd <folder>`` then ``ls`` — move into a folder and list it; ``cd ..`` goes back.
- ``cat <file>`` — print a text file's contents.

Expected: ``ls`` shows entries with sizes (folders marked ``<DIR>``), ``cd`` changes
what ``ls`` shows, and ``cat`` prints readable text. Asking for a file that does not
exist prints a clear "no such file" message rather than crashing.

4.3 The text editor
-------------------

.. important::

   The editor's **Ctrl** shortcuts and the blinking cursor are best checked on the
   **emulated screen** (the QEMU graphical window) with the PS/2 keyboard, because
   that is where most people will use them.

Open a file::

   obsidia:/> edit /notes.txt

You should see an editor screen with a header line: ``edit: /notes.txt   [Ctrl-S save
Ctrl-X exit]``. Check each behavior:

- **Typing** inserts characters where the cursor is.
- **The cursor** (a blinking marker) sits where your next character will go and moves
  as you type and as you press the arrow keys — it should *not* stay stuck in the
  top-left corner.
- **Arrow keys** move the cursor up/down/left/right through the text.
- **Backspace** deletes the character before the cursor.
- **Ctrl-S** saves the file. The header briefly shows ``-- saved --``.
- **Ctrl-X** exits back to the shell prompt. Pressing Ctrl-X must *exit* — it must
  **not** type a literal ``x`` into the file.

After saving and exiting, ``cat /notes.txt`` should print what you typed.

4.4 Scrolling back through the screen
--------------------------------------

On the **emulated screen**, after enough output has scrolled by, press **Page Up** to
look back at earlier lines and **Page Down** to return to the bottom. The view should
move and then snap back to the live prompt. (The mouse wheel does the same thing.)

4.5 Playing sound
-----------------

Obsidia can play audio through an emulated sound card. Start QEMU with sound enabled:

.. code-block:: console

   $ qemu-system-x86_64 -M q35 -m 512M -cdrom obsidia.iso -enable-kvm \
       -audiodev pipewire,id=snd0 -device AC97,audiodev=snd0

A short tone plays once at startup. At the shell, ``play <file>`` plays a ``.wav`` or
raw ``.pcm`` audio file from the disk. Expected: you hear the audio, and ``play``
reports how many bytes it streamed. With no sound device, ``play`` says so politely
instead of failing.

4.6 Logging in and installing
-----------------------------

Obsidia can require a password and can install itself onto a disk. See the
"Installing Obsidia" section of ``README.md`` for the full walkthrough; the quick
check is:

- ``./install.sh`` — boots an installer; type ``install``, then ``shutdown``.
- ``./install.sh boot`` — boots the disk you just made; you should be asked to log in,
  and the username/password you set should be accepted (a wrong password is rejected).

4.7 Date and time
-----------------

``date`` and ``uptime`` should both show a sensible current time (matching your real
clock, in UTC). This reads the PC's battery-backed clock.

4.8 Turning the machine off
---------------------------

- ``shutdown`` — powers the emulated machine off (the QEMU window closes / process
  ends).
- ``restart`` — reboots; you should see Obsidia start up again from the beginning.

4.9 Seeing a crash report (on purpose)
--------------------------------------

Obsidia turns a crash into a readable report instead of a silent freeze. The ``crash``
command triggers one deliberately::

   obsidia:/> crash

You should see a "CPU EXCEPTION" report listing what went wrong and the processor's
state. This proves the safety-net works. (This report is always shown, even in a quiet
build, because a real crash must never be hidden.)


5. Quiet vs. verbose boot
=========================

This is worth checking directly, because it is easy to see:

1. Build the normal (quiet) way and boot::

      $ zig build && ./run.sh

   The screen should go from the bootloader straight to the ``obsidia:/>`` prompt with
   essentially no chatter in between.

2. Build verbose and boot::

      $ zig build -Ddebug-log=true && ./run.sh

   Now the boot prints a running commentary — each subsystem ("[GDT]", "[PMM]",
   "[ACPI]", and so on) reporting that it started, plus the self-tests.

In **both** cases the shell and everything you type still work the same way; only the
startup noise differs.


6. What "good" looks like (summary)
===================================

- ``./tests/run.sh`` ends with ``... 0 failed``.
- A normal boot reaches ``obsidia:/>`` quietly; a ``-Ddebug-log=true`` boot is chatty.
- Every command in section 4.1 does what the table says.
- ``ls`` / ``cd`` / ``cat`` read the disk; ``edit`` types, moves a visible cursor,
  saves with Ctrl-S, and exits with Ctrl-X (no stray ``x``).
- Sound plays; login accepts the right password and rejects a wrong one;
  ``shutdown`` / ``restart`` work; ``crash`` shows a readable report.

If anything deviates, note exactly what you typed and what you saw, and include the
serial log — that is the fastest path to a fix.
