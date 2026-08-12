#!/bin/sh
# Collects the frontier readings, surviving cases that take the process with them.
#
#   sh test/lib/frontier.sh > cppia.tsv
#
# A frontier case can abort rather than throw, and hxcpp's cppia has taken the process down more than
# once. So the run is restarted past whatever killed it, and the case that did so is recorded as
# `killed the process`, which is the most important reading about it rather than one to lose.
#
# The probe says `#done` on its way out, which is what separates a run that finished from one that
# was killed: without it, no output means either "the first case aborted" or "there was nothing left
# to do", and those want opposite responses.
#
# One tab-separated row per case on stdout: index, label, interpreted, compiled, verdict. Progress
# goes to stderr, so the rows can be redirected somewhere useful.
set -eu

LIMIT=${LIMIT:-500}

cd bin_test/cppia
RUN="./FrontierTest.exe --rows"

at=0

while [ "$at" -lt "$LIMIT" ]; do
	out=$($RUN --from "$at" 2>/dev/null || true)

	# Only well-formed rows. A dying runtime prints its own complaint on the way out, so anything that
	# is not `<number><tab>` is noise here.
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
