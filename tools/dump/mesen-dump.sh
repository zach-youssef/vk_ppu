#!/bin/sh
# Dumps one SNES, PC Engine or PC Engine CD frame with Mesen 2, headless (see README.md).
#
#   MESEN=/path/to/Mesen [PPU_DUMP_BIOS=<system card>] tools/dump/mesen-dump.sh \
#     <rom or .cue> <out-dir> [frame] [savestate.mss]
#
# MESEN is the Mesen executable (on macOS, Mesen.app/Contents/MacOS/Mesen). Mesen runs with a
# throwaway HOME so it neither reads nor changes your own Mesen settings (unless it is portable,
# see README.md). PPU_DUMP_BIOS, the 256 KB System Card 3.0 image, is required for a PC Engine CD
# game (its .cue) and refused for anything else. Exits with 2 if the arguments are wrong, and
# otherwise non-zero, with Mesen's log on stderr, if the dump fails or a file has the wrong size.
set -eu

if [ $# -lt 2 ] || [ $# -gt 4 ]; then
  echo "usage: MESEN=/path/to/Mesen [PPU_DUMP_BIOS=<system card>] $0 <rom or .cue> <out-dir> [frame] [savestate.mss]" >&2
  exit 2
fi
[ -n "${MESEN:-}" ] || { echo "$0: set MESEN to the Mesen 2 executable" >&2; exit 2; }

rom=$1
out=$2
frame=${3:-1}
state=${4:-}
case $frame in
  '' | *[!0-9]*) echo "$0: frame must be a whole number, not '$frame'" >&2; exit 2 ;;
esac
script="$(cd "$(dirname "$0")" && pwd)/mesen-dump.lua"

case $rom in /*) ;; *) rom="$(pwd)/$rom" ;; esac
if [ -n "$state" ]; then
  case $state in /*) ;; *) state="$(pwd)/$state" ;; esac
fi

fail() {
  echo "$0: $*" >&2
  exit 2
}

# A PC Engine CD game is a .cue sheet plus the track files it names, which Mesen looks for in the
# cue's folder. Mesen needs the System Card for it, which it only takes from its home folder's
# Firmware folder, and the wrapper's throwaway home has none: Mesen would fail to load the game
# with -1 (and its UI, outside --testrunner, would ask for the card with a dialog). So a .cue
# needs PPU_DUMP_BIOS, and the wrapper checks the card and the tracks before Mesen starts.
bios=${PPU_DUMP_BIOS:-}
case $(printf '%s' "$rom" | tr '[:upper:]' '[:lower:]') in
  *.cue)
    [ -f "$rom" ] || fail "no such file: $rom"
    [ -n "$bios" ] || fail "a PC Engine CD game needs PPU_DUMP_BIOS set to the System Card 3.0 image"
    cue_dir=$(dirname "$rom")
    # FILE "name" TYPE, or FILE name TYPE without quotes, where Mesen takes the name to be
    # everything up to the last space; CRLF line ends are fine. (Mesen also takes "FILE name" with
    # no type, which no ripper writes; it is refused here as naming no file.)
    files=$(tr -d '\r' <"$rom" | sed -n \
      -e 's/^[[:space:]]*FILE[[:space:]][[:space:]]*"\(.*\)".*$/\1/p' \
      -e 't' \
      -e 's/^[[:space:]]*FILE[[:space:]][[:space:]]*\(.*[^[:space:]]\)[[:space:]][[:space:]]*[^[:space:]]*[[:space:]]*$/\1/p')
    [ -n "$files" ] || fail "$rom names no FILE: not a cue sheet"
    printf '%s\n' "$files" | while IFS= read -r file; do
      [ -f "$cue_dir/$file" ] || fail "$rom names $file, which isn't in $cue_dir"
    done || exit 2 # the loop runs in a subshell, so its fail only ends the loop
    ;;
  *)
    [ -z "$bios" ] || fail "PPU_DUMP_BIOS is only for PC Engine CD games (.cue), not $rom"
    ;;
esac
if [ -n "$bios" ]; then
  [ -f "$bios" ] || fail "PPU_DUMP_BIOS: no such file: $bios"
  bios_size=$(wc -c <"$bios" | tr -d ' ')
  [ "$bios_size" -eq 262144 ] ||
    fail "PPU_DUMP_BIOS is $bios_size bytes; the System Card 3.0 image is 262144 bytes"
  # A portable Mesen ignores the seeded home (see below) and loads the card from its own folder.
  if [ -f "$(dirname "$MESEN")/settings.json" ]; then
    echo "$0: note: $MESEN is portable, so it uses the System Card in its own Firmware folder, not PPU_DUMP_BIOS" >&2
  fi
fi

# Only now, so that a refused run leaves no empty folder behind.
mkdir -p "$out"
out="$(cd "$out" && pwd)"

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
  # Mesen looks for the System Card in its home's Firmware folder, as
  # "[BIOS] Super CD-ROM System (Japan) (v3.0).pce" or as syscard3.pce, checking only the size.
  if [ -n "$bios" ]; then
    mkdir -p "$dir/Firmware"
    cp "$bios" "$dir/Firmware/syscard3.pce"
  fi
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
palette_writes=$(sed -n 's/^paletteWrites=//p' "$out/info.txt")
case $(sed -n 's/^console=//p' "$out/info.txt") in
  SNES) check cgram.bin 512; check oam.bin 544; check cgram-writes.bin $((palette_writes * 8)) ;;
  "PC Engine") check palette.bin 1024; check sat.bin 512; check palette-writes.bin $((palette_writes * 8)) ;;
  *) echo "$0: unknown console in info.txt" >&2; exit 1 ;;
esac
grep '^warning=' "$out/info.txt" >&2 || true
echo "dumped to $out"
