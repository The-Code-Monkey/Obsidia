# Fonts (`src/fonts/`)

Bitmap font assets embedded by the framebuffer console.

## Files
- `Tamzen8x16.psf` — the Tamzen 8×16 (regular) bitmap font in PSF (PC Screen Font) format. The framebuffer console (`src/drivers/console.zig`) embeds this file directly and parses it to render text glyphs.
- `LICENSE.tamzen` — the font license.
- `README.md` — source-tree notes on the font and its provenance.

## About the font
Tamzen is a refresh by [sunaku/tamzen-font](https://github.com/sunaku/tamzen-font) of the Tamsyn font by Scott Fial. Both Tamsyn and Tamzen are freely licensed (permission to use, copy, modify, and distribute) — see [`LICENSE.tamzen`](../../src/fonts/LICENSE.tamzen).
