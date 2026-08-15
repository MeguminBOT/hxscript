#!/bin/sh
# Builds and runs the HashLink benchmark: a script against the same program compiled by Haxe.
#
#   sh test/bench/hlbench/run.sh
#   SCALE=200000 sh test/bench/hlbench/run.sh
#
# Four columns, from two builds:
#
#   hashlink/vm      the corpus as Haxe, compiled to `.hl`, run by the HashLink VM
#   hashlink/c       the same Haxe, compiled to C and linked as a native binary
#   hxscript hl/c    the corpus as scripts, compiled to HashLink bytecode at run time
#   hxscript interp  the same scripts, walked as a tree
#
# Three of the four come out of the HL/C binary, so the compiled Haxe and the scripts are measured in
# one process by one clock. Only the VM column is a second build, since running on the VM is the
# thing it measures.
#
# The corpus is `test/bench/mbench/ModeCases.hx`, the same one the execution-mode benchmark uses.
# A natively compiled case cannot take its loop count at run time, so `GenNative` writes the Haxe
# half at a fixed scale and the harness refuses to run at any other. Change SCALE and both halves
# are regenerated together.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
BIN=${BIN:-"$ROOT/bin_hlbench"}
OUT="$BIN/results.txt"
GEN="$BIN/gen"
HL=${HLPATH:-/c/hashlink/hashlink-1.16.0-win}

# Must be a multiple of 1000, which is the array length `forArray` walks.
SCALE=${SCALE:-100000}

CP="-cp $ROOT/src -cp $ROOT/test/bench/mbench -cp $HERE -cp $GEN"

mkdir -p "$GEN"

echo "generating the native corpus at n=$SCALE..." >&2
HXS_GEN="$SCALE $GEN/NativeCases.hx" haxe -cp "$ROOT/test/bench/mbench" -cp "$HERE" -main GenNative --interp >&2

# The VM build. Plain Haxe with no library in it: this column is the language on its own, and
# linking the compiler into it would only invite the question of whether that changed the number.
echo "building for the VM..." >&2
rm -rf "$BIN/vm"
mkdir -p "$BIN/vm"
haxe -cp "$ROOT/test/bench/mbench" -cp "$HERE" -cp "$GEN" -D hl-ver=1.16.0 -main HlBench -hl "$BIN/vm/bench.hl" >&2

# The HL/C build, which carries the library because two of its three columns are the library. The
# native column is measured in this same binary rather than in a separate one, so that the floor and
# what sits on it are read off the same build.
#
# `-D hxscript_hl` is also what links HashLink's loader in and produces the binary at all: the VM
# keeps its bytecode loader in `hl.exe` rather than in `libhl`, so the library carries it and the
# setup macro compiles it in. That macro is what a host gets from `-lib hxscript`; named here because
# this builds against the sources rather than against the haxelib, and without it the C is generated
# and nothing links it.
echo "building HL/C..." >&2
rm -rf "$BIN/hlc"
HLPATH="$HL" haxe $CP --macro 'hxscript.setup.Autowire.run()' \
	-D hxscript_hl -D hl-ver=1.16.0 -D no-compilation -main HlBench -hl "$BIN/hlc/main.c" >&2

[ -f "$BIN/hlc/main.exe" ] || { echo "no binary was linked for HL/C" >&2; exit 1; }

# The binary links libhl by path and has to find it again when it runs. `|| true` is not decoration:
# the last name in the list is absent on every platform but one.
for lib in libhl.dll libhl.so libhl.dylib; do
	[ -f "$HL/$lib" ] && cp "$HL/$lib" "$BIN/hlc/" || true
done

: > "$OUT"
# tr -d '\r': the binaries emit CRLF, and a case name carrying a trailing CR matches nothing
CASES=$(cd "$BIN/hlc" && ./main.exe native __list | tr -d '\r')

# Where each column runs, and what runs it.
#   <column>|<directory>|<command>|<mode>
COLUMNS="hashlink/vm|$BIN/vm|$HL/hl bench.hl|native
hashlink/c|$BIN/hlc|./main.exe|native
hxscript-hl/c|$BIN/hlc|./main.exe|hxs-hl
hxscript-interp|$BIN/hlc|./main.exe|hxs-interp"

echo "$COLUMNS" | while IFS='|' read -r col dir cmd mode; do
	[ -d "$dir" ] || continue

	# Getting ready does not scale with the loop count, so it is measured once per column.
	line=$(cd "$dir" && timeout 300 $cmd "$mode" __prepare 2>/dev/null | grep -E '^P\|') || true
	echo "${line:-P|$col|0|crash}" | sed "s#^P|[^|]*|#P|$col|#" >> "$OUT"

	for c in $CASES; do
		line=$(cd "$dir" && timeout 300 $cmd "$mode" "$c" "$SCALE" 2>/dev/null | grep -E '^R\|') || true
		line=${line:-R|$mode|$c|?|$SCALE|crash|-|process died}
		# The column name replaces the mode, since two columns share a mode name across two builds.
		echo "$line" | sed "s#^R|[^|]*|#R|$col|#" >> "$OUT"
	done
	echo "$col done" >&2
done

python "$HERE/collate.py" "$OUT"
