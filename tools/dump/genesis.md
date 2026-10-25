# Genesis (Mega Drive) dumps from a savestate

`genesis-savestate.rkt` pulls the VDP's memory and registers out of an emulator savestate and
writes them as the files a Genesis game program loads:

    racket tools/dump/genesis-savestate.rkt <savestate> <out-dir>

It prints the format it read and a summary of the screen's setup (H40 or H32, the planes', window's,
sprites' and hscroll table's addresses, the plane size), so a dump can be sanity-checked. It exits
non-zero, before writing anything, when the savestate is one it can't read, truncated, or not in
Mega Drive mode (register 1 bit 2).

## Output files

Every file is in the VDP's own order: byte `n` is the byte at VDP address `n`, and each 16-bit word
is big-endian (high byte first), as the 68K writes it. A shader reading them as `uint8` arrays
gets the same bytes on every host.

| File            | Size        | Contents                                                                                       |
|-----------------|-------------|------------------------------------------------------------------------------------------------|
| `vram.bin`      | 65536 bytes | VRAM: tiles, the plane A, B and window nametables, the sprite table, the hscroll table          |
| `cram.bin`      | 128 bytes   | CRAM: 64 colours (4 palettes of 16), each word `0000 BBB0 GGG0 RRR0`                           |
| `vsram.bin`     | 80 bytes    | VSRAM: 40 vertical scroll words (planes A and B for each of 20 two-cell columns), 11 bits used   |
| `registers.bin` | 24 bytes    | VDP registers 0 to 23, register `n` at byte `n`                                                |

Values are as the emulator stored them; unused bits aren't masked.

The H40 address bits aren't masked either (the window and sprite table bases ignore reg 3 bit 1
and reg 5 bit 0 in H40), so a consumer computing those addresses must mask them itself.

`.gitignore` ignores `*.bin`: dumps committed under a game (GE1, U1-gen) need a
`!/<game>/assets/**/*.bin` exception there, or they silently won't be committed.

## Taking a savestate

Pick a static moment (a title screen, a paused game) so the savestate and the emulator's
screenshot show the same frame.

- **BlastEm** (free, macOS, Linux, Windows), the one used for the test fixture. In `blastem.cfg`'s
  `ui` section, set `state_format gst` (its native format isn't supported). The `` ` `` key saves
  the current slot (`slot_<n>.gst` in the game's save directory) and `p` takes a screenshot.
- **Gens, Kega Fusion, Genecyst**: their `.gs0` to `.gs9` files are GST, the same format.
- **Genesis Plus GX** 1.7.5 or 1.7.6 (the version string at the start of its states, unchanged
  since 2013): the core's own state, as the libretro core's `retro_serialize` writes it. In
  RetroArch, turn off savestate compression (Settings > Saving) first; its uncompressed container
  (`RASTATE`) is unwrapped. OpenEmu's Genesis Plus GX core should work too, but hasn't been tried.

## The formats

**GST** (fixed offsets; Gens' `save.cpp` and BlastEm's `gst.c` agree): `"GST"` at 0, then the 24
VDP registers at `0xFA`, CRAM as 64 little-endian words at `0x112`, VSRAM as 40 little-endian
words at `0x192`, and VRAM at `0x12478` in VDP address order. Genecyst, Kega and BlastEm files are
`0x22478` bytes; Gens appends more, which is ignored.

**Genesis Plus GX** (`state_save()` in `core/state.c`, Mega Drive mode, little-endian host): the
16-byte version string, 68K RAM (`0x10000`), Z80 RAM (`0x2000`), `zstate` (1), `zbank` (4),
`io_reg` (`0x10`), then the VDP: its internal sprite table cache (`0x400`, at `0x12025`), VRAM
(`0x10000`, at `0x12425`) as host-order words, so each byte pair is swapped; CRAM (`0x80`, at
`0x22425`), 64 little-endian words packed to 9 bits `BBBGGGRRR`, which the tool unpacks to the
bus format above; VSRAM (`0x80`, at `0x224A5`), 64 little-endian words of which the VDP has 40;
and the registers (`0x20`, at `0x22525`), of which the first 24 are kept.

## Limitations

- **One moment, not a frame:** a savestate is the VDP at one instant. Registers or CRAM written
  partway through a frame (from a horizontal interrupt: raster splits, mid-screen palette changes)
  appear only as their value at that instant; the earlier lines' values are lost. A screen that
  needs them gets the changes by hand in its game program.
- **Scroll survives:** horizontal scroll is a table in VRAM (per screen, cell or line, from
  register 11) and vertical scroll is VSRAM (per screen or per two-cell column), so both come
  through whole for the frame.
- The VDP's internal copy of part of the sprite table isn't extracted; the sprite table in VRAM is.
  They differ only if a game rewrites the table in VRAM without the VDP seeing it, which a
  savestate taken at a static moment doesn't catch. Pending FIFO writes and a DMA in progress are
  lost too.

## Tests

`make test-tools` (or `raco test tools/dump`; CI runs it as its own step, `make test` does not) checks the extractor on
two real savestates of the same ROM, `test/genesis-test-rom.rkt`: a tiny hand-assembled ROM of our
own (freely redistributable; the ROM itself isn't committed) that writes known, byte-asymmetric
patterns to all 24 registers, VRAM, CRAM and VSRAM, then loops. The tests check every extracted
byte against the patterns, plus RetroArch's container, truncated files, other formats and a
non-Mega-Drive mode, and that the command line writes the files or exits non-zero.

- `test/genesis-test.gs0`: BlastEm (the libretro/blastem mirror at `ab74365`), GST, after 30
  frames. BlastEm has no command-line save, so a local build was patched to save a GST when its
  headless `-b <frames>` run ends.
- `test/genesis-test.gpgx-state`: Genesis Plus GX 1.7.6 (the libretro core at `60bee4c`) after 30
  frames, from a minimal libretro frontend that loads the ROM, calls `retro_run` 30 times and
  writes `retro_serialize`.

To remake the ROM: `racket tools/dump/test/genesis-test-rom.rkt test.bin`.
