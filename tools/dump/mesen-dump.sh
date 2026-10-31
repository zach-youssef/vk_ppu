#!/bin/sh
# Dumps one SNES or PC Engine frame with Mesen 2, headless (see README.md).
#
#   MESEN=/path/to/Mesen tools/dump/mesen-dump.sh <rom> <out-dir> [frame] [savestate.mss]
#
# MESEN is the Mesen executable (on macOS, Mesen.app/Contents/MacOS/Mesen). Mesen runs with a
# throwaway HOME so it neither reads nor changes your own Mesen settings (unless it is portable,
# see README.md). Exits non-zero, with Mesen's log on stderr, if the dump fails or a file has the
# wrong size.
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
# Without a settings.json in its home folder, Mesen shows its setup wizard instead of running the
# test (on Linux, that needs a display and then waits for a click). An empty one gives Mesen's
# defaults. The home folder is .NET's ApplicationData folder plus Mesen2: on Linux
# $XDG_CONFIG_HOME/Mesen2 (GitHub's runners set XDG_CONFIG_HOME, so it's pointed into the
# throwaway HOME too), and on macOS ~/Library/Application Support/Mesen2, where ~ comes from
# CFFIXED_USER_HOME rather than HOME. A portable Mesen, with a settings.json next to the
# executable, uses that folder and its settings instead.
for dir in "$home/.config/Mesen2" "$home/Library/Application Support/Mesen2"; do
  mkdir -p "$dir"
  echo '{}' >"$dir/settings.json"
done

# Seconds of emulation before Mesen gives up: generous, since each frame before the dumped one
# runs at full speed and the dumped frame takes well under a second.
timeout=$((10 + frame / 30))

# DOTNET_SYSTEM_GLOBALIZATION_INVARIANT keeps .NET from loading ICU, which on Linux brings in the
# system's libstdc++ before Mesen's core (built with its own copy) and makes the core's start-up
# abort with std::bad_cast (seen on Ubuntu 24.04 with Mesen 2.1.1). Mesen's UI text isn't used here.
status=0
HOME="$home" CFFIXED_USER_HOME="$home" XDG_CONFIG_HOME="$home/.config" \
  DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1 \
  PPU_DUMP_OUT="$out" PPU_DUMP_FRAME="$frame" PPU_DUMP_STATE="$state" \
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
