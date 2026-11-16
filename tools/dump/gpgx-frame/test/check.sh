#!/usr/bin/env bash
# Checks the headless Genesis Plus GX frontend and gpgx-dump.sh on the committed Genesis Plus GX
# fixture (../../test/genesis-test.gpgx-state, of genesis-test-rom.rkt's ROM, regenerated here):
#
#   tools/dump/gpgx-frame/test/check.sh [work-dir]
#
# Builds the core and the frontend (build.sh, into build/gpgx-frame), then checks that:
# - a frame is the native, unfiltered picture: 320 x 224 for the fixture's H40 screen, 256 x 224
#   with register 12 switched to H32, and every pixel a CRAM colour (check.py);
# - the state after frame N extracts to the same memory as the fixture (the ROM only loops), so
#   it round-trips through genesis-savestate.rkt;
# - the state after frame N is frame N's moment: on the ROM's animated variant, which writes a
#   new colour to CRAM at the start of every frame, frames 1 to 3 each show only the CRAM of their
#   own state, differ from each other, and have the colours the ROM wrote; and the state after
#   frame 1, run one more frame, gives frame 2's picture and memory;
# - RetroArch's container around the state gives the same frame;
# - the frontend fails on a bad frame count or a file that isn't a state, and on a Mega-CD state
#   from a build without the Nuked YM3438 core;
# - gpgx-dump.sh writes the dump, the screenshot and info.txt, and refuses bad arguments, a GST
#   state, a state that doesn't fit the game and the Sega CD BIOS cases with 2 before writing
#   anything.
# The Sega CD path itself needs a BIOS and a disc, which never go to CI: it's checked by hand
# (genesis.md). Needs Racket, Python 3 and what build.sh needs. The work directory (default: a
# temporary one, removed on success) keeps every file for a failure's review.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
dump=$(cd "$here/../.." && pwd)
fixture=$dump/test/genesis-test.gpgx-state
gst=$dump/test/genesis-test.gs0
work=${1:-$(mktemp -d "${TMPDIR:-/tmp}/gpgx-frame-check.XXXXXX")}
mkdir -p "$work"
work=$(cd "$work" && pwd)

failures=0
pass() { echo "ok: $*"; }
failed() { echo "FAILED: $*" >&2; failures=$((failures + 1)); }

build=$("$here/../build.sh")
core=$(ls "$build"/genesis_plus_gx_libretro.* | head -n 1)
frontend=$build/gpgx-frame
mkdir -p "$work/system" "$work/save"
racket "$dump/test/genesis-test-rom.rkt" "$work/test.md"
racket "$dump/test/genesis-test-rom.rkt" --animated "$work/animated.md"

# frame <state> <frames> <name> [rom]: runs the frontend (on the test ROM, or [rom]) into
# $work/<name>.png and <name>.state
frame() {
  "$frontend" "$core" "${4:-$work/test.md}" "$1" "$2" "$work/$3.png" "$work/$3.state" \
    "$work/system" "$work/save" >"$work/$3.txt"
}
# cram_entry <dump> <n>: CRAM entry n of a dump, as 4 hex digits
cram_entry() { od -An -tx1 -j $((2 * $2)) -N 2 "$1/cram.bin" | tr -d ' \n'; }
extract() { racket "$dump/genesis-savestate.rkt" "$1" "$2" >/dev/null; }
same_dump() {
  for file in vram cram vsram registers; do
    cmp -s "$1/$file.bin" "$2/$file.bin" || return 1
  done
}
# The state up to the sound context (68K and Z80 RAM, I/O, the VDP): the rest holds host
# pointers, which differ from run to run
same_prefix() { cmp -s -n $((0x2256B)) "$1" "$2"; }

extract "$fixture" "$work/fixture"

# Frames 1 and 2 from the fixture, and frame 1 from the state after frame 1
frame "$fixture" 1 f1 && frame "$fixture" 2 f2 && frame "$work/f1.state" 1 f1-then-1 ||
  { echo "the frontend failed" >&2; exit 1; }
