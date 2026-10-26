#!/usr/bin/env python3
"""Checks dumps of the test ROMs made by mesen-dump.lua (run by check.sh).

    check.py snes <dump-dir>
    check.py pce <dump-dir>

The expected values follow from what snes-test.s and pce-test.s write; see their header comments.
"""

import struct
import sys
import zlib

SNES_REGISTERS = (
    "INIDISP OBSEL OAMADD BGMODE MOSAIC BG1SC BG2SC BG3SC BG4SC BG12NBA BG34NBA "
    "BG1HOFS BG1VOFS BG2HOFS BG2VOFS BG3HOFS BG3VOFS BG4HOFS BG4VOFS "
    "M7SEL M7A M7B M7C M7D M7X M7Y M7HOFS M7VOFS "
    "W12SEL W34SEL WOBJSEL WH0 WH1 WH2 WH3 WBGLOG WOBJLOG "
    "TM TS TMW TSW CGWSEL CGADSUB COLDATA SETINI"
).split()
PCE_REGISTERS = (
    "CR RCR BXR BYR MWR HSR HDR VPR VDW VCR SCROLL_X SCROLL_Y FLAGS LINE MWR_LATCHED VCE_CR"
).split()

failures = []


def expect(what, actual, expected):
    if actual != expected:
        failures.append(f"{what}: got {actual!r}, expected {expected!r}")


def read(directory, name):
    with open(f"{directory}/{name}", "rb") as f:
        return f.read()


def rows(data, names):
    size = 2 * len(names)
    if len(data) % size:
        failures.append(f"registers.bin is {len(data)} bytes, not a multiple of {size}")
        return []
    fmt = "<" + "H" * len(names)
    return [dict(zip(names, struct.unpack(fmt, data[i:i + size]))) for i in range(0, len(data), size)]


def png(data):
    """Returns (width, height, rows of (r, g, b) tuples) for an 8-bit RGB PNG."""
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG")
    pos, idat, header = 8, b"", None
    while pos < len(data):
        (length,) = struct.unpack(">I", data[pos:pos + 4])
        kind = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + length]
        (crc,) = struct.unpack(">I", data[pos + 8 + length:pos + 12 + length])
        if zlib.crc32(kind + body) != crc:
            raise ValueError(f"bad CRC in {kind!r}")
        if kind == b"IHDR":
            header = struct.unpack(">IIBBBBB", body)
        elif kind == b"IDAT":
            idat += body
        pos += 12 + length
    width, height, depth, colour, _, _, interlace = header
    if (depth, colour, interlace) != (8, 2, 0):
        raise ValueError("not 8-bit RGB")
    raw = zlib.decompress(idat)
    stride = width * 3 + 1
    if len(raw) != stride * height:
        raise ValueError("wrong image data size")
    image = []
    for y in range(height):
        line = raw[y * stride:(y + 1) * stride]
        if line[0] != 0:
            raise ValueError("unexpected filter type")
        image.append([tuple(line[1 + x * 3:4 + x * 3]) for x in range(width)])
    return width, height, image


def edges(line):
    """x positions where a row's colour changes."""
    return [x for x in range(1, len(line)) if line[x] != line[x - 1]]


def info(directory):
    entries = {}
    for line in read(directory, "info.txt").decode().splitlines():
        key, _, value = line.partition("=")
        entries.setdefault(key, []).append(value)
    return entries


def horizontal_edges(image, first, last, scroll_x, starts_tile_row, width=40):
    """Checks that, from row first + 1 to last, a row's left edge (x < width, where no sprite
    is) differs from the row above exactly when the row starts a new row of background tiles.
    Rows whose horizontal scroll differs from the row above are skipped."""
    for y in range(first + 1, last + 1):
        if scroll_x[y] != scroll_x[y - 1]:
            continue
        expect(f"screenshot row {y} starts a tile row", image[y][:width] != image[y - 1][:width], starts_tile_row(y))


# The values snes-test.s writes to the registers that don't change down the screen.
SNES_FIXED = {
    "OBSEL": 0x59, "OAMADD": 0x8005, "BGMODE": 0xE9, "MOSAIC": 0x5E,
    "BG1SC": 0x10, "BG2SC": 0x21, "BG3SC": 0x32, "BG4SC": 0x43, "BG12NBA": 0x30, "BG34NBA": 0x54,
    "BG2HOFS": 0x123, "BG2VOFS": 0x045, "BG3HOFS": 0x067, "BG3VOFS": 0x189, "BG4HOFS": 0x0AB, "BG4VOFS": 0x1CD,
    "M7SEL": 0xC3, "M7A": 0x1234, "M7B": 0x8765, "M7C": 0x0F0F, "M7D": 0xF00D, "M7X": 0x1F00, "M7Y": 0x0123,
    "W12SEL": 0xB4, "W34SEL": 0x7D, "WOBJSEL": 0xE6, "WH0": 0x12, "WH1": 0x34, "WH2": 0x56, "WH3": 0x78,
    "WBGLOG": 0x1B, "WOBJLOG": 0x09, "TS": 0x0A, "TMW": 0x06, "TSW": 0x13, "CGWSEL": 0x33, "CGADSUB": 0xD5,
    "SETINI": 0x42,
}


