#!/bin/sh
# Builds and runs the execution-mode benchmark, one process per case.
#
#   sh test/mbench/run.sh
#
# Three modes out of one binary: interpreted, compiled to cppia, and cppia with the JIT on. The JIT
# is a process-wide switch, so it cannot share a process with the mode it is measured against, and
# one process per case was already the rule here for the same reason the cross-library suite has it.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
BIN=${BIN:-"$ROOT/bin_mbench"}
OUT="$BIN/results.txt"
EXE="$BIN/MBench.exe"

# Dead code elimination, defaulted OFF, and for two reasons that both matter. `-D scriptable` needs
# it, because cppia resolves the host's classes by name at load time and DCE removes what nothing
# references statically. It is also what the cross-library suite is built with, so the two documents
# describe the same build. See docs/benchmarks.md.
DCE=${DCE:-no}

# Scales the corpus runs at. Must be multiples of 1000, which is the array length `forArray` walks.
SCALES=${SCALES:-"100000"}

# hxcpp compiles one translation unit at a time unless told otherwise, and `-D scriptable -dce no`
# means compiling the whole standard library rather than the part this program reaches. Left at the
# default that is a quarter-hour build for a benchmark that runs in a couple of minutes.
# Eight rather than every core on purpose: this is often built while something else is running,
# and a build that takes the whole machine makes that something else stutter.
THREADS=${HXCPP_COMPILE_THREADS:-8}
export HXCPP_COMPILE_THREADS="$THREADS"

mkdir -p "$BIN"

echo "building on $THREADS threads..." >&2
haxe -cp "$ROOT/src" -cp "$HERE" -main MBench -cpp "$BIN" \
  -D scriptable -D hxscript_cppia -dce "$DCE" -D HXCPP_STACK_LINE -D HXCPP_STACK_TRACE >/dev/null

: > "$OUT"
# tr -d '\r': the binary emits CRLF, and a case name carrying a trailing CR matches nothing
CASES=$("$EXE" interp __list | tr -d '\r')

for mode in interp cppia jit; do
  # What getting ready costs does not scale with the loop count, so it is measured once per mode.
  line=$(timeout 300 "$EXE" "$mode" __prepare 2>/dev/null | grep -E '^P\|') || true
  echo "${line:-P|$mode|0|crash}" >> "$OUT"

  for n in $SCALES; do
    for c in $CASES; do
      line=$(timeout 300 "$EXE" "$mode" "$c" "$n" 2>/dev/null | grep -E '^R\|') || true
      echo "${line:-R|$mode|$c|?|$n|crash|-|process died}" >> "$OUT"
    done
    echo "$mode @ $n done" >&2
  done
done

python "$HERE/collate.py" "$OUT"