for name in f1 f2 f1-then-1; do
  if extract "$work/$name.state" "$work/$name" && same_dump "$work/fixture" "$work/$name"; then
    pass "$name: the state round-trips to the fixture's memory"
  else
    failed "$name: the state doesn't extract to the fixture's memory"
  fi
  if grep -qx 'width=320' "$work/$name.txt" && grep -qx 'height=224' "$work/$name.txt" &&
    python3 "$here/check.py" "$work/$name.png" 320 224 "$work/$name/cram.bin"; then
    pass "$name: native 320 x 224 frame in CRAM colours"
  else
    failed "$name: not the native H40 frame"
  fi
done
if cmp -s "$work/f2.png" "$work/f1-then-1.png" && same_prefix "$work/f2.state" "$work/f1-then-1.state"; then
  pass "the state after frame 1 continues to frame 2"
else
  failed "running on from the state after frame 1 doesn't give frame 2"
fi

# The animated ROM: each frame's picture and state from the same frame. From the fixture (d4 = 0,
# so frame N writes 2N to CRAM entry 1), each frame must show only its own state's CRAM; a frame
# paired with the state before or after it shows a colour its CRAM doesn't have.
frame "$fixture" 1 a1 "$work/animated.md" && frame "$fixture" 2 a2 "$work/animated.md" &&
  frame "$fixture" 3 a3 "$work/animated.md" && frame "$work/a1.state" 1 a1-then-1 "$work/animated.md" ||
  { echo "the frontend failed on the animated ROM" >&2; exit 1; }
for n in 1 2 3; do
  if extract "$work/a$n.state" "$work/a$n" && [ "$(cram_entry "$work/a$n" 1)" = "000$((2 * n))" ] &&
    python3 "$here/check.py" "$work/a$n.png" 320 224 "$work/a$n/cram.bin"; then
    pass "animated frame $n: the picture shows its own state's CRAM"
  else
    failed "animated frame $n: the picture and the state aren't from the same frame"
  fi
done
if ! cmp -s "$work/a1.png" "$work/a2.png" && ! cmp -s "$work/a2.png" "$work/a3.png" &&
  ! cmp -s "$work/a1.png" "$work/a3.png"; then
  pass "animated frames 1 to 3 differ"
else
  failed "animated frames 1 to 3 aren't all different"
fi
if extract "$work/a1-then-1.state" "$work/a1-then-1" && same_dump "$work/a2" "$work/a1-then-1" &&
  cmp -s "$work/a2.png" "$work/a1-then-1.png" && same_prefix "$work/a2.state" "$work/a1-then-1.state"; then
  pass "animated: the state after frame 1 continues to frame 2"
else
  failed "animated: running on from the state after frame 1 doesn't give frame 2"
fi

# The check itself fails on a palette the picture doesn't use
cp "$work/f1/cram.bin" "$work/wrong-cram.bin"
printf '\x0e\xee' | dd of="$work/wrong-cram.bin" bs=1 seek=2 conv=notrunc 2>/dev/null
if python3 "$here/check.py" "$work/f1.png" 320 224 "$work/wrong-cram.bin" >/dev/null 2>&1; then
  failed "check.py accepts a palette with a colour changed"
else
  pass "check.py refuses a palette with a colour changed"
fi

# H32: register 12 (at 0x22525 + 12) from $81 to $00
python3 - "$fixture" "$work/h32-input.state" <<'EOF'
import sys
data = bytearray(open(sys.argv[1], "rb").read())
assert data[0x22525 + 12] == 0x81
data[0x22525 + 12] = 0x00
open(sys.argv[2], "wb").write(data)
EOF
if frame "$work/h32-input.state" 1 h32 && extract "$work/h32.state" "$work/h32" &&
  grep -qx 'width=256' "$work/h32.txt" && python3 "$here/check.py" "$work/h32.png" 256 224 "$work/h32/cram.bin"; then
  pass "h32: native 256 x 224 frame in CRAM colours"
else
  failed "h32: not the native H32 frame"
fi

