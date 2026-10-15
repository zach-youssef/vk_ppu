#!/bin/bash
# Captures each game's frames (see PpuSession::kCaptureFrames) and compares them with the approved
# screenshots in tests/approved/<game>/. Run from the repository root via `make test`.
#     run_screenshot_tests.sh <compare tool> <received directory> <game>...
set -u
compare=$1
received_root=$2
shift 2

status=0
for game in "$@"; do
    received="$received_root/$game"
    approved="tests/approved/$game"
    rm -rf "$received"
    if ! "./$game/ppu" --capture "$received"; then
        echo "FAIL $game: capture failed" >&2
        status=1
        continue
    fi
    if ! ls "$approved"/*.png > /dev/null 2>&1; then
        echo "FAIL $game: no approved screenshots in $approved (make approve-screenshots)" >&2
        status=1
        continue
    fi
    for image in "$received"/*.png; do
        [ -e "$approved/$(basename "$image")" ] || { echo "FAIL $game: $image has no approved version" >&2; status=1; }
    done
    for image in "$approved"/*.png; do
        name=$(basename "$image")
        if [ ! -e "$received/$name" ]; then
            echo "FAIL $game: frame $name wasn't captured" >&2
            status=1
        elif "$compare" "$image" "$received/$name"; then
            echo "ok   $game frame ${name%.png}"
        else
            echo "FAIL $game frame ${name%.png}" >&2
            status=1
        fi
    done
done
exit $status
