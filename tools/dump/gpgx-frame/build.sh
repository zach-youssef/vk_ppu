#!/usr/bin/env bash
# Builds the Genesis Plus GX libretro core at a pinned commit and gpgx-frame.c against it:
#
#   tools/dump/gpgx-frame/build.sh [build-dir]
#
# into build-dir (default: build/gpgx-frame in the repository), which then holds the core
# (genesis_plus_gx_libretro.so, or .dylib on macOS) and the gpgx-frame frontend, and prints the
# build directory. Needs git, make, a C compiler and zlib's headers (on Ubuntu: zlib1g-dev). A
# build at the pinned commit is reused; the source is fetched once (by commit, so the hash pins
# the whole tree) into build-dir/src-<commit>. CC is the compiler for both (default cc). Runs at
# the same time (two dumps, or a dump during the check) take turns on a lock in build-dir, and the
# core and the frontend are replaced by a rename, never rewritten in place, so a run already using
# them is safe.
#
# Genesis Plus GX is GPL and non-commercial: it's built from its own repository and only called,
# never copied into this one. See ../genesis.md.
set -euo pipefail

# libretro/Genesis-Plus-GX, the core RetroArch uses (2026-11-09). Bumping it: change both, rerun
# tools/dump/gpgx-frame/test/check.sh, and check genesis.md's savestate layouts still hold.
GPGX_REPOSITORY=https://github.com/libretro/Genesis-Plus-GX.git
GPGX_COMMIT=b9c2316441978d4015ba30e9a95d9b0e6f8ee981

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
out=${1:-$repo/build/gpgx-frame}
mkdir -p "$out"
out=$(cd "$out" && pwd)
cc=${CC:-cc}

case "$(uname -s)" in
  Darwin) core_name=genesis_plus_gx_libretro.dylib ;;
  *) core_name=genesis_plus_gx_libretro.so ;;
esac
jobs=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)

# The lock: a directory holding its owner's PID. A lock whose owner is gone (killed) is taken over
# by renaming it away, which only one waiter can do, so two waiters can't both take it.
lock=$out/.lock
waiting=false
until mkdir "$lock" 2>/dev/null; do
  owner=$(cat "$lock/pid" 2>/dev/null || true)
  if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null &&
    mv "$lock" "$lock.stale.$$" 2>/dev/null; then
    rm -rf "$lock.stale.$$"
    continue
  fi
  if ! $waiting; then
    echo "$0: waiting for the build lock $lock (remove it if no build is running)" >&2
    waiting=true
  fi
  sleep 1
done
echo $$ >"$lock/pid"
trap 'rm -rf "$lock"' EXIT

src=$out/src-$GPGX_COMMIT
if [ ! -f "$src/.fetched" ]; then
  rm -rf "$src"
  git init -q "$src"
  git -C "$src" fetch -q --depth 1 "$GPGX_REPOSITORY" "$GPGX_COMMIT"
  git -C "$src" checkout -q --detach FETCH_HEAD
  touch "$src/.fetched"
fi

# The core: make keeps it up to date, so a rerun rebuilds nothing. Its compiler warnings go to
# the log, which is shown only if the build fails.
if ! make -C "$src" -f Makefile.libretro -j"$jobs" CC="$cc" >"$out/core-build.log" 2>&1; then
  tail -n 50 "$out/core-build.log" >&2
  echo "$0: the core's build failed; the whole log is $out/core-build.log" >&2
  exit 1
fi
if ! cmp -s "$src/$core_name" "$out/$core_name"; then
  cp "$src/$core_name" "$out/$core_name.new"
  mv -f "$out/$core_name.new" "$out/$core_name"
fi

# The frontend, against the core's own libretro.h
"$cc" -std=gnu99 -O2 -Wall -Wextra -Werror -I"$src/libretro/libretro-common/include" \
  -o "$out/gpgx-frame.new" "$here/gpgx-frame.c" -ldl -lz
mv -f "$out/gpgx-frame.new" "$out/gpgx-frame"

echo "$out"