# RetroArch's container: a block before the core's state, then "MEM ", then "END "
python3 - "$fixture" "$work/rastate.state" <<'EOF'
import struct, sys
def block(kind, content):
    return kind + struct.pack("<I", len(content)) + content + bytes(-len(content) % 8)
core = open(sys.argv[1], "rb").read()
open(sys.argv[2], "wb").write(b"RASTATE\x01" + block(b"RPLY", b"12345") + block(b"MEM ", core) + block(b"END ", b""))
EOF
if frame "$work/rastate.state" 1 rastate && cmp -s "$work/rastate.png" "$work/f1.png"; then
  pass "RetroArch's container gives the same frame"
else
  failed "RetroArch's container doesn't give the same frame"
fi

# Frontend failures
python3 - "$fixture" "$work/openemu-cd.state" <<'EOF'
import sys
data = bytearray(open(sys.argv[1], "rb").read())
data[0x234C5:0x234C9] = b"SCD!"
open(sys.argv[2], "wb").write(data)
EOF
# expect_frontend_failure <what> <message> <state> <frames>
expect_frontend_failure() {
  if "$frontend" "$core" "$work/test.md" "$3" "$4" "$work/x.png" "$work/x.state" \
    "$work/system" "$work/save" >/dev/null 2>"$work/error.txt"; then
    failed "the frontend accepts $1"
  elif grep -q "$2" "$work/error.txt"; then
    pass "the frontend refuses $1"
  else
    failed "the frontend refuses $1 without saying '$2': $(cat "$work/error.txt")"
  fi
}
expect_frontend_failure "0 frames" "frames must be" "$fixture" 0
expect_frontend_failure "a GST state" "refused the state" "$gst" 1
expect_frontend_failure "an OpenEmu Mega-CD state" "without the Nuked YM3438" "$work/openemu-cd.state" 1
[ ! -e "$work/x.png" ] && [ ! -e "$work/x.state" ] || failed "a refused run wrote output"

# The wrapper
wrapper=$here/../gpgx-dump.sh
if "$wrapper" "$work/test.md" "$fixture" 1 "$work/dump" "$work/dump.state" >"$work/dump.txt" 2>&1 &&
  same_dump "$work/fixture" "$work/dump" && cmp -s "$work/dump/screenshot.png" "$work/f1.png" &&
  same_prefix "$work/dump.state" "$work/f1.state" &&
  [ "$(cat "$work/dump/info.txt")" = "$(printf 'console=Genesis\nframe=1\nwidth=320\nheight=224')" ]; then
  pass "gpgx-dump.sh writes the dump, the screenshot, info.txt and the state"
else
  failed "gpgx-dump.sh: $(cat "$work/dump.txt")"
fi
if "$wrapper" "$work/animated.md" "$fixture" 2 "$work/animated-dump" >"$work/animated-dump.txt" 2>&1 &&
  [ "$(cram_entry "$work/animated-dump" 1)" = 0004 ] && cmp -s "$work/animated-dump/screenshot.png" "$work/a2.png" &&
  python3 "$here/check.py" "$work/animated-dump/screenshot.png" 320 224 "$work/animated-dump/cram.bin"; then
  pass "gpgx-dump.sh dumps the animated ROM's frame 2 with its own screenshot"
else
  failed "gpgx-dump.sh on the animated ROM: $(cat "$work/animated-dump.txt")"
fi

