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
  (`RASTATE`) is unwrapped. OpenEmu's Genesis Plus GX core should work too, but hasn't been
  tried; use it for frame 0 only (below).
- **Mega-CD:** Genesis Plus GX 1.7.6 only, built since Sep 2021, on a 64-bit host (RetroArch or
  OpenEmu). The state embeds the BIOS's program RAM, so never commit one; commit the dumped files.

## Frames after the state (frame N >= 1)

**Take states for frame N >= 1 in RetroArch with its Genesis Plus GX core** (savestate
compression off). OpenEmu is for frame 0 captures only: its states don't run correctly in the
core built here (see "Which states run" below).

A savestate carries no picture, so a dump straight from it (frame 0) takes its reference from the
emulator's own screenshot, which must be the native, unfiltered frame. For frame N >= 1,
`gpgx-frame/gpgx-dump.sh` runs the Genesis Plus GX libretro core headless from the state and
writes both the dump and its reference from that same moment:

    [PPU_DUMP_BIOS=<Sega CD BIOS>] tools/dump/gpgx-frame/gpgx-dump.sh \
      <rom or .cue> <state> <frame> <out-dir> [state-out]

It runs `<frame>` frames from the state (1 is the first frame after the state loads, as for
Mesen's dumps), saves the core's state after the last one and extracts it into `<out-dir>` with
`genesis-savestate.rkt` (the files above), beside them:

| File             | Contents                                                                                 |
|------------------|------------------------------------------------------------------------------------------|
| `screenshot.png` | frame N as the core drew it: native size (320 x 224 in H40, 256 x 224 in H32), unfiltered, 8-bit RGB |
| `info.txt`       | `console=Genesis` or `Sega CD`, `frame=N`, `width=`, `height=`, one per line              |

`<rom or .cue>` must be the exact game the state was saved from: the core doesn't check, and
runs another game's (or another revision's) state into garbage without an error.

The state after the frame goes to `[state-out]` if given (never commit it, as with any state).
The state after frame N is frame N's memory: the core's `retro_run` runs the vertical blank first
and the active lines last, so a state saved between two runs holds the VDP as the frame just
drawn used it, and running one frame from the state after frame 1 gives frame 2 exactly.

Colours: the core draws in RGB565 (a CRAM channel `c`, 0 to 7, is the 4-bit level `2c` in 5 or
6 bits), and the PNG widens each channel to 8 bits by repeating its top bits, as RetroArch's
screenshots do. Shadow and highlight levels come through the same way.

