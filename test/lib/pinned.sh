#!/bin/sh
# Runs a command on a subset of the machine's cores, so a build does not take the whole desk with it.
#
#   sh test/lib/pinned.sh sh test/lib/conformance.sh
#   CORES=8-15 sh test/lib/pinned.sh haxe test/cpp/build.hxml
#
# `CORES` is a first-last pair of zero-based processor numbers, default 12-23. The affinity is set on
# the process that is started and every child inherits it, which is what puts the C++ compiler hxcpp
# spawns on the same cores rather than on all of them.
#
# `HXCPP_COMPILE_THREADS` is set to match, because affinity alone does not stop hxcpp asking for one
# compiler per core it can see: it would start twenty-four of them and then queue them onto twelve.
#
# Windows only. Elsewhere this runs the command unchanged, since `taskset` and an affinity mask are
# not the same thing and guessing at one is worse than not pinning.
set -eu

RANGE=${CORES:-12-23}
FIRST=${RANGE%-*}
LAST=${RANGE#*-}

case "$(uname -s 2>/dev/null || echo unknown)" in
	MINGW*|MSYS*|CYGWIN*) ;;
	*) exec "$@" ;;
esac

# The mask is a bit per processor, so cores 12 to 23 are bits 12 to 23 set.
MASK=0
at=$FIRST
while [ "$at" -le "$LAST" ]; do
	MASK=$((MASK | (1 << at)))
	at=$((at + 1))
done

COUNT=$((LAST - FIRST + 1))
export HXCPP_COMPILE_THREADS=${HXCPP_COMPILE_THREADS:-$COUNT}

printf 'pinned to cores %s, %s compile thread(s)\n' "$RANGE" "$HXCPP_COMPILE_THREADS" >&2

# PowerShell rather than `start /affinity`, which takes a program rather than a shell line and loses
# the arguments to any shell given one. Affinity is set on the process just after it starts and every
# child it spawns inherits it, which is what puts hxcpp's compilers on these cores too.
WORK=$(mktemp)
{
	echo '#!/bin/sh'
	echo 'set -eu'
	# A moment before any real work starts, because `Start-Process -PassThru` returns before the
	# affinity is applied and anything the shell spawned in between would have escaped the mask.
	echo 'sleep 0.5'
	echo "cd '$(pwd)'"
	echo "export HXCPP_COMPILE_THREADS='$HXCPP_COMPILE_THREADS'"
	printf '%s\n' "$*"
} > "$WORK"

SHELL_EXE=$(cygpath -w "$(command -v sh)")
WORK_WIN=$(cygpath -w "$WORK")

powershell -NoProfile -ExecutionPolicy Bypass -Command "\$p = Start-Process -FilePath '$SHELL_EXE' -ArgumentList '$WORK_WIN' -PassThru -NoNewWindow; \$p.ProcessorAffinity = [System.IntPtr]$MASK; \$p.WaitForExit(); exit \$p.ExitCode"

CODE=$?
rm -f "$WORK"
exit $CODE
