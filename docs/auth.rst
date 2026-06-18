================
``src/auth.zig``
================

   Real password hashing and checking with scrypt, shared by the installer and the kernel.

What it does
============

This module turns a password into a hash and checks a typed password against a
stored hash. It never stores or compares raw passwords. It uses **scrypt**, a
memory-hard key-derivation function (KDF) designed to be slow and expensive to
brute-force, so a leaked hash is hard to crack offline.

The hash is stored as a **PHC string** — the standard one-line format like
``$scrypt$ln=14,r=8,p=1$<salt>$<hash>``. That single string carries the algorithm,
the cost settings, the random salt, and the hash together, so verification needs
no separately stored parameters.

The same code runs in two places and must agree: the host installer creates the
hash, and the kernel checks it at login. To make that possible, the module takes
a ``std.mem.Allocator`` as a parameter instead of importing the kernel heap. That
keeps it free of any kernel-only imports, so it compiles for the host too and is
covered by a normal ``zig build test`` unit test.

   **Why scrypt and not Argon2id?** Argon2id is the usual first choice, but Zig's
   standard-library Argon2 spawns threads for its parallel lanes, and threads
   have no implementation on a bare-metal (``freestanding``) target — it won't
   compile in the kernel. scrypt is single-threaded, equally memory-hard, and
   compiles cleanly.

Key components
==============

- ``PARAMS`` — the scrypt cost used for hashes we create: ``ln=14`` (N = 2^14),
  ``r=8``, ``p=1`` — the classic "interactive" cost (~16 MiB of working memory).
  Verification honors whatever cost is embedded in the stored hash, so raising
  this later does not invalidate existing credentials.
- ``MAX_HASH`` — the largest PHC string we read or write (256 bytes; a scrypt PHC
  string is ~100 bytes).
- ``verify(allocator, phc, password)`` — returns ``true`` if ``password`` matches the
  stored PHC hash. Wraps ``std.crypto.pwhash.scrypt.strVerify``; any error means
  "no match".
- ``hash(allocator, password, out)`` — writes a PHC-format scrypt hash of
  ``password`` into ``out`` and returns the slice (or ``null`` on error). Used by the
  self-test and the host ``mkpasswd`` tool.

Tests
=====

A host unit test hashes a password, then asserts the correct password verifies
and a wrong one is rejected.

Used by
=======

- `shell.rst <shell.rst>`_ — the login gate calls ``verify``.
- `tools/mkpasswd <../tools/mkpasswd.zig>`_ (host) and the kernel both use the
  same scrypt/PHC format so a credential made at install time logs in at boot.
