#!/bin/sh
# Builds and runs the cross-library benchmark, one process per case.
#
#   LIBS=/path/to/checkouts sh test/xbench/run.sh
#
# `LIBS` must contain checkouts named: insanity, hscript, improved, iris, rulescript,
# hscript-rs (an hscript old enough for RuleScript; see docs/benchmarks.md). Anything missing is
# skipped rather than failing the run.
#
# One process per case on purpose: some libraries hang or crash on some inputs, and a single-process
# run would lose every case after the first one that dies.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
LIBS=${LIBS:-"$ROOT/../xbench-libs"}
BIN=${BIN:-"$ROOT/bin_xbench"}
OUT="$BIN/results.txt"

mkdir -p "$BIN"

# Dead code elimination, defaulted OFF. That is a correctness setting here rather than a tuning one:
# under hxcpp's default `-dce std` the compiler eliminates `IntIterator.hasNext`/`next`, because every
# call site inlines them and nothing references them statically, so an interpreter reaching them by
# reflection finds a null field. It made `for (i in 0...n)` look like a defect in four of the six
# libraries when it is a property of how the HOST was built. See docs/benchmarks.md.
DCE=${DCE:-no}

# The old binary goes BEFORE the build does, so a build that fails cannot leave one behind.
#
# It has. A run whose RuleScript build failed reused the binaries from a run ten days earlier: they
# answered every case the corpus held then, and reported the ten added since as `crash`. Those had
# not crashed, and that binary had never heard of them. A stale column is worse than a missing one,
# because the table reports it as collected.
build() { # name, classpath, main, [extra hxml]
  rm -rf "$BIN/$1"
  [ -d "$2" ] || { echo "skip $1 (no $2)" >&2; return; }
  haxe -cp "$HERE" -cp "$2" ${4:+"$4"} -dce "$DCE" -main "$3" -cpp "$BIN/$1" >"$BIN/$1.build.log" 2>&1 \
    || { echo "skip $1 (build failed, see bin_xbench/$1.build.log)" >&2; return; }
  echo "$1"
}

echo "building..." >&2
build hxscript "$ROOT/src" RunHxScript >/dev/null
# Its own runner: hscript-insanity is `package insanity`, so one runner cannot import both.
build insanity "$LIBS/insanity" RunInsanity >/dev/null
build hscript "$LIBS/hscript" RunHscript >/dev/null
build improved "$LIBS/improved" RunHscript >/dev/null
build iris "$LIBS/iris" RunIris >/dev/null
# The same libraries again with position tracking on, which is what hxScript always does. Without
# it they record no source positions at all, so the plain rows are not a like-for-like comparison.
build hscript-pos "$LIBS/hscript" RunHscript "$HERE/hscript-pos.hxml" >/dev/null
build improved-pos "$LIBS/improved" RunHscript "$HERE/hscript-pos.hxml" >/dev/null
build iris-pos "$LIBS/iris" RunIris "$HERE/hscript-pos.hxml" >/dev/null
# RuleScript needs its own macro params on top, and like every other hscript-derived library it is
# built BOTH ways. Building it only without positions dropped it out of the like-for-like comparison
# entirely, since the collator reads a position-less build as the no-pos column.
if [ -d "$LIBS/rulescript" ] && [ -d "$LIBS/hscript-rs" ]; then
  rm -rf "$BIN/rulescript" "$BIN/rulescript-pos"
  haxe -cp "$HERE" -cp "$LIBS/rulescript" -cp "$LIBS/hscript-rs" "$HERE/rulescript-params.hxml" \
    -dce "$DCE" -main RunRuleScript -cpp "$BIN/rulescript" >"$BIN/rulescript.build.log" 2>&1 \
    || echo "skip rulescript (see bin_xbench/rulescript.build.log)" >&2
  haxe -cp "$HERE" -cp "$LIBS/rulescript" -cp "$LIBS/hscript-rs" "$HERE/rulescript-params.hxml" \
    "$HERE/hscript-pos.hxml" -dce "$DCE" -main RunRuleScript -cpp "$BIN/rulescript-pos" >"$BIN/rulescript-pos.build.log" 2>&1 \
    || echo "skip rulescript-pos (see bin_xbench/rulescript-pos.build.log)" >&2
fi

: > "$OUT"
# tr -d '\r': the runners emit CRLF, and a case name carrying a trailing CR matches nothing
CASES=$("$BIN/hxscript/RunHxScript.exe" hxscript __list | tr -d '\r')

# Scales the whole corpus is run at. Must be multiples of 1000, which is the array length `forArray`
# walks.
#
# One scale by default. Three were used to establish that the ranking is a property of the
# interpreters rather than a warm-up or fixed-setup artefact; that held, moving by at most a few
# percent across a 20x change, so paying three times the wall time to re-establish it on every run is
# not worth it. Pass SCALES to check it again after a change that could plausibly disturb it.
SCALES=${SCALES:-"100000"}

for entry in "hxscript:$BIN/hxscript/RunHxScript.exe" \
             "insanity:$BIN/insanity/RunInsanity.exe" \
             "hscript-pos:$BIN/hscript-pos/RunHscript.exe" \
             "hscript:$BIN/hscript/RunHscript.exe" \
             "hscript-improved-pos:$BIN/improved-pos/RunHscript.exe" \
             "hscript-improved:$BIN/improved/RunHscript.exe" \
             "hscript-iris-pos:$BIN/iris-pos/RunIris.exe" \
             "hscript-iris:$BIN/iris/RunIris.exe" \
             "rulescript-pos:$BIN/rulescript-pos/RunRuleScript.exe" \
             "rulescript:$BIN/rulescript/RunRuleScript.exe"; do
  lib=${entry%%:*}
  exe=${entry#*:}
  [ -x "$exe" ] || continue
  # Parse throughput does not scale with the loop count, so it is measured once per library.
  line=$(timeout 300 "$exe" "$lib" __parse 2>/dev/null | grep -E '^P\|') || true
  echo "${line:-P|$lib|0|crash}" >> "$OUT"
  for n in $SCALES; do
    for c in $CASES; do
      line=$(timeout 300 "$exe" "$lib" "$c" "$n" 2>/dev/null | grep -E '^R\|') || true
      echo "${line:-R|$lib|$c|?|$n|crash|-|process died}" >> "$OUT"
    done
    echo "$lib @ $n done" >&2
  done
done

python "$HERE/collate.py" "$OUT"
