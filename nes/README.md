# NES

The NES's picture processing unit, `nes/nes.zgal`, is a compute shader that approximates how the
NES PPU renders a scanline. It renders real NES memory dumps from an emulator: the structs match a
real NES's memory (references: [nesdev](https://www.nesdev.org/)), so the dumps load as they are.

One workgroup renders a scanline, each invocation a pixel of it, into a 256 x 240 picture. The
workgroup first picks the scanline's sprites from OAM in shared memory, then each invocation
combines the background and those sprites.

The registers the PPU reads (scrolling, which tile sets, the first name table, 8 x 16 sprites) are
push constants. To support changing registers partway through a frame (as is done in the title
screen of Super Mario Bros 3, which switches name tables at scanline 192), the scanlines before and
after a change are rendered by separate dispatches, each with its own registers.

Animations (palette cycling, metasprites, animated tiles, OAM cycling) are each game's state,
advanced every game frame and written into the PPU's memory by the game's `Prepare` material before
the frame renders (as during V-blank).

## Games

Listed in `nes/games.mk`:

- `smb3`: Super Mario Bros. 3's title screen. A background colour cycles, a turtle walks, and the
  name tables switch at scanline 192.
- `batman`: Batman's title screen. Its animated tiles come from eight more dumps in turn, and OAM
  rotates a sprite every frame, so sprites beyond the 8 a scanline shows take turns (they flicker).

Each game's dumps are in `<game>/assets`: `ppu_dump.bin` (the PPU's 16 KB address space) and
`oam_dump.bin` (256 bytes of OAM), and Batman's animated tiles in `batman/assets/tileframes/0.bin`
to `7.bin`.

## Supported

- The background: four name tables with their attribute tables, from either tile set.
- Sprites of 8 x 8 or 8 x 16 pixels, with flips, palettes and priority behind the background,
  evaluated a scanline late as on a real NES.
- The NES's 64 colours (an index's top two bits are ignored).

## Not supported

- PPUMASK's greyscale, colour emphasis and hiding the leftmost 8 pixels.
- Sprite 0 hits and sprite overflow (they affect only the CPU's view).
- Name table mirroring: the dump's four name tables are used as they are.
- Scrolling within a name table: `xScroll` and `yScroll` only pick the name table, and the tile,
  attribute and pixel lookups are unscrolled. Untested, as both games scroll 0.
- The 8 sprites a scanline shows: one sprite is kept per OAM index class (index mod 8), the highest
  index of each, so a line with sprites 0 and 8 draws only 8, and priority goes by class, not by
  index.

## Known differences from hardware

- Colours: `pictureColor` (common/ppu.zgal) takes linear colours and sRGB-encodes them, but
  `nesColors` are already sRGB, so they're encoded twice and the pictures (and the approved frames)
  are brighter and more washed out than the emulator's. Kept as it is by decision (2026-10-25), so
  the frames stay approved; other systems must `srgbDecode` their palette colours first.
