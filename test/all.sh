#!/bin/sh
# Every suite, in one command, reported by part rather than by file.
#
#   sh test/all.sh                  everything that can run here
#   sh test/all.sh --quick          skip the cross-target matrix, which is most of the time
#   sh test/all.sh --no-sandbox     skip the heaps app, which needs HashLink and a checkout
#
# There are three suites and they answer three different questions, which is why one command that
# only ran one of them was never enough:
#
#   targets   does the library BUILD and pass its own tests on each Haxe target
#   modes     does a SCRIPT get the same answer interpreted and compiled, per part of the language
#   host      does a real project's interop hold up, interpreted against compiled
#
# The middle one is the interesting matrix and it is not per target: `hxcpp-cppia` and `hl-bytecode` are two
# ways of running a script, and a part of the language can work in one and not the other on the same
# target. That is what `Table` prints by part at the end.
#
# Exit is non-zero only on an unexpected failure. A target listed in known-failing.txt reports as
# `known-fail` and does not fail the run.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
BIN="$ROOT/bin_test"

QUICK=0
SANDBOX=1

for arg in "$@"; do
	case "$arg" in
		--quick) QUICK=1 ;;
		--no-sandbox) SANDBOX=0 ;;
		*) echo "test/all.sh: no option called '$arg'" >&2; exit 2 ;;
	esac
done

cd "$ROOT"
mkdir -p "$BIN"

failures=0
summary=""

note() {
	summary="$summary
$(printf '  %-22s %s' "$1" "$2")"
}

printf '\n=== targets: the library on each Haxe target ===\n\n'

if [ "$QUICK" = "1" ]; then
	note "targets" "skipped (--quick)"
else
	if sh "$HERE/run.sh" > "$BIN/all-targets.log" 2>&1; then
		note "targets" "$(grep -cE '^\S+ +(ok|built)' "$BIN/all-targets.log" || echo 0) of 10 ok"
	else
		note "targets" "FAILED, see bin_test/all-targets.log"
		failures=$((failures + 1))
	fi

	grep -E '^\S+ +(ok|built|FAIL|known-fail|skipped)' "$BIN/all-targets.log" || true
fi

printf '\n=== modes: one script, every way of running it ===\n\n'

# Collected first, then judged. `conformance.sh` writes one column per mode and decides nothing;
# `Table` is where every judgement lives, so that two columns cannot disagree about what agreement
# means. It prints the by-part grid and writes the page.
if sh "$HERE/lib/conformance.sh" > "$BIN/all-modes.log" 2>&1; then
	grep -E 'rows$' "$BIN/all-modes.log" || true
else
	note "modes" "collection FAILED, see bin_test/all-modes.log"
	failures=$((failures + 1))
fi

# The exit code is `Table`'s and not `grep`'s, which is the whole point of running it separately:
# piping it into a filter would report the filter's success and a table full of misses would read
# as a pass.
if haxe "$HERE/lib/table.hxml" > "$BIN/all-table.log" 2>&1; then
	grep -v '^-- constructs' "$BIN/all-table.log" || true
	note "modes" "no part is wrong"
else
	grep -v '^-- constructs' "$BIN/all-table.log" || true
	note "modes" "SOMETHING IS WRONG, see docs/support-table.md"
	failures=$((failures + 1))
fi

if [ "$SANDBOX" = "1" ]; then
	printf '\n=== host: a real project, interpreted against compiled ===\n\n'

	app="$ROOT/apps/sandbox-heaps/export/hlc/Sandbox.exe"

	if [ ! -x "$app" ]; then
		note "host" "skipped, no build at apps/sandbox-heaps/export/hlc"
		echo "  build it with: cd apps/sandbox-heaps && ./build.sh"
	else
		for project in conform widgets heaps3d; do
			line=$(cd "$(dirname "$app")" && ./Sandbox.exe --conform "$project" 2>/dev/null | grep -E '^== ' || true)
			printf '  %-10s %s\n' "$project" "${line:-did not report}"

			case "$line" in
				*' 0 differ'*) ;;
				'') note "host/$project" "did not report"; failures=$((failures + 1)) ;;
				*) note "host/$project" "DIFFERS"; failures=$((failures + 1)) ;;
			esac
		done

		# Written out rather than as `[ ... ] && note ...`, which under `set -e` ends the run as soon
		# as the test is false, so a single differing project would take the summary with it.
		if [ "$failures" -eq 0 ]; then
			note "host" "nothing differs"
		fi
	fi
fi

printf '\n=== summary ===\n%s\n\n' "$summary"

if [ "$failures" -eq 0 ]; then
	echo "no unexpected failures"
	echo "detail: docs/support-table.md"
	exit 0
fi

echo "$failures unexpected failure(s); logs in bin_test"
exit 1
