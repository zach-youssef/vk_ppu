# Dump tools

These tools take the memory dumps and reference screenshots that the tests render from. Each one
dumps a single frame: the video memory, the registers that the frame's lines were drawn with, and
the emulator's own picture of that frame.

- SNES, PC Engine and PC Engine CD: `mesen-dump.lua`, a [Mesen 2](https://www.mesen.ca) script
  (described below).
- Genesis and Sega CD: `genesis-savestate.rkt` for the moment a savestate holds, and
  `gpgx-frame/gpgx-dump.sh`, which runs the Genesis Plus GX libretro core headless for frames
  after it; see [genesis.md](genesis.md).

## Games, BIOS files and licensing

ROMs, disc images, BIOS files and savestates are never committed, and never uploaded to CI (as
inputs, caches or artifacts): they stay in a folder of their own outside the repo. CI tests the
tools on test ROMs written for them (`test/`) and on made-up files. What a game's scene commits
is what the dump tools write from them: the frame's video memory, its registers and the
emulator's screenshot. Emulator cores are built or downloaded from their own projects, pinned
(Mesen by its release's checksum, Genesis Plus GX by its commit), and only run, never copied in.

Keep that folder in one subfolder per system, with BIOS files apart:

| Folder | Holds |
| --- | --- |
| `snes/`, `pce/`, `genesis/` | cartridge ROMs, one file per game |
| `pcecd/<game>/`, `segacd/<game>/` | one disc per folder: its `.cue` and every file the cue names, beside it under the names it gives |
| `bios/` | the PC Engine System Card 3.0 (256 KB, see below) and the Sega CD BIOS for each disc region |

## Mesen 2 (SNES, PC Engine and PC Engine CD)

`mesen-dump.lua` works out the console from the loaded ROM. It needs Mesen 2.1 or later; it was
written against 2.1.1. It must be allowed to write files: in the script window, turn on
Script → Settings → "Allow access to I/O and OS functions", or pass
`--debug.scriptWindow.allowIoOsAccess=true` on the command line.

### Headless

```sh
MESEN=/path/to/Mesen [PPU_DUMP_BIOS=<system card>] tools/dump/mesen-dump.sh \
  <rom or .cue> <out-dir> [frame] [savestate.mss]
```

On macOS `MESEN` is `Mesen.app/Contents/MacOS/Mesen`; on Linux it is the `Mesen` file from the
Linux x64 release, which also needs SDL2 (`libsdl2-2.0-0` on Ubuntu). The wrapper runs Mesen with
`--testrunner`, which emulates as fast as it can without a window (and without a display on
Linux). It gives Mesen a home folder of its own, with an empty `settings.json` (Mesen's defaults),
so your Mesen settings neither change the dump nor get changed by it. Without that file Mesen
opens its setup wizard instead of running. What that covers:

- Linux: Mesen's folder is `$XDG_CONFIG_HOME/Mesen2`, and the wrapper points `XDG_CONFIG_HOME`
  into its own `HOME`. CI runs this case.
- macOS: Mesen's folder is `~/Library/Application Support/Mesen2`, where macOS takes `~` from
  `CFFIXED_USER_HOME`, not `HOME`, so the wrapper sets both. This case is untested: dumps on macOS
  so far used a portable Mesen.
- A portable Mesen (one with a `settings.json` next to the executable, on either system) uses its
  own folder instead, so its settings do apply to the dump; the test runner doesn't save them.

The wrapper then checks the exit code and the file sizes, and prints any warnings from
`info.txt`.

- `frame` is which frame to dump, counted from 1 at the first frame that starts after the script
  (or the savestate) loads. It defaults to 1.
- `savestate.mss` is loaded first. Save one in Mesen at the screen you want (File → Save State
  saves under Mesen's `SaveStates` folder), and the dump then starts from there.
- `PPU_DUMP_BIOS` is the System Card for a PC Engine CD game (below). It is required for a `.cue`
  and refused for anything else.

#### PC Engine CD

A PC Engine CD game is given as its `.cue`. Mesen 2.1.1 reads the files the cue names from the
cue's own folder (a name with a folder in it is taken relative to that folder), and accepts data
tracks in `MODE1/2352` or `MODE1/2048` and `AUDIO` tracks, which is how disc images are usually
kept (`.bin` tracks). The dump's `console` is `PC Engine`, and its files are the PC Engine ones.

Mesen loads the System Card from its home folder's `Firmware` folder, as
`[BIOS] Super CD-ROM System (Japan) (v3.0).pce` or `syscard3.pce`, and checks only that it is
262144 bytes. Version 3.0 runs every CD-ROM², Super CD-ROM² and Arcade CD-ROM² game; Games
Express discs need a different card, which the wrapper doesn't provide. Mesen has no setting for
the Firmware folder, and the wrapper's own home folder starts empty, so the wrapper copies
`PPU_DUMP_BIOS` there as `Firmware/syscard3.pce` (in both of the home folders below). Before
starting Mesen it exits with 2 and says why if:

- the `.cue` has no `PPU_DUMP_BIOS`, or `PPU_DUMP_BIOS` isn't a 262144-byte file (without a card,
  Mesen fails to load the game, and its window would ask for one with a dialog);
- the `.cue` names no file, or a file that isn't in its folder;
- `PPU_DUMP_BIOS` is set for a cartridge, which doesn't use it.

A portable Mesen (below) loads the card from its own `Firmware` folder instead: the wrapper says
so, and the card must then be in that folder. `PPU_DUMP_BIOS` is still required for a `.cue`
then, on purpose: every CD dump names its card explicitly, whichever Mesen runs it.

Under the hood, the wrapper runs:

```sh
HOME=<dir> CFFIXED_USER_HOME=<dir> XDG_CONFIG_HOME=<dir>/.config \
  DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1 \
  PPU_DUMP_OUT=<out-dir> PPU_DUMP_FRAME=<frame> PPU_DUMP_STATE=<state> \
  Mesen --testrunner --debug.scriptWindow.allowIoOsAccess=true \
  --debug.scriptWindow.scriptTimeout=5 \
  --snes.disableFrameSkipping=true --pcEngine.disableFrameSkipping=true \
  tools/dump/mesen-dump.lua <rom> --timeout=<seconds>
```

`<dir>/.config/Mesen2/settings.json` and `<dir>/Library/Application Support/Mesen2/settings.json`
hold `{}`, and for a `.cue` each of those folders gets `Firmware/syscard3.pce`, a copy of
`PPU_DUMP_BIOS`. `DOTNET_SYSTEM_GLOBALIZATION_INVARIANT` stops
.NET from loading ICU: on Linux that brings in the system's libstdc++ ahead of the copy built into
Mesen's core, which then aborts with `std::bad_cast` as it loads (Mesen 2.1.1 on Ubuntu 24.04).

With `PPU_DUMP_OUT` set, the script stops Mesen when it is done. Mesen exits with 0 on success
and 1 when the dump fails, and the reason goes to stderr. A timeout, or a script that doesn't
load, gives -1 (255).

### From the script window (untested)

This mode hasn't been tried yet. Until it has, dump headless: save a state at the screen you
want in Mesen, then pass it to the wrapper as `savestate.mss`.

Load the game and get to the screen you want, then open Debug → Script Window, open
`mesen-dump.lua` and run it. It dumps the next frame that starts into the script's data folder,
which is `LuaScriptData/mesen-dump` in Mesen's home folder. It reports the folder in the script
log and on screen, and leaves the game running. `PPU_DUMP_FRAME` and `PPU_DUMP_STATE` also apply
here when they are set in Mesen's environment, but normally you'd leave both unset.

The headless wrapper avoids some hazards that you have to avoid yourself here:

- Don't fast-forward or turn on run-ahead. Mesen then skips rendering some frames, and the
  screenshot can be an older frame than the registers and memory.
- Don't set breakpoints. They stop the script's line-by-line stepping, and the dump fails with
  "stepping lost its place".
- Raise Script → Settings → script timeout (1 second by default) if the dump stops with a
  timeout: the end of the dumped frame reads and compares all the memory and encodes the PNG in
  Lua.

### Output files

Every multi-byte value is little-endian. Memory is dumped as it was at the start of the frame's
first displayed line (on SNES, the first line out of forced blank), so it includes whatever the
game uploads during vertical blank or forced blank. If it changes later in the displayed lines
(up to the start of vertical blank, so the game's uploads for the next frame don't count),
`info.txt` gets a warning. On SNES that includes uploads in forced blank after the last displayed
line: those lines are already drawn, so the dump is right, but the warning still appears. If no
line is displayed, memory is dumped as of the frame's end, also
with a warning. The register rows show the state each line was drawn with.

Palette memory is the exception to the warning: its writes from that first displayed line to the
end of the display are logged in a palette writes file (`cgram-writes.bin` or
`palette-writes.bin`), so a renderer can rebuild the palette at any point of the frame, as for an
HDMA gradient or a raster palette swap. The palette file itself keeps the frame-start state. At
the end of the display the script checks that the frame-start palette plus the logged writes is
the palette in memory, and warns if it isn't (a write the log missed).

The palette writes file is binary: one 8-byte row per colour write, four `uint16` fields, in the
order the writes happened:

| # | Field | Value |
| --- | --- | --- |
| 0 | line | the scanline the write happened on, in Mesen's numbering (the register rows' numbering below: SNES row *i* is scanline *i* + 1, PC Engine row *i* is scanline *i* + 14) |
| 1 | dot | the horizontal position of the write, per console below |
| 2 | index | the colour written (0-255 on SNES, 0-511 on PC Engine) |
| 3 | value | the colour's whole value after the write, in the palette file's format |

It is binary for the same reason as `registers.bin`: a renderer loads it as a buffer as is (an
array of `uvec2`, or of four `uint16`), with no parsing, and replays it per line. Its length is
`paletteWrites` × 8 bytes; a frame without palette writes gives an empty file.

`info.txt` has one `key=value` per line: `console` (`SNES` or `PC Engine`), `frame` (Mesen's
frame counter), `width` and `height` (the screenshot's size), `rows` and `rowBytes` (the size of
`registers.bin`), `paletteWrites` (the number of rows in the palette writes file), and one
`warning=` line per warning.

#### SNES

| File | Size | Layout |
| --- | --- | --- |
| `vram.bin` | 65536 | VRAM, 32768 words in address order, each low byte first |
| `cgram.bin` | 512 | 256 colours, each a BGR555 word (`0bbbbbgggggrrrrr`) |
| `oam.bin` | 544 | the 512-byte low table (128 sprites × x, y, tile, attributes), then the 32-byte high table (2 bits per sprite: bit 0 x bit 8, bit 1 size) |
| `cgram-writes.bin` | 8 per row | the CGRAM writes during the display (see above) |
| `registers.bin` | 90 per row | one row per line: 224 rows for scanlines 1 to 224, or 239 rows (1 to 239) when SETINI's overscan bit is set at the frame's start |
| `screenshot.png` | | 256 × 224 (or 239) RGB; row *i* is register row *i* |

Each register row is 45 `uint16` fields, in this order. Most are the byte the game wrote to the
register, rebuilt from Mesen's decoded state. A field for a register that is written twice (the
scroll and Mode 7 registers) holds the value the PPU uses.

| # | Field | Value |
| --- | --- | --- |
| 0 | INIDISP | bit 7 forced blank, bits 0-3 brightness |
| 1 | OBSEL | register byte (size, name select, name base) |
| 2 | OAMADD | OAM word address (bits 0-8), bit 15 priority rotation |
| 3 | BGMODE | register byte |
| 4 | MOSAIC | register byte (bits 4-7 size − 1, bits 0-3 enabled layers) |
| 5-8 | BG1SC-BG4SC | register bytes |
| 9-10 | BG12NBA, BG34NBA | register bytes |
| 11-18 | BG1HOFS, BG1VOFS, … BG4HOFS, BG4VOFS | the 10-bit scroll values |
| 19 | M7SEL | register byte |
| 20-23 | M7A-M7D | the 16-bit matrix values |
| 24-25 | M7X, M7Y | the centre values, all 16 bits as written (the PPU uses the low 13 as a signed value) |
| 26-27 | M7HOFS, M7VOFS | the Mode 7 scroll values, the low 13 bits as written (bits 13-15 are 0) |
| 28-30 | W12SEL, W34SEL, WOBJSEL | register bytes |
| 31-34 | WH0-WH3 | window 1 left, right, window 2 left, right |
| 35-36 | WBGLOG, WOBJLOG | register bytes, from the last write (see the gaps) |
| 37-40 | TM, TS, TMW, TSW | register bytes |
| 41 | CGWSEL | register byte; bits 4-7 from the last write (see the gaps) |
| 42 | CGADSUB | register byte |
| 43 | COLDATA | the fixed colour as a BGR555 word, not the register's write format |
| 44 | SETINI | register byte |

Each row is sampled at dot 23 of its line. Mesen draws a line's first pixel there, so the row
holds every write that reaches the start of the line. A write later in the line, such as an IRQ
handler's, shows from the next row on, even though Mesen's picture changes partway along the line.
HDMA runs in the H-blank before a line, so it lands on the right row.

In `cgram-writes.bin`, a row is logged when the game (CPU, DMA or HDMA) writes a colour's high
byte to $2122, which stores both bytes; the script watches $2122 because Mesen 2.1.1 doesn't call
scripts back on writes to CGRAM itself. `dot` is the PPU's H counter (0-339, as $213C reads it). Mesen draws pixel *x*
of a line at dot *x* + 22 and looks colours up as it draws, so a write at dot *d* shows from pixel
*d* − 21 on, and a write from dot 277 on (in H-blank, where HDMA writes) from the next line on. While the screen is drawn,
Mesen writes a CPU's CGRAM write to the colour the PPU is reading at that moment, not to CGADD's,
as the hardware does. The script can only read that address as of the PPU's last catch-up, which
Mesen does when it handles the write, after the script's callback: such a row's `index` is a guess
and may be wrong, and `info.txt` warns with the number of these rows. Writes in forced blank or in
the H-blank window Mesen allows (H counter below 22 or from 274 on), which is where HDMA and
well-behaved games write, have the right index.

#### PC Engine

| File | Size | Layout |
| --- | --- | --- |
| `vram.bin` | 65536 | VRAM, 32768 words in address order, each low byte first |
| `palette.bin` | 1024 | the VCE's 512 colours, each a word (`0000000gggrrrbbb`); 0-255 background, 256-511 sprites |
| `sat.bin` | 512 | the VDC's sprite attribute table (64 sprites × 4 words: y, x, pattern, attributes), as last copied from VRAM by the SATB DMA |
| `palette-writes.bin` | 8 per row | the VCE palette writes during the display (see above) |
| `registers.bin` | 32 per row | 242 rows, one for each of Mesen's output lines (VDC scanlines 14 to 255) |
| `screenshot.png` | | width × 242 RGB, row *i* is register row *i* |

The screenshot's width follows the VCE's dot clock: 256 (5.37 MHz), 341 (7.16 MHz) or 512
(10.74 MHz). This is Mesen's default framing, with its 18-dot borders at 5.37 MHz trimmed from
each side. Rows outside the displayed area are in the screenshot as the border colour. Check
`FLAGS` bit 3 to tell them apart.

Each register row is 16 `uint16` fields:

| # | Field | Value |
| --- | --- | --- |
| 0 | CR | the control register (R05): bits 0-7 and 11-12 as written, except that EX (bits 4-5) = 3 reads as 2; bits 8-10 are 0 |
| 1 | RCR | raster compare register (R06) |
| 2-3 | BXR, BYR | the scroll registers as last written (R07, R08) |
| 4 | MWR | memory width register (R09) |
| 5-9 | HSR, HDR, VPR, VDW, VCR | the display registers (R0A-R0E) |
| 10-11 | SCROLL_X, SCROLL_Y | the scroll the line was drawn with: the X the VDC latched for it, and the background row it drew |
| 12 | FLAGS | bit 0 background on, bit 1 sprites on, bit 2 burst mode, bit 3 the line is displayed |
| 13 | LINE | the VDC's line counter for the line (0 = first displayed line, compared with RCR − 64) |
| 14 | MWR_LATCHED | the MWR the line was drawn with. Mesen 2.1.1 never latches bit 7 (CG mode), so it is 0 here, which is what Mesen draws with |
| 15 | VCE_CR | VCE control: bits 0-1 dot clock (0 = 5.37, 1 = 7.16, 2 = 10.74 MHz), bit 2 263 lines, bit 7 grayscale |

Each row is sampled at the end of its line. Writes the game makes during a line show in the
register fields (0-9) of that line's row. They take effect in `SCROLL_X`/`SCROLL_Y` from the
line the VDC latches them for, the same way the picture changes. On a SuperGrafx, only the first
VDC is dumped.

In `palette-writes.bin`, every byte written to the VCE's colour data ($0404 low, $0405 high) is a
row, since each one changes the colour on its own. `dot` counts pixels of the VCE's current dot
clock from the start of the line: Mesen's master clock position (0-1364) divided by the clock
divider (4, 3 or 2 for 5.37, 7.16 or 10.74 MHz). Mesen draws its line up to that pixel before the
write, so the write shows from that pixel of Mesen's full line on. The screenshot starts later in
the line (Mesen's left overscan and the border the script trims), so the write shows from
screenshot column `dot` − 48, 72 or 120 (divider 4, 3 or 2) on, assuming Mesen's left overscan
setting is 0, its default, which the wrapper uses. A write whose column is negative shows from the
line's first pixel; one whose column is at or past the screenshot's width shows from the next line
on.

The script sees these writes where games map the I/O page, logical $0000-$1FFF (MPR0 = $FF, so
the VCE is at $0400-$07FF): Mesen 2.1.1 doesn't call scripts back on writes to palette memory
itself, and doesn't map the I/O page to an address scripts can watch in every bank. A game that
writes colours through another bank gets the missed-write warning.

### Gaps and limits

- **No scanline event.** Mesen's Lua API has none. The script uses the debugger's step command
  to stop at every line of the dumped frame, then reads `emu.getState()`. That makes the frame
  slow (a fraction of a second), but no other frame is affected.
- **Per-line VRAM and sprite memory changes are lost.** VRAM and OAM (SAT) are one copy, from
  the first displayed line, so a change during the display is in the dump only as it was on that
  line, plus a warning with the number of bytes that changed. A reference mismatch on such a
  frame can come from this. Palette writes are logged instead (see the output files), with two
  limits: a SNES CPU write to CGRAM while the PPU draws gets a guessed colour index, and a PC
  Engine colour write through a bank other than MPR0 is missed; each gives a warning.
- **Enums missing from `getState()`.** SNES WBGLOG, WOBJLOG and CGWSEL bits 4-7 are stored as
  enums that `getState()` doesn't return. The script keeps the last value written to $212A,
  $212B and $2130 instead. If none was written after the script started, which is always the
  case after a savestate load, those bits are 0 and `info.txt` says so. To get them, start the
  script before the game sets them, for example from power-on with a later `frame`.
- **Not supported:** SNES high-resolution and interlaced frames (Mesen's buffer is then
  512 × 478), and a PC Engine frame that changes dot clock partway down. In both cases the dump
  fails rather than writing a picture whose rows don't match the register rows.
- The screenshot goes through Mesen's video filter, so its colours follow Mesen's video
  settings (brightness, contrast, palette and so on). The headless wrapper runs with Mesen's
  defaults. From the script window, reset the video settings first. A filter that changes the
  frame's size, such as NTSC, makes the dump fail. Mesen's overscan cropping doesn't affect it.
- Mesen fills VRAM and palette memory with random values at power-on. A game that doesn't clear
  them leaves noise in the dump's unused areas.

### Checking the script

```sh
MESEN=/path/to/Mesen tools/dump/test/check.sh [work-dir]
```

This needs [cc65](https://cc65.github.io) (`ca65`, `ld65`) and Python 3. It first runs
`test/bios-check.sh`, which needs neither Mesen nor a System Card nor a disc, so it also runs on
its own (`tools/dump/test/bios-check.sh [work-dir]`): it gives the wrapper a stand-in for Mesen,
a made-up `.cue` with its tracks and a 256 KB file of zeros, and checks each refusal above (with
Mesen never started) and that a complete `.cue` gets the card copied into both home folders.
No real CD dump runs in CI. Then it assembles the two
test ROMs in `test/` (`snes-test.s` and `pce-test.s`, written for this check and free to
redistribute), dumps frame 10 of each (and SNES frame 1), and checks the dumps against what the
ROMs write (`test/check.py`):

- Every register field, each set to a distinctive value, and the rows where they change
  (HDMA, raster and V-IRQ writes, forced blank at the top of the SNES screen).
- A frame counter that scrolls the picture and is written to VRAM and palette memory late in
  vertical blank (and on SNES, in forced blank). The screenshot, the register rows and the
  memory must all show the same frame, which catches a stale screenshot from frame skipping and
  a memory snapshot taken before the game's uploads.
- The memory-changed warning, from a VRAM write during the PC Engine frame, and its absence for
  an upload early in vertical blank, before Mesen's frame ends (the test ROM's display ends at
  scanline 251, Mesen's frame at 256).
- The palette writes files: an HDMA gradient on SNES colour 0 (one write per line, and one before
  the first displayed line that must be in `cgram.bin` instead), and a raster palette swap on the
  PC Engine, written one byte at a time, then undone through MPR1, which the log must miss and
  warn about.
- The no-displayed-line warning, from SNES frame 1, which is in forced blank throughout.
- The screenshot's edges against the rows' scroll values, horizontally and vertically.

It also checks that a failed dump makes Mesen exit with 1, both when the script loads and from
a callback during emulation.

CI runs this check on every commit, in each commit's `test` job (`.github/workflows/test.yml`),
on Ubuntu 24.04 with Mesen 2.1.1's Linux x64 release (pinned by its SHA-256) and cc65 from apt.
It needs no display. To reproduce it on Ubuntu or Debian:

```sh
sudo apt-get update
sudo apt-get install cc65 libsdl2-2.0-0
curl -LO https://github.com/SourMesen/Mesen2/releases/download/2.1.1/Mesen_2.1.1_Linux_x64.zip
echo "7a9947575cc198209f743fef83fb2b702b786ea705506bdf3f2aea01ab7c1ce9  Mesen_2.1.1_Linux_x64.zip" |
  sha256sum -c
unzip Mesen_2.1.1_Linux_x64.zip Mesen && chmod +x Mesen
MESEN=$PWD/Mesen tools/dump/test/check.sh
```

To move CI to a newer Mesen, change the URL and the SHA-256 in the workflow's install step
(GitHub's release page lists each file's SHA-256).
