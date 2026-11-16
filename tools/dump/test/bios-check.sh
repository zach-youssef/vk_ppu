#!/bin/sh
# Checks mesen-dump.sh's PC Engine CD input checks and System Card seeding (see ../README.md).
#
#   tools/dump/test/bios-check.sh [work-dir]
#
# Needs no Mesen, no System Card and no disc: it runs the wrapper with a stand-in MESEN that
# records that it ran and checks the seeded Firmware folders, on a made-up .cue and a 256 KB file
# of zeros. The files go to work-dir (default: a new temporary directory, removed on success).
set -eu

here="$(cd "$(dirname "$0")" && pwd)"
dump="$here/../mesen-dump.sh"
if [ $# -ge 1 ]; then
  work=$1
  mkdir -p "$work"
  keep=1
else
  work=$(mktemp -d "${TMPDIR:-/tmp}/mesen-bios-check.XXXXXX")
  keep=0
fi

# The stand-in Mesen: it notes that it ran, checks that both of the wrapper's Mesen homes hold
# the System Card under the name Mesen looks for, and exits with 3 so the wrapper stops there.
cat >"$work/fake-mesen" <<'EOF'
#!/bin/sh
touch "$FAKE_MESEN_RAN"
for dir in "$HOME/.config/Mesen2" "$HOME/Library/Application Support/Mesen2"; do
  if ! cmp -s "$dir/Firmware/syscard3.pce" "$FAKE_MESEN_BIOS"; then
    echo "fake Mesen: $dir/Firmware/syscard3.pce isn't the System Card"
    exit 4
  fi
done
echo "fake Mesen: System Card seeded"
exit 3
EOF
chmod +x "$work/fake-mesen"
export MESEN="$work/fake-mesen" FAKE_MESEN_RAN="$work/ran"

# A disc folder as a ripper leaves it: the cue (with CRLF line ends, a quoted name and an unquoted
# one, both with spaces) and its tracks beside it.
mkdir -p "$work/disc"
printf 'FILE "Game (Japan) (Track 01).bin" BINARY\r\n  TRACK 01 MODE1/2352\r\n    INDEX 01 00:00:00\r\nFILE Game (Japan) (Track 02).bin BINARY\r\n  TRACK 02 AUDIO\r\n    INDEX 01 00:00:00\r\n' \
  >"$work/disc/Game (Japan).cue"
: >"$work/disc/Game (Japan) (Track 01).bin"
: >"$work/disc/Game (Japan) (Track 02).bin"
printf 'FILE "missing.bin" BINARY\n  TRACK 01 MODE1/2352\n' >"$work/disc/missing.cue"
printf 'not a cue sheet\n' >"$work/disc/empty.cue"
: >"$work/hucard.pce"
head -c 262144 /dev/zero >"$work/syscard3.pce"
head -c 262143 /dev/zero >"$work/short.pce"
export FAKE_MESEN_BIOS="$work/syscard3.pce"

# Runs the wrapper with PPU_DUMP_BIOS set to $1 (unset if empty) on the rest of the arguments,
# and checks that it refused with exit code 2 and the expected message before starting Mesen or
# creating the out folder.
must_refuse() {
  expected=$1
  bios=$2
  shift 2
  rm -f "$work/ran"
  rm -rf "$work/out"
  status=0
  if [ -n "$bios" ]; then
    PPU_DUMP_BIOS=$bios "$dump" "$@" 2>"$work/refusal.txt" || status=$?
  else
    (unset PPU_DUMP_BIOS; "$dump" "$@") 2>"$work/refusal.txt" || status=$?
  fi
  if [ "$status" -ne 2 ] || ! grep -qF "$expected" "$work/refusal.txt" || [ -e "$work/ran" ] ||
      [ -e "$work/out" ]; then
    cat "$work/refusal.txt" >&2
    echo "$0: mesen-dump.sh $* (PPU_DUMP_BIOS='$bios') exited with $status; expected 2 and \"$expected\" before Mesen started or the out folder was made" >&2
    exit 1
  fi
}
cue="$work/disc/Game (Japan).cue"
must_refuse "needs PPU_DUMP_BIOS" "" "$cue" "$work/out"
must_refuse "is 262143 bytes" "$work/short.pce" "$cue" "$work/out"
must_refuse "no such file: $work/none.pce" "$work/none.pce" "$cue" "$work/out"
must_refuse "names missing.bin, which isn't in $work/disc" "$work/syscard3.pce" \
  "$work/disc/missing.cue" "$work/out"
must_refuse "names no FILE" "$work/syscard3.pce" "$work/disc/empty.cue" "$work/out"
must_refuse "no such file: $work/disc/none.cue" "$work/syscard3.pce" "$work/disc/none.cue" "$work/out"
must_refuse "only for PC Engine CD games" "$work/syscard3.pce" "$work/hucard.pce" "$work/out"

# With everything in place, the wrapper seeds the card and starts Mesen (the stand-in's exit
# code 3 then makes it fail, with the stand-in's output).
rm -f "$work/ran"
status=0
PPU_DUMP_BIOS="$work/syscard3.pce" "$dump" "$cue" "$work/out" 2>"$work/run.txt" || status=$?
if [ "$status" -ne 1 ] || ! grep -q "^fake Mesen: System Card seeded$" "$work/run.txt" ||
    ! grep -q "Mesen exited with 3$" "$work/run.txt"; then
  cat "$work/run.txt" >&2
  echo "$0: mesen-dump.sh with a System Card and a complete .cue should have seeded the card and started Mesen" >&2
  exit 1
fi

[ $keep = 1 ] || rm -rf "$work"
echo "all System Card checks passed"
