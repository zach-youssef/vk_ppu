#!/bin/bash
# Captures each game's frames headless, with validation, and compares them with the approved
# screenshots in tests/approved/<game>/. A game with an emulator's reference,
# tests/reference/<game>.png, also has its frame 1 compared with it, at the tolerance in
# tests/reference/<game>.tolerance (an integer from 0 to 255, the largest channel difference
# allowed; 0, pixel-exact, without the file). Run from the repository root via `make test` (native,
# the programs in build/<game>) or `make test-web` (web, the programs in build/web/<game>, under
# Node).
#     run_screenshot_tests.sh <compare tool> <received directory> <frames, e.g. 1,2,60> native|web <game>...
set -u
compare=$1
received_root=$2
frames=$3
kind=$4
shift 4

status=0
for game in "$@"; do
    received="$received_root/$game"
    approved="tests/approved/$game"
    rm -rf "$received"
    if [ "$kind" = web ]; then
        program=(node "build/web/$game/$game.zgal.main.js")
    else
        program=("build/$game/$game")
    fi
    if ! "${program[@]}" --capture-frames "$frames" --capture "$received" --validation; then
        echo "FAIL $game: capture failed" >&2
        status=1
        continue
    fi
    reference="tests/reference/$game.png"
    if [ -e "$reference" ]; then
        tolerance_file="tests/reference/$game.tolerance"
        tolerance=0
        [ -e "$tolerance_file" ] && tolerance=$(tr -d '[:space:]' < "$tolerance_file")
        if ! [[ "$tolerance" =~ ^[0-9]{1,3}$ ]] || [ $((10#$tolerance)) -gt 255 ]; then
            echo "FAIL $game: $tolerance_file isn't an integer from 0 to 255" >&2
            status=1
        elif [ ! -e "$received/1.png" ]; then
            echo "FAIL $game: frame 1 wasn't captured, so it can't be compared with $reference" >&2
            status=1
        else
            tolerance=$((10#$tolerance))
            # A copy of frame 1 in its own directory, so the comparer's diff image doesn't overwrite
            # the approved comparison's and make approve-screenshots doesn't pick it up
            mkdir -p "$received/reference"
            cp "$received/1.png" "$received/reference/1.png"
            if "$compare" "$reference" "$received/reference/1.png" "$tolerance"; then
                echo "ok   $game frame 1 against $reference (tolerance $tolerance)"
            else
                echo "FAIL $game frame 1 against $reference (tolerance $tolerance)" >&2
                status=1
            fi
        fi
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
