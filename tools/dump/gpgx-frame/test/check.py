#!/usr/bin/env python3
"""Checks a gpgx-frame screenshot against the dump of the state it was taken with:

    check.py <screenshot.png> <width> <height> <cram.bin>

The PNG must be <width> x <height>, 8-bit RGB, and every pixel one of CRAM's 64 colours as the
core outputs them, so the picture is the native frame with no filter blending colours: the core
draws a normal (not shadowed or highlighted) CRAM channel c (0-7) as the 4-bit level 2c, which
its RGB565 output holds as 5 bits (level << 1 | level >> 3) or 6 bits (level << 2 | level >> 2),
which gpgx-frame widens to 8 bits by repeating the top bits. Exits non-zero with the reason.
"""
import struct
import sys
import zlib


def read_png(path):
    data = open(path, "rb").read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        sys.exit(f"{path}: not a PNG")
    at, header, idat = 8, None, b""
    while at < len(data):
        length, kind = struct.unpack(">I4s", data[at:at + 8])
        body = data[at + 8:at + 8 + length]
        if zlib.crc32(kind + body) != struct.unpack(">I", data[at + 8 + length:at + 12 + length])[0]:
            sys.exit(f"{path}: bad CRC in {kind}")
        if kind == b"IHDR":
            header = struct.unpack(">IIBBBBB", body)
        elif kind == b"IDAT":
            idat += body
        elif kind == b"IEND":
            break
        at += 12 + length
    width, height, depth, colour, _, _, interlace = header
    if (depth, colour, interlace) != (8, 2, 0):
        sys.exit(f"{path}: depth {depth}, colour type {colour}, interlace {interlace}; expected 8-bit RGB, not interlaced")
    raw = zlib.decompress(idat)
    stride = width * 3
    rows, previous = [], bytearray(stride)
    for y in range(height):
        kind = raw[y * (stride + 1)]
        line = bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for x in range(stride):
            left = line[x - 3] if x >= 3 else 0
            up = previous[x]
            upper_left = previous[x - 3] if x >= 3 else 0
            if kind == 1:
                line[x] = (line[x] + left) & 0xFF
            elif kind == 2:
                line[x] = (line[x] + up) & 0xFF
            elif kind == 3:
                line[x] = (line[x] + (left + up) // 2) & 0xFF
            elif kind == 4:
                p = left + up - upper_left
                pa, pb, pc = abs(p - left), abs(p - up), abs(p - upper_left)
                predictor = left if pa <= pb and pa <= pc else up if pb <= pc else upper_left
                line[x] = (line[x] + predictor) & 0xFF
            elif kind != 0:
                sys.exit(f"{path}: unknown filter {kind} on row {y}")
        rows.append(bytes(line))
        previous = line
    return width, height, rows


def cram_colours(path):
    cram = open(path, "rb").read()
    def five_bits(c):  # red, blue
        level = c << 1
        five = level << 1 | level >> 3
        return five << 3 | five >> 2

    def six_bits(c):  # green
        level = c << 1
        six = level << 2 | level >> 2
        return six << 2 | six >> 4

    colours = set()
    for i in range(64):
        word = cram[2 * i] << 8 | cram[2 * i + 1]  # 0000 BBB0 GGG0 RRR0
        r, g, b = (word >> 1) & 7, (word >> 5) & 7, (word >> 9) & 7
        colours.add((five_bits(r), six_bits(g), five_bits(b)))
    return colours


def main():
    png, width, height, cram = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
    got_width, got_height, rows = read_png(png)
    if (got_width, got_height) != (width, height):
        sys.exit(f"{png}: {got_width} x {got_height}, expected {width} x {height}")
    palette = cram_colours(cram)
    used = set()
    for y, row in enumerate(rows):
        for x in range(width):
            pixel = tuple(row[3 * x:3 * x + 3])
            if pixel not in palette:
                sys.exit(f"{png}: pixel ({x}, {y}) is {pixel}, not a CRAM colour")
            used.add(pixel)
    # The test ROM's tiles draw from every palette line; a blank or one-colour frame isn't it
    if len(used) < 16:
        sys.exit(f"{png}: only {len(used)} colours")
    print(f"{png}: {width} x {height}, {len(used)} CRAM colours")


main()