The script exits with 2, before running the core or writing anything, for frame 0 (also written
`00`: use the extractor and the emulator's screenshot), a frame that isn't a whole number from 1
to 1000000 written without leading zeros, a missing file, a game path over 255 bytes (the core
truncates longer ones), a state the extractor can't read or that isn't a Genesis Plus GX state
(GST states from BlastEm or Gens can't be run on), a Mega-CD state with a cartridge or a Mega Drive
state with a disc, and the Sega CD cases below. It exits with 1 if the core fails.

`gpgx-frame/build.sh` builds the core and the frontend into `build/gpgx-frame` on first use (a few
seconds; git, make, a C compiler and zlib's headers, `zlib1g-dev` on Ubuntu) and reuses them
afterwards; dumps run at the same time take turns building. The core is libretro/Genesis-Plus-GX at
the commit `build.sh` pins: fetched by its hash, which pins the whole source tree (there's no
release binary to pin by checksum, as Mesen's is). To bump it, change `GPGX_COMMIT`, rerun
`gpgx-frame/test/check.sh`, and check that the savestate layouts above still hold. Genesis Plus GX
is GPL and non-commercial: the frontend (`gpgx-frame.c`) builds and calls the core from its own
repository, and none of its code is copied into this one. The frontend gives the core its default
options, no input and no audio.

**Which states run:** the core only loads states of its own layout. Builds differ by a byte when
one was built with the Nuked YM3438 sound core (as libretro's, and so RetroArch's, always is) and
the other without (OpenEmu's): such a state loads, but everything after the VDP (the sound chips,
the Z80, the 68K and, for a Mega-CD, the CD part) is misread, so the frames run from it can go
wrong without an error. For the Mega-CD the frontend detects that build and refuses its states;
for the Mega Drive the two can't be told apart, hence RetroArch for frame N >= 1. Frame 0 dumps
from any build are fine. A core matching OpenEmu's build is a possible follow-up, only if frame
N >= 1 captures from OpenEmu turn out to be needed.

**Sega CD:** give the `.cue` (its tracks beside it, under the names it gives) and set
`PPU_DUMP_BIOS` to the 128 KB BIOS for the disc's region; it's copied into a temporary system
folder as `bios_CD_U.bin`, `bios_CD_E.bin` and `bios_CD_J.bin`, so the core finds it whichever
region it detects. The script refuses a `.cue` without a BIOS, naming a missing track or one whose
path (the cue's folder plus its name) is over 255 bytes, a BIOS that isn't 131072 bytes, a BIOS
for a cartridge, and a Mega-CD state from a build before Feb 2024 (the extractor's layout line). This path isn't tested yet: CI has no BIOS or disc, so
it's checked by hand with a real BIOS, disc and state (run it for frames 1 and 2, then check that
the screenshots match the game and that the state after frame 1, run one frame, gives frame 2).

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

To remake the ROM: `racket tools/dump/test/genesis-test-rom.rkt test.bin`. Its animated variant
(`--animated`), for gpgx-frame's check, writes a new colour to CRAM entry 1 at the start of every
frame and is otherwise the same, so the fixtures run on into it.

No real Mega-CD state can be committed (each embeds BIOS-derived PRG-RAM), so the Mega-CD tests
build synthetic ones (`test/genesis-megacd-state.rkt`): the Genesis Plus GX fixture's prefix up to
the marker, then `"SCD!"` and a CD part assembled field by field from GPGX's saved sizes for each
known build (so they check the tool's offsets rather than restate them), with patterns in the
registers, the render state, the CDC RAM and word RAM, in both word RAM modes. They check every
output file, and that a 1.7.5 state, an unknown marker offset, an ambiguous or garbled layout and a
truncated state fail.

`gpgx-frame/gpgx-frame.c` is a headless libretro frontend for the Genesis Plus GX core: it loads a
game and a state, runs N frames, and writes the last frame as a PNG and the state after it.
`gpgx-frame/build.sh` builds the core (libretro/Genesis-Plus-GX, fetched by the commit it pins) and
the frontend into `build/gpgx-frame`; the core is GPL and non-commercial, so it's built from its
own repository and called, never copied in. `gpgx-frame/test/check.sh [work-dir]` (CI runs it as
its own step, after `make test-tools`; a few seconds after the core's build) builds them and checks
them on the Genesis Plus GX fixture: frames 1 and 2 are native 320 x 224 pictures in the fixture's
CRAM colours (`check.py` decodes the PNG itself), H32 (register 12 patched) gives 256 x 224, the
states after them extract to the fixture's memory (the ROM only loops), and on the animated ROM
each of frames 1 to 3 shows only its own state's CRAM and differs from the others, so a picture
paired with the wrong frame's state fails; one frame from the state after frame 1 gives frame 2's
picture and memory (comparing the state up to the sound context, whose host pointers change from
run to run), RetroArch's container works, the frontend refuses a bad frame count, a GST state and
an OpenEmu-built Mega-CD state, and `gpgx-dump.sh` writes the dump, `screenshot.png`, `info.txt`
and the state (also on the animated ROM), and refuses the bad inputs above with 2 before writing
anything (the Sega CD ones with a made-up BIOS and disc, and a synthetic Mega-CD state, before the
core runs).