mkdir -p "$work/disc"
head -c 131072 /dev/zero >"$work/bios.bin"
head -c 1000 /dev/zero >"$work/short-bios.bin"
head -c 2352 /dev/zero >"$work/disc/track01.bin"
printf 'FILE "track01.bin" BINARY\r\n  TRACK 01 MODE1/2352\r\n    INDEX 01 00:00:00\r\n' >"$work/disc/game.cue"
printf 'FILE "missing.bin" BINARY\n  TRACK 01 MODE1/2352\n' >"$work/disc/missing.cue"
racket "$dump/test/genesis-megacd-state.rkt" "$work/megacd.state"
long=$work/$(printf '%0130d' 0)/$(printf '%0130d' 0)
mkdir -p "$long"
cp "$work/test.md" "$long/test.md"
# a cue whose own path fits, naming a track whose path (cue folder + name) doesn't
long_track=$(printf '%0130d' 1).bin
head -c 2352 /dev/zero >"$(dirname "$long")/$long_track"
printf 'FILE "%s" BINARY\n  TRACK 01 MODE1/2352\n' "$long_track" >"$(dirname "$long")/long.cue"
expect_refusal() {
  local what=$1 message=$2
  shift 2
  local status=0
  env "$@" >/dev/null 2>"$work/error.txt" || status=$?
  if [ "$status" -ne 2 ]; then
    failed "gpgx-dump.sh exits with $status for $what, not 2"
  elif ! grep -q "$message" "$work/error.txt"; then
    failed "gpgx-dump.sh refuses $what without saying '$message': $(cat "$work/error.txt")"
  elif [ -e "$work/refused" ]; then
    failed "gpgx-dump.sh refuses $what but wrote $work/refused"
  else
    pass "gpgx-dump.sh refuses $what"
  fi
}
expect_refusal "frame 0" "frame 0 is the saved frame" "$wrapper" "$work/test.md" "$fixture" 0 "$work/refused"
expect_refusal "frame 00" "frame 0 is the saved frame" "$wrapper" "$work/test.md" "$fixture" 00 "$work/refused"
expect_refusal "a frame that isn't a number" "whole number" "$wrapper" "$work/test.md" "$fixture" x "$work/refused"
expect_refusal "a frame with a leading zero" "leading zeros" "$wrapper" "$work/test.md" "$fixture" 07 "$work/refused"
expect_refusal "a frame over 1000000" "at most 1000000" "$wrapper" "$work/test.md" "$fixture" 1000001 "$work/refused"
expect_refusal "a game path over 255 bytes" "over 255 bytes" "$wrapper" "$long/test.md" "$fixture" 1 "$work/refused"
expect_refusal "a Mega-CD state with a cartridge" "give the disc's .cue" \
  "$wrapper" "$work/test.md" "$work/megacd.state" 1 "$work/refused"
expect_refusal "a Mega Drive state with a disc" "not a Mega-CD one" \
  PPU_DUMP_BIOS="$work/bios.bin" "$wrapper" "$work/disc/game.cue" "$fixture" 1 "$work/refused"
expect_refusal "a missing state" "no such file" "$wrapper" "$work/test.md" "$work/none.state" 1 "$work/refused"
expect_refusal "a GST state" "isn't a Genesis Plus GX state" "$wrapper" "$work/test.md" "$gst" 1 "$work/refused"
expect_refusal "PPU_DUMP_BIOS for a cartridge" "only for Sega CD games" \
  PPU_DUMP_BIOS="$work/bios.bin" "$wrapper" "$work/test.md" "$fixture" 1 "$work/refused"
expect_refusal "a .cue without PPU_DUMP_BIOS" "needs PPU_DUMP_BIOS" \
  PPU_DUMP_BIOS= "$wrapper" "$work/disc/game.cue" "$fixture" 1 "$work/refused"
expect_refusal "a BIOS of the wrong size" "131072 bytes" \
  PPU_DUMP_BIOS="$work/short-bios.bin" "$wrapper" "$work/disc/game.cue" "$fixture" 1 "$work/refused"
expect_refusal "a .cue naming a missing track" "missing.bin" \
  PPU_DUMP_BIOS="$work/bios.bin" "$wrapper" "$work/disc/missing.cue" "$fixture" 1 "$work/refused"
expect_refusal "a .cue naming a track whose path is over 255 bytes" "over 255 bytes" \
  PPU_DUMP_BIOS="$work/bios.bin" "$wrapper" "$(dirname "$long")/long.cue" "$fixture" 1 "$work/refused"

if [ "$failures" -ne 0 ]; then
  echo "$failures check(s) failed; the files are in $work" >&2
  exit 1
fi
[ $# -ge 1 ] || rm -rf "$work"
echo "All gpgx-frame checks passed"
