#!/bin/sh
# Builds the test ROMs, dumps them with mesen-dump.sh and checks the dumps (see ../README.md).
#
#   MESEN=/path/to/Mesen tools/dump/test/check.sh [work-dir]
#
# Needs ca65/ld65 (cc65) and python3. The ROMs and dumps go to work-dir (default: a new
# temporary directory, removed on success).
set -eu

: "${MESEN:?set MESEN to the Mesen 2 executable}"
here="$(cd "$(dirname "$0")" && pwd)"
if [ $# -ge 1 ]; then
  work=$1
  mkdir -p "$work"
  keep=1
else
  work=$(mktemp -d "${TMPDIR:-/tmp}/mesen-dump-check.XXXXXX")
  keep=0
fi

for rom in snes pce; do
  ext=$([ $rom = snes ] && echo sfc || echo pce)
  ca65 -o "$work/$rom.o" "$here/$rom-test.s"
  ld65 -C "$here/$rom-test.cfg" -o "$work/$rom-test.$ext" "$work/$rom.o"
  # Frame 10: both ROMs finish setting up within the first few frames.
  "$here/../mesen-dump.sh" "$work/$rom-test.$ext" "$work/$rom" 10
  python3 -I "$here/check.py" $rom "$work/$rom"
done

# Frame 1 is in forced blank all the way through (the SNES ROM is still setting up), so memory
# comes from the frame's end, with a warning.
"$here/../mesen-dump.sh" "$work/snes-test.sfc" "$work/snes-blank" 1
if ! grep -qx "warning=no line of the frame was displayed; memory is dumped as of the frame's end" \
    "$work/snes-blank/info.txt"; then
  cat "$work/snes-blank/info.txt" >&2
  echo "$0: the SNES dump of frame 1 should warn that no line was displayed" >&2
  exit 1
fi

# A failed dump must make Mesen exit with 1 (not -1, a timeout) and say why. The bad frame
# number fails when the script loads; the bad savestate fails in a callback on the emulation
# thread.
must_fail() {
  expected=$1
  shift
  if "$here/../mesen-dump.sh" "$@" 2>"$work/fail.txt"; then
    echo "$0: mesen-dump.sh $* should have failed" >&2
    exit 1
  fi
  if ! grep -q "Mesen exited with 1$" "$work/fail.txt" || ! grep -q "$expected" "$work/fail.txt"; then
    cat "$work/fail.txt" >&2
    echo "$0: mesen-dump.sh $* didn't fail with exit code 1 and \"$expected\"" >&2
    exit 1
  fi
}
must_fail "PPU_DUMP_FRAME must be" "$work/snes-test.sfc" "$work/bad" 0
printf 'not a savestate' >"$work/bad.mss"
must_fail "couldn't load the savestate" "$work/pce-test.pce" "$work/bad" 1 "$work/bad.mss"

[ $keep = 1 ] || rm -rf "$work"
echo "all dump checks passed"