def check_snes(directory):
    meta = info(directory)
    expect("console", meta.get("console"), ["SNES"])
    expect("warnings", meta.get("warning"), None)
    vram = read(directory, "vram.bin")
    expect("vram.bin size", len(vram), 65536)
    cgram = read(directory, "cgram.bin")
    expect("cgram.bin size", len(cgram), 512)
    oam = read(directory, "oam.bin")
    expect("oam.bin size", len(oam), 544)
    # Sprite 3 has x bit 9 set in the high table (bits 6-7 of byte 512: sprite 3's x9 and size).
    expect("OAM sprite 0", oam[0:4], bytes([40, 40, 1, 0x30]))
    expect("OAM high table byte 0 (sprite 3 x bit 9)", oam[512] & 0x40, 0x40)

    # The frame counter, as the NMI handler wrote it to VRAM word $7000 in forced blank on line 3.
    # The memory is from the first displayed line (9), so it must be this frame's.
    c = vram[0xE000]
    expect("VRAM word $7000", vram[0xE000:0xE002], bytes([c, c]))
    expect("colour 200", cgram[400:402], bytes([c, c & 0x7F]))
    expect("frame counter is running", c >= 5, True)

    regs = rows(read(directory, "registers.bin"), SNES_REGISTERS)
    expect("rows", len(regs), 224)
    if len(regs) != 224:
        return
    for i, row in enumerate(regs):
        line = i + 1
        for name, value in SNES_FIXED.items():
            expect(f"row {i} {name}", row[name], value)
        # HDMA writes hscroll = entry * 4 every 8 lines, during the H-blank before the line, and
        # INIDISP: forced blank on lines 1-8.
        expect(f"row {i} BG1HOFS", row["BG1HOFS"], min((line - 1) // 8, 27) * 4)
        expect(f"row {i} INIDISP", row["INIDISP"], 0x8F if line <= 8 else 0x0F)
        # $210D/$210E also set the Mode 7 scroll, from the same writes, but with 13 bits.
        expect(f"row {i} M7HOFS", row["M7HOFS"], row["BG1HOFS"])
        expect(f"row {i} BG1VOFS", row["BG1VOFS"], 0x300 | c)
        expect(f"row {i} M7VOFS", row["M7VOFS"], 0x1F00 | c)
        # The V-IRQ at line 112 runs during that line, after its first pixel: the dump rounds the
        # write to the next line.
        expect(f"row {i} TM", row["TM"], 0x11 if line <= 112 else 0x01)
        expect(f"row {i} COLDATA", row["COLDATA"], 0x0000 if line <= 112 else 0x001F)  # red 31, as BGR555

    width, height, image = png(read(directory, "screenshot.png"))
    expect("screenshot size", (width, height), (256, 224))
    if (width, height) != (256, 224):
        return
    for y in range(8):
        expect(f"screenshot row {y} (forced blank) is blank", edges(image[y]), [])
    # The checkerboard's columns move with BG1HOFS, and its rows with BG1VOFS (which changes every
    # frame), so the screenshot must be of the same frame as the register rows.
    for y in (8, 100, 111, 112, 200):
        shift = regs[y]["BG1HOFS"] % 8
        expect(f"screenshot row {y} first edge", edges(image[y])[:1], [8 - shift])
    # Scanline y + 1 shows background line y + 1 + vscroll.
    horizontal_edges(image, 8, 223, [row["BG1HOFS"] for row in regs],
                     lambda y: (y + 1 + regs[y]["BG1VOFS"]) % 8 == 0)


def check_pce(directory):
    meta = info(directory)
    expect("console", meta.get("console"), ["PC Engine"])
    vram = read(directory, "vram.bin")
    expect("vram.bin size", len(vram), 65536)
    palette = read(directory, "palette.bin")
    expect("palette.bin size", len(palette), 1024)
    sat = read(directory, "sat.bin")
    expect("sat.bin size", len(sat), 512)
    expect("SAT sprite 0 nonzero", any(sat[0:8]), True)

    # The frame counter, as the vertical-blank handler wrote it to VRAM word $7000 and colour 100
    # after the frame started. The memory is from the first displayed line, so it must be this
    # frame's. The raster handler writes it to $7001 during the frame, so the dump holds the
    # previous frame's value there, and warns. The handler writes the next frame's counter to
    # $7002 in this frame's vertical blank, which must neither show nor warn.
    c = vram[0xE000]
    expect("VRAM word $7000", vram[0xE000:0xE002], bytes([c, c]))
    expect("VRAM word $7001", vram[0xE002:0xE004], bytes([(c - 1) & 0xFF] * 2))
    expect("VRAM word $7002", vram[0xE004:0xE006], bytes([c, c]))
    expect("colour 100", palette[200:202], bytes([c, 0]))
    expect("frame counter is running", c >= 3, True)
    expect("warnings", meta.get("warning"), [
        "vram.bin changed in 2 bytes after the first displayed line; the dump holds its state from the start of that line"])

    regs = rows(read(directory, "registers.bin"), PCE_REGISTERS)
    expect("rows", len(regs), 242)
    if len(regs) != 242:
        return
    first = next((i for i, row in enumerate(regs) if row["FLAGS"] & 8), None)
    expect("first displayed row", first, 14)
    if first is None:
        return
    for i, row in enumerate(regs):
        expect(f"row {i} CR", row["CR"], 0x10DF)
        expect(f"row {i} RCR", row["RCR"], 164)
        expect(f"row {i} MWR", row["MWR"], 0xD9)
        expect(f"row {i} HSR", row["HSR"], 0x0202)
        expect(f"row {i} HDR", row["HDR"], 0x031F)
        expect(f"row {i} VPR", row["VPR"], 0x1A02)
        expect(f"row {i} VDW", row["VDW"], 0xDF)
        expect(f"row {i} VCR", row["VCR"], 0x03)
        # Mesen 2.1.1 doesn't latch the CG mode (bit 7); accept a version that does.
        expect(f"row {i} MWR_LATCHED", row["MWR_LATCHED"] in (0x59, 0xD9), True)
        expect(f"row {i} VCE_CR", row["VCE_CR"], 0x84)
        expect(f"row {i} FLAGS", row["FLAGS"], 0x0B if first <= i < first + 224 else 0x03)
        if first <= i < first + 224:
            line = i - first
            expect(f"row {i} LINE", row["LINE"], line)
            # The raster IRQ (RCR 164 = line 100) writes BXR = c + 12 and BYR = 0 during line 99,
            # so line 100 restarts the background at its row 1 and scrolls it by 12 more.
            expect(f"row {i} BXR", row["BXR"], c + 12 if line >= 99 else c)
            expect(f"row {i} BYR", row["BYR"], 0 if line >= 99 else c)
            expect(f"row {i} SCROLL_X", row["SCROLL_X"], c + 12 if line >= 100 else c)
            expect(f"row {i} SCROLL_Y", row["SCROLL_Y"], line - 99 if line >= 100 else line + c)

    width, height, image = png(read(directory, "screenshot.png"))
    expect("screenshot size", (width, height), (256, 242))
    if (width, height) != (256, 242):
        return
    expect("screenshot rows before the display are blank", edges(image[first - 1]), [])
    # The checkerboard's columns move with SCROLL_X and its rows with SCROLL_Y (both change every
    # frame), so the screenshot must be of the same frame as the register rows.
    for y in (first, first + 50, first + 99, first + 100, first + 200):
        shift = regs[y]["SCROLL_X"] % 8
        expect(f"screenshot row {y} first edge", edges(image[y])[:1], [8 - shift])
    expect("screenshot rows after the display are blank", edges(image[first + 224]), [])
    horizontal_edges(image, first, first + 223, [row["SCROLL_X"] for row in regs],
                     lambda y: regs[y]["SCROLL_Y"] % 8 == 0)


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ("snes", "pce"):
        sys.exit(__doc__)
    try:
        (check_snes if sys.argv[1] == "snes" else check_pce)(sys.argv[2])
    except (OSError, ValueError) as e:
        failures.append(str(e))
    for f in failures[:20]:
        print(f"{sys.argv[1]}: {f}", file=sys.stderr)
    if len(failures) > 20:
        print(f"{sys.argv[1]}: ... and {len(failures) - 20} more", file=sys.stderr)
    if failures:
        sys.exit(1)
    print(f"{sys.argv[1]}: dump OK")


if __name__ == "__main__":
    main()
