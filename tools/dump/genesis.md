# Genesis (Mega Drive) dumps from a savestate

`genesis-savestate.rkt` pulls the VDP's memory and registers out of an emulator savestate and
writes them as the files a Genesis game program loads:

    racket tools/dump/genesis-savestate.rkt <savestate> <out-dir>

It prints the format it read and a summary of the screen's setup (H40 or H32, the planes', window's,
sprites' and hscroll table's addresses, the plane size), so a dump can be sanity-checked. For a
Genesis Plus GX Mega-CD (Sega CD) state it also prints "Mega-CD" and the word RAM mode (1M or 2M),
and writes word RAM and the graphics ASIC's state as well. It exits non-zero, before writing
anything, when the savestate is one it can't read, truncated, or not in Mega Drive mode (register 1
bit 2).

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

For a Mega-CD state (Genesis Plus GX only), also:

| File          | Size         | Contents                                                                                    |
|---------------|--------------|---------------------------------------------------------------------------------------------|
| `wordram.bin` | 262144 bytes | word RAM in 2M order (byte `n` is at sub-CPU address `$080000 + n`), whichever mode it was in |
| `asic.bin`    | 56 bytes     | the graphics ASIC's registers and Genesis Plus GX's render state, below                    |

In 1M mode the two 128 KB banks are interleaved into 2M order as the hardware maps them: 2M word
`2i` is bank 0's word `i` and `2i+1` is bank 1's. The ASIC only renders in 2M mode, so a 1M dump
is for checking, not for rendering ASIC output.

`asic.bin`, all big-endian:

| Offset | Size   | Contents                                                                                       |
|--------|--------|------------------------------------------------------------------------------------------------|
| `0x00` | 2      | `$FF8002`: memory mode (bits 3-4 priority mode off/underwrite/overwrite, bit 2 1M mode)          |
| `0x02` | 16     | `$FF8058` to `$FF8066`, one word each: stamp data size (bit 15 GRON, busy), stamp map base, image buffer V cell size, start, offset, H dot size, V dot size, trace vector base |
| `0x12` | 2      | zero                                                                                           |
| `0x14` | 9 x 4  | Genesis Plus GX's render state (`gfx_context_save`, `cd_hw/gfx.c`), one 32-bit word each: `cycles` (sub-CPU cycle of the next line's render), `cyclesPerLine`, `dotMask`, `stampShift`, `mapShift`, `bufferOffset`, `bufferStart` (in dots from word RAM's start), the trace vector pointer and the stamp map pointer (byte offsets into 2M word RAM) |

A render in progress (GRON set) has drawn only part of the image buffer: the render state says how
far it got.

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
- **Mega-CD:** Genesis Plus GX 1.7.6 only, built since Sep 2021, on a 64-bit host (RetroArch or
  OpenEmu). The state embeds the BIOS's program RAM, so never commit one; commit the dumped files.

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

**Genesis Plus GX, Mega-CD** (`system_hw == SYSTEM_MCD`): the same prefix, so the VDP is where it is
above; after the VDP come the sound, 68K and Z80 contexts, the marker `"SCD!"`, then
`scd_context_save()` (`cd_hw/scd.c`): `scd.regs` (`0x200`, 256 little-endian words, `$FF80xx` at
word `xx/2`), the timers, the gfx context (from the marker at `+0x212`, 28 bytes), CDC, CDD, PCM,
PRG-RAM (`0x80000`) and word RAM, as host-order words: one 256 KB block in 2M mode, or bank 0 then
bank 1 (128 KB each) in 1M mode. Mega Drive states have no marker.

The sound and Z80 contexts are host structs saved whole, and the Z80's and MAME YM2612's hold
pointers, so the marker's offset depends on the host and the build. On 64-bit hosts (worked out
from the sources' struct sizes, and checked against the Mega Drive fixture, whose Z80 context ends
where the marker would be) it is:

| Marker    | Build                                                                                     |
|-----------|-------------------------------------------------------------------------------------------|
| `0x234C6` | MAME YM2612 in a build with the Nuked YM3438 core (`HAVE_YM3438_CORE`): RetroArch's default |
| `0x234C5` | MAME YM2612 in a build without it, which has no `config.ym3438` byte: OpenEmu               |
| `0x22BEE` | the Nuked YM3438 (RetroArch's `nuked` FM option)                                          |

A marker anywhere else (a 32-bit host, another build) is refused rather than guessed at.

Only `GENPLUS-GX 1.7.6` Mega-CD states are read: 1.7.5 ones predate e87891f (Sep 2021), which
grew the saved CDD context, and are refused.

What follows the gfx context changed twice without a new version string, as GPGX reworked the CDC
(fcb6620, Nov 2023, to e8a6086, Feb 2024), so word RAM is at one of three offsets from the marker.
All three save the CDC's 24 register bytes, then:

| Builds                                         | Then                                                    | DMA target | Word RAM    |
|------------------------------------------------|---------------------------------------------------------|------------|-------------|
| since e8a6086 (Feb 2024): current RetroArch    | `cycles[2]` (8), CDC RAM                                | 0 to 7     | `+0x94C28`  |
| fcb6620 to e8a6086 (Nov 2023 to Feb 2024)      | `cycles` (4), DMA callback pointer (8), CDC RAM         | 0 to 7     | `+0x94C2C`  |
| e87891f to fcb6620 (Sep 2021 to Nov 2023): OpenEmu (a2931d1) | the whole `cdc_t`: `cycles` (4), padding (4), pointer (8), CDC RAM | 0 to 5 | `+0x94C30` |

The CDC RAM is `0x4000 + 2352` bytes; after it come the DMA target (1 byte), CDD (33 bytes,
its track index 8 bytes in), PCM (65672) and PRG-RAM (`0x80000`). The tool tells the layouts
apart by facts each one guarantees for its own states: the DMA target is in range; where saved,
the callback pointer is a user-space address that is non-null exactly when a DMA is running (target
1 to 5; 6 and 7 are a halted DMA); the padding is zero; and the CDD track index is at most 100. A
real state always matches its own layout, so a wrong layout can only add a second match: a state
matching none or more than one is refused, never misread. That can refuse a genuine state whose
CDC counters and the CDC RAM bytes the other layouts read are all zero (no CD data read yet).

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

No real Mega-CD state can be committed (each embeds BIOS-derived PRG-RAM), so the Mega-CD tests
build synthetic ones: the Genesis Plus GX fixture's prefix up to the marker, then `"SCD!"` and a CD
part assembled field by field from GPGX's saved sizes for each known build (so they check the
tool's offsets rather than restate them), with patterns in the registers, the render state, the
CDC RAM and word RAM, in both word RAM modes. They check every output file, and that a 1.7.5
state, an unknown marker offset, an ambiguous or garbled layout and a truncated state fail.
