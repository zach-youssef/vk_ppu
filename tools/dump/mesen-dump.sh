#!/bin/sh
# Dumps one SNES or PC Engine frame with Mesen 2, headless (see README.md).
#
#   MESEN=/path/to/Mesen tools/dump/mesen-dump.sh <rom> <out-dir> [frame] [savestate.mss]
#
# MESEN is the Mesen executable (on macOS, Mesen.app/Contents/MacOS/Mesen). Mesen runs with a
# throwaway HOME so it neither reads nor changes your own Mesen settings. Exits non-zero, with
# Mesen's log on stderr, if the dump fails or a file has the wrong size.
set -eu

if [ $# -lt 2 ] || [ $# -gt 4 ]; then
  echo "usage: MESEN=/path/to/Mesen $0 <rom> <out-dir> [frame] [savestate.mss]" >&2
  exit 2
fi
: "${MESEN:?set MESEN to the Mesen 2 executable}"

rom=$1
out=$2
frame=${3:-1}
state=${4:-}
case $frame in
  '' | *[!0-9]*) echo "$0: frame must be a whole number, not '$frame'" >&2; exit 2 ;;
esac
script="$(cd "$(dirname "$0")" && pwd)/mesen-dump.lua"

mkdir -p "$out"
out="$(cd "$out" && pwd)"
case $rom in /*) ;; *) rom="$(pwd)/$rom" ;; esac
if [ -n "$state" ]; then
  case $state in /*) ;; *) state="$(pwd)/$state" ;; esac
fi

home=$(mktemp -d "${TMPDIR:-/tmp}/mesen-dump-home.XXXXXX")
trap 'rm -rf "$home"' EXIT

# Seconds of emulation before Mesen gives up: generous, since each frame before the dumped one
# runs at full speed and the dumped frame takes well under a second.
timeout=$((10 + frame / 30))

status=0
HOME="$home" PPU_DUMP_OUT="$out" PPU_DUMP_FRAME="$frame" PPU_DUMP_STATE="$state" \
  "$MESEN" --testrunner \
  --debug.scriptWindow.allowIoOsAccess=true \
  --debug.scriptWindow.scriptTimeout=5 \
  --snes.disableFrameSkipping=true \
  --pcEngine.disableFrameSkipping=true \
  "$script" "$rom" --timeout="$timeout" >"$home/log.txt" 2>&1 || status=$?

if [ "$status" -ne 0 ]; then
  cat "$home/log.txt" >&2
  echo "$0: Mesen exited with $status" >&2
  exit 1
fi

check() {
  size=$(wc -c <"$out/$1" | tr -d ' ')
  if [ "$size" -ne "$2" ]; then
    echo "$0: $1 is $size bytes, expected $2" >&2
    exit 1
  fi
}

rows=$(sed -n 's/^rows=//p' "$out/info.txt")
row_bytes=$(sed -n 's/^rowBytes=//p' "$out/info.txt")
check vram.bin 65536
check registers.bin $((rows * row_bytes))
case $(sed -n 's/^console=//p' "$out/info.txt") in
  SNES) check cgram.bin 512; check oam.bin 544 ;;
  "PC Engine") check palette.bin 1024; check sat.bin 512 ;;
  *) echo "$0: unknown console in info.txt" >&2; exit 1 ;;
esac
grep '^warning=' "$out/info.txt" >&2 || true
echo "dumped to $out"
