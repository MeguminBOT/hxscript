#!/bin/sh
# Checks every encoder in src/hxscript/hl/native/arm64/a64.h against a real assembler.
#
#   sh test/hl/native/a64/run.sh
#
# Run from the repository root. Needs no ARM machine and runs nothing it built for one: the encoder
# is arithmetic that produces instruction words, so the words can be produced here and compared
# against what clang assembles the same mnemonics into.
#
# That comparison is the whole test. An encoder checked against a disassembler agrees with whatever
# it already believed; checked against an assembler, it agrees with the architecture.
set -e

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../../.." && pwd)
NATIVE="$ROOT/src/hxscript/hl/native/arm64"
OUT="$ROOT/bin_test/a64"

CC=${CC:-}
if [ -z "$CC" ]; then
	for c in clang gcc cc; do
		if command -v "$c" >/dev/null 2>&1; then CC=$c; break; fi
	done
fi

[ -n "$CC" ] || { echo "no C compiler found: set CC" >&2; exit 1; }

for tool in clang llvm-objcopy; do
	command -v "$tool" >/dev/null 2>&1 || { echo "$tool is needed to assemble the reference" >&2; exit 1; }
done

mkdir -p "$OUT"

$CC -O2 -I "$NATIVE" -I "$HERE" -o "$OUT/probe" "$HERE/probe.c"

"$OUT/probe" > "$OUT/ours.txt"
"$OUT/probe" asm > "$OUT/ref.s"

clang --target=aarch64-linux-gnu -c "$OUT/ref.s" -o "$OUT/ref.o"
llvm-objcopy -O binary --only-section=.text "$OUT/ref.o" "$OUT/ref.bin"

# od reads four byte units in the host's byte order, which on any machine this runs on is the same
# order the object file is written in, so a word here is the instruction word.
od -An -tx4 -v "$OUT/ref.bin" | tr -s ' ' '\n' | grep -v '^$' > "$OUT/theirs.txt"

awk '
	NR == FNR { ref[FNR] = $1; refs = FNR; next }
	{
		n = FNR
		mine = $1
		text = $0
		sub(/^[^\t]*\t/, "", text)
		if( ref[FNR] != mine ) {
			bad++
			printf "  %-34s assembles to %s, encoder gave %s\n", text, ref[FNR], mine
		}
	}
	END {
		if( refs != n ) {
			printf "== the two lists are different lengths: %d assembled, %d encoded ==\n", refs, n
			exit 1
		}
		if( bad ) {
			printf "== %d passed, %d failed ==\n", n - bad, bad
			exit 1
		}
		printf "== %d passed, 0 failed ==\n", n
	}
' "$OUT/theirs.txt" "$OUT/ours.txt"
