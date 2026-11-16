#!/usr/bin/env bash
# Dumps a Genesis or Sega CD frame N >= 1 frames after a Genesis Plus GX savestate, with the
# frame's reference screenshot (see ../genesis.md, "Frames after the state"):
#
#   [PPU_DUMP_BIOS=<Sega CD BIOS>] tools/dump/gpgx-frame/gpgx-dump.sh \
#     <rom or .cue> <state> <frame> <out-dir> [state-out]
#
# <rom or .cue> must be the game the state was saved from: the core doesn't check, and runs another
# game's state into garbage. Builds the core and the frontend if needed (build.sh, into
# build/gpgx-frame), runs <frame> frames from <state> headless (1 = the first frame after the state
# loads), then writes the frame's memory (genesis-savestate.rkt's files, from the core's state
# after that frame) and the frame itself as screenshot.png, plus info.txt, to <out-dir>. The state
# after the frame is written to <state-out> if given (never commit it), else discarded.
# PPU_DUMP_BIOS, the 128 KB Sega CD BIOS for the disc's region, is required for a disc (its .cue)
# and refused for a cartridge. Needs Racket (racket on PATH) and what build.sh needs. Exits with 2,
# before running the core or writing to <out-dir>, if the arguments are wrong (or the state doesn't
# fit the game), and with 1 if the dump fails.
set -euo pipefail

usage="usage: [PPU_DUMP_BIOS=<Sega CD BIOS>] $0 <rom or .cue> <state> <frame> <out-dir> [state-out]"
if [ $# -lt 4 ] || [ $# -gt 5 ]; then
  echo "$usage" >&2
  exit 2
fi
game=$1 state=$2 frame=$3 out=$4 state_out=${5:-}
here=$(cd "$(dirname "$0")" && pwd)
extractor=$here/../genesis-savestate.rkt

fail() {
  echo "$0: $*" >&2
  exit 2
}

# The frame: 1 to 1000000 (the frontend's limit), written without leading zeros
case $frame in
  '' | *[!0-9]*) fail "frame must be a whole number from 1, not '$frame'" ;;
esac
[ -n "${frame//0/}" ] || fail "frame 0 is the saved frame itself, which the state can't redraw: run genesis-savestate.rkt on the state and use the emulator's screenshot (genesis.md)"
case $frame in
  0*) fail "frame must be written without leading zeros, not '$frame'" ;;
esac
[ "${#frame}" -le 7 ] && [ "$frame" -le 1000000 ] || fail "frame must be at most 1000000, not $frame"
[ -f "$game" ] || fail "no such file: $game"
# The core copies the game's path into a 256-byte buffer, truncating it without an error
[ "$(printf '%s' "$game" | wc -c)" -le 255 ] ||
  fail "the game's path is over 255 bytes, more than the core takes: move it or link it from a shorter path"
[ -f "$state" ] || fail "no such file: $state"

# A Sega CD game is a .cue sheet plus the track files it names, which the core reads from the
# cue's folder (as in mesen-dump.sh). The core loads the BIOS for the region it detects from its
# system folder, as bios_CD_U.bin (US), bios_CD_E.bin (Europe) or bios_CD_J.bin (Japan), and
# fails to load the disc without it.
bios=${PPU_DUMP_BIOS:-}
disc=false
case $(printf '%s' "$game" | tr '[:upper:]' '[:lower:]') in
  *.cue)
    [ -n "$bios" ] || fail "a Sega CD game needs PPU_DUMP_BIOS set to the Sega CD BIOS for the disc's region"
    [ -f "$bios" ] || fail "PPU_DUMP_BIOS: no such file: $bios"
    bios_size=$(wc -c <"$bios" | tr -d ' ')
    [ "$bios_size" -eq 131072 ] || fail "PPU_DUMP_BIOS is $bios_size bytes; a Sega CD BIOS is 131072 bytes"
    disc=true
    cue_dir=$(dirname "$game")
    # FILE "name" TYPE, or FILE name TYPE without quotes; CRLF line ends are fine
    files=$(tr -d '\r' <"$game" | sed -n \
      -e 's/^[[:space:]]*FILE[[:space:]][[:space:]]*"\(.*\)".*$/\1/p' \
      -e 't' \
      -e 's/^[[:space:]]*FILE[[:space:]][[:space:]]*\(.*[^[:space:]]\)[[:space:]][[:space:]]*[^[:space:]]*[[:space:]]*$/\1/p')
    [ -n "$files" ] || fail "$game names no FILE: not a cue sheet"
    while IFS= read -r file; do
      [ -f "$cue_dir/$file" ] || fail "$game names $file, which isn't in $cue_dir"
      # the core reads each track from the cue's folder plus its name, cut to 255 bytes
      [ "$(printf '%s/%s' "$cue_dir" "$file" | wc -c)" -le 255 ] ||
        fail "$cue_dir/$file is over 255 bytes, more than the core takes: move the disc to a shorter path"
    done <<<"$files"
    ;;
  *)
    [ -z "$bios" ] || fail "PPU_DUMP_BIOS is only for Sega CD games (.cue), not $game"
    ;;
