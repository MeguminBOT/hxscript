#!/bin/sh
# Builds, and where possible runs, the test suite on every target.
#
#   sh test/run.sh              every target
#   sh test/run.sh cpp js       just those
#
# Exits non-zero only on an UNEXPECTED failure. A target listed in known-failing.txt is reported as
# `known-fail` and does not fail the run, so this can be wired to CI while those five are still open.
#
# Generation is real output rather than `--no-output`, and that is not incidental: the js and lua
# failures are generator-stage errors that `--no-output` does not reach. A matrix that skipped
# generation would report all nine green while four of them could not build.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
BIN="$ROOT/bin_test"
KNOWN="$HERE/known-failing.txt"

THREADS=${HXCPP_COMPILE_THREADS:-8}
export HXCPP_COMPILE_THREADS="$THREADS"

ALL="eval cpp js java neko python lua php hl"
TARGETS=${*:-$ALL}

mkdir -p "$BIN"

# Whether a target has a runtime here. The rest are built and not run, which still catches every
# compile and generator error, and is the entire failure mode this suite exists for.
#
# `hl` runs when the HashLink VM is on PATH. It is worth putting there: the target had nine failures
# and fourteen gaps that only a real run could show, all of them one runtime cast.
runs() {
  case "$1" in
    eval|cpp) return 0 ;;
    neko) command -v neko >/dev/null 2>&1 ;;
    python) command -v python >/dev/null 2>&1 ;;
    hl) command -v hl >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

# The command that runs a built target, empty when there is nothing to run.
runner() {
  case "$1" in
    cpp) echo "$BIN/cpp/common/AllCommon.exe" ;;
    neko) echo "neko $BIN/neko/all.n" ;;
    python) echo "python $BIN/python/all.py" ;;
    hl) echo "hl $BIN/hl/all.hl" ;;
    *) echo "" ;;
  esac
}

known() {
  [ -f "$KNOWN" ] || return 1
  grep -q "^$1|" "$KNOWN"
}

unexpected=0
results=""

for t in $TARGETS; do
  if [ ! -f "$HERE/$t/build.hxml" ]; then
    results="$results\n$(printf '%-8s %s' "$t" 'skipped   no build.hxml')"
    continue
  fi

  log="$BIN/$t.log"
  if ! haxe "$HERE/$t/build.hxml" >"$log" 2>&1; then
    first=$(grep -v '^$' "$log" | head -1 | cut -c1-84)
    if known "$t"; then
      results="$results\n$(printf '%-8s %s' "$t" "known-fail  $first")"
    else
      results="$results\n$(printf '%-8s %s' "$t" "FAIL        $first")"
      unexpected=$((unexpected + 1))
    fi
    continue
  fi

  # eval runs during compilation, so the build output already holds its summary.
  if [ "$t" = "eval" ]; then
    line=$(grep -E 'passed, [0-9]+ failed' "$log" | tail -1)
    case "$line" in
      *' 0 failed'*) results="$results\n$(printf '%-8s %s' "$t" "ok          $line")" ;;
      '') results="$results\n$(printf '%-8s %s' "$t" 'FAIL        no summary')"; unexpected=$((unexpected + 1)) ;;
      *) results="$results\n$(printf '%-8s %s' "$t" "FAIL        $line")"; unexpected=$((unexpected + 1)) ;;
    esac
    continue
  fi

  if ! runs "$t"; then
    results="$results\n$(printf '%-8s %s' "$t" 'built       no runtime here, generation only')"
    continue
  fi

  out="$BIN/$t.out"
  if $(runner "$t") >"$out" 2>&1; then
    line=$(grep -E 'passed, [0-9]+ failed' "$out" | tail -1)
    results="$results\n$(printf '%-8s %s' "$t" "ok          ${line:-ran}")"
  else
    line=$(grep -E 'passed, [0-9]+ failed' "$out" | tail -1)
    if known "$t"; then
      results="$results\n$(printf '%-8s %s' "$t" "known-fail  ${line:-non-zero exit}")"
    else
      results="$results\n$(printf '%-8s %s' "$t" "FAIL        ${line:-non-zero exit}")"
      unexpected=$((unexpected + 1))
    fi
  fi
done

# The cppia suite, hxcpp only, and only when cpp was asked for.
case " $TARGETS " in
  *" cpp "*)
    if [ -x "$BIN/cpp/cppia/AllCpp.exe" ]; then
      out="$BIN/cppia.out"
      if "$BIN/cpp/cppia/AllCpp.exe" >"$out" 2>&1; then
        line=$(grep -E 'passed, [0-9]+ failed' "$out" | tail -1)
        results="$results\n$(printf '%-8s %s' 'cppia' "ok          ${line:-ran}")"
      else
        line=$(grep -E 'passed, [0-9]+ failed' "$out" | tail -1)
        results="$results\n$(printf '%-8s %s' 'cppia' "FAIL        ${line:-non-zero exit}")"
        unexpected=$((unexpected + 1))
      fi
    fi
    ;;
esac

printf '%b\n' "$results"
echo ""
if [ "$unexpected" -eq 0 ]; then
  echo "no unexpected failures"
else
  echo "$unexpected unexpected failure(s); logs in $BIN"
fi
exit $([ "$unexpected" -eq 0 ] && echo 0 || echo 1)
