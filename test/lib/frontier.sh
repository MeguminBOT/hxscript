#!/bin/sh
# Collects the frontier readings, surviving cases that take the process with them.
#
#   sh test/lib/frontier.sh hl     > hl.tsv
#   sh test/lib/frontier.sh cppia  > cppia.tsv
#
# A frontier case can abort rather than throw: a bad constant reaches HashLink's jit as an assert,
# and nothing in Haxe runs after that. So the run is restarted past whatever killed it, and the case
# that did so is recorded as `killed the process`, which is the most important reading about it
# rather than one to lose.
#
# The probe says `#done` on its way out, which is what separates a run that finished from one that
# was killed: without it, no output means either "the first case aborted" or "there was nothing left
# to do", and those want opposite responses.
#
# One tab-separated row per case on stdout: index, label, interpreted, compiled, verdict. Progress
# goes to stderr, so the rows can be redirected somewhere useful.
set -eu

WHICH=${1:-hl}
HL=${HLPATH:-/c/hashlink/hashlink-1.16.0-win}
LIMIT=${LIMIT:-500}

# Run from beside the built program, because that is where each looks for what it needs: HashLink
# finds hxscript.hdll in the working directory, and without it the compiler is simply absent and
# every single case reports as refused, which reads like a result and is not one.
case "$WHICH" in
	hl)
		cd bin/hl
		RUN="$HL/hl frontier.hl --rows"
		;;
	cppia)
		cd bin_test/cppia
		RUN="./FrontierTest.exe --rows"
		;;
	*)
		echo "frontier.sh: no runner called '$WHICH'" >&2
		exit 2
		;;
esac

at=0

while [ "$at" -lt "$LIMIT" ]; do
	out=$($RUN --from "$at" 2>/dev/null || true)

	# Only well-formed rows. A dying runtime prints its own complaint on the way out, and HashLink's
	# jit puts its assert on stdout, so anything that is not `<number><tab>` is noise here.
	rows=$(printf '%s\n' "$out" | grep -E '^[0-9]+	' || true)

	[ -n "$rows" ] && printf '%s\n' "$rows"

	if printf '%s' "$out" | grep -q '^#done'; then
		break
	fi

	if [ -z "$rows" ]; then
		# Nothing came back before it died, so the case being resumed at is the one that aborts.
		printf '%s\tcase %s\t-\t-\tkilled the process\n' "$at" "$at"
		at=$((at + 1))
	else
		# It died after the last row it managed to print, so that next one is the culprit.
		last=$(printf '%s\n' "$rows" | tail -1 | cut -f1)
		culprit=$((last + 1))
		printf '%s\tcase %s\t-\t-\tkilled the process\n' "$culprit" "$culprit"
		at=$((culprit + 1))
	fi

	printf 'resuming at %s\n' "$at" >&2
done