esac

work=$(mktemp -d "${TMPDIR:-/tmp}/gpgx-dump.XXXXXX")
trap 'rm -rf "$work"' EXIT

# The state must be one the extractor reads (which also catches a truncated one), and one this
# core loads: a Genesis Plus GX state, not a GST one, and for the Sega CD, saved with the CD part
# laid out as current builds do (an older build's loads misread, without an error).
if ! racket "$extractor" "$state" "$work/input" >"$work/input.txt" 2>&1; then
  cat "$work/input.txt" >&2
  fail "can't read the state $state"
fi
grep -q 'Genesis Plus GX' "$work/input.txt" ||
  fail "$state isn't a Genesis Plus GX state (the extractor read: $(head -n 1 "$work/input.txt"))"
if grep -q 'Mega-CD' "$work/input.txt" && ! grep -q 'laid out as GPGX builds since Feb 2024' "$work/input.txt"; then
  fail "$state is a Mega-CD state from an older Genesis Plus GX build, which this core can't load: $(grep 'Mega-CD' "$work/input.txt")"
fi
# The core loads a Mega-CD state with a cartridge without an error, reading the CD part as the
# cartridge's (bank mappings into the ROM), and refuses the reverse with no useful reason
if grep -q 'Mega-CD' "$work/input.txt"; then
  $disc || fail "$state is a Mega-CD (Sega CD) state: give the disc's .cue, not a cartridge ROM"
else
  ! $disc || fail "$state is a Mega Drive state, not a Mega-CD one: give the cartridge ROM it was saved with, not a disc"
fi

build=$("$here/build.sh")
core=$(ls "$build"/genesis_plus_gx_libretro.* | head -n 1)

mkdir -p "$work/system" "$work/save"
if [ -n "$bios" ]; then
  # The BIOS under all three names, so it's the one loaded whichever region the core detects
  for region in U E J; do cp "$bios" "$work/system/bios_CD_$region.bin"; done
fi

if ! "$build/gpgx-frame" "$core" "$game" "$state" "$frame" "$work/screenshot.png" "$work/state" \
  "$work/system" "$work/save" >"$work/frame.txt"; then
  echo "$0: the frontend failed" >&2
  exit 1
fi
width=$(sed -n 's/^width=//p' "$work/frame.txt")
height=$(sed -n 's/^height=//p' "$work/frame.txt")

mkdir -p "$out"
if ! racket "$extractor" "$work/state" "$out" >"$work/output.txt" 2>&1; then
  cat "$work/output.txt" >&2
  echo "$0: can't extract the core's state after frame $frame" >&2
  exit 1
fi
cat "$work/output.txt"
cp "$work/screenshot.png" "$out/screenshot.png"
console=Genesis
grep -q 'Mega-CD' "$work/output.txt" && console="Sega CD"
printf 'console=%s\nframe=%s\nwidth=%s\nheight=%s\n' "$console" "$frame" "$width" "$height" >"$out/info.txt"
[ -z "$state_out" ] || cp "$work/state" "$state_out"
echo "Wrote screenshot.png ($width x $height) and info.txt to $out"
