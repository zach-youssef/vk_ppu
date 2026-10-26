# Dump tools

These tools take the memory dumps and reference screenshots that the tests render from. Each one
dumps a single frame: the video memory, the registers that the frame's lines were drawn with, and
the emulator's own picture of that frame.

- SNES and PC Engine: `mesen-dump.lua`, a [Mesen 2](https://www.mesen.ca) script (described
  below).
- Genesis: see [genesis.md](genesis.md).

## Mesen 2 (SNES and PC Engine)

`mesen-dump.lua` works out the console from the loaded ROM. It needs Mesen 2.1 or later; it was
written against 2.1.1. It must be allowed to write files: in the script window, turn on
Script → Settings → "Allow access to I/O and OS functions", or pass
`--debug.scriptWindow.allowIoOsAccess=true` on the command line.

### Headless

```sh
MESEN=/path/to/Mesen tools/dump/mesen-dump.sh <rom> <out-dir> [frame] [savestate.mss]
```

On macOS `MESEN` is `Mesen.app/Contents/MacOS/Mesen`. The wrapper runs Mesen with `--testrunner`,
which emulates as fast as it can without a window. It gives Mesen an empty `HOME` of its own, so
your Mesen settings neither change the dump nor get changed by it. It then checks the exit code and
the file sizes, and prints any warnings from `info.txt`.

- `frame` is which frame to dump, counted from 1 at the first frame that starts after the script
  (or the savestate) loads. It defaults to 1.
- `savestate.mss` is loaded first. Save one in Mesen at the screen you want (File → Save State
  saves under Mesen's `SaveStates` folder), and the dump then starts from there.

Under the hood, the wrapper runs:

```sh
HOME=<empty dir> PPU_DUMP_OUT=<out-dir> PPU_DUMP_FRAME=<frame> PPU_DUMP_STATE=<state> \
  Mesen --testrunner --debug.scriptWindow.allowIoOsAccess=true \
  --debug.scriptWindow.scriptTimeout=5 \
  --snes.disableFrameSkipping=true --pcEngine.disableFrameSkipping=true \
  tools/dump/mesen-dump.lua <rom> --timeout=<seconds>
```

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
`info.txt` gets a warning. If no line is displayed, memory is dumped as of the frame's end, also
with a warning. The register rows show the state each line was drawn with.

`info.txt` has one `key=value` per line: `console` (`SNES` or `PC Engine`), `frame` (Mesen's
frame counter), `width` and `height` (the screenshot's size), `rows` and `rowBytes` (the size of
`registers.bin`), and one `warning=` line per warning.

#### SNES

| File | Size | Layout |
| --- | --- | --- |
| `vram.bin` | 65536 | VRAM, 32768 words in address order, each low byte first |
| `cgram.bin` | 512 | 256 colours, each a BGR555 word (`0bbbbbgggggrrrrr`) |
| `oam.bin` | 544 | the 512-byte low table (128 sprites × x, y, tile, attributes), then the 32-byte high table (2 bits per sprite: bit 0 x bit 8, bit 1 size) |
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

#### PC Engine

| File | Size | Layout |
| --- | --- | --- |
| `vram.bin` | 65536 | VRAM, 32768 words in address order, each low byte first |
| `palette.bin` | 1024 | the VCE's 512 colours, each a word (`0000000gggrrrbbb`); 0-255 background, 256-511 sprites |
| `sat.bin` | 512 | the VDC's sprite attribute table (64 sprites × 4 words: y, x, pattern, attributes), as last copied from VRAM by the SATB DMA |
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

### Gaps and limits

- **No scanline event.** Mesen's Lua API has none. The script uses the debugger's step command
  to stop at every line of the dumped frame, then reads `emu.getState()`. That makes the frame
  slow (a fraction of a second), but no other frame is affected.
- **Per-line memory changes are lost.** Memory is one copy, from the first displayed line, so a
  palette that changes down the screen (an SNES HDMA gradient written to $2121/$2122, or a PC
  Engine raster palette swap) is in the dump only as it was on that line, plus a warning with
  the number of bytes that changed. A reference mismatch on such a frame can come from this.
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
