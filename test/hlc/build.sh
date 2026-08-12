#!/bin/sh
# Builds and runs the HL/C suite: native binaries that compile and run scripts with no VM under them.
#
#   sh test/hlc/build.sh                 all of them
#   sh test/hlc/build.sh callback        one of them
#   sh test/hlc/build.sh --no-jit basic  the same binary built without the loader
#
# HL/C is the other way to ship HashLink, and the one a game with mod support is most likely to be
# built as: Haxe becomes C, the C becomes an ordinary native binary, and there is no VM process and
# no bytecode file. Every other probe in this repository runs on HL/JIT, where the whole program is
# bytecode and the extension is loaded by name when the module starts. These answer the separate
# question of whether the same thing works when none of that is true.
#
# The native build goes through the library's own tooling rather than a compile line kept here, so
# what is tested is what is shipped. HL_SRC and HLPATH are passed through to it.
#
#   basic      a script compiles, answers, and keeps answering
#   callback   the host's own dynamic calls survive the jit taking over hl_setup
#   throw      exceptions cross between compiled and generated code in both directions
#   corpus     the 168 shared cases, the same ones HL/JIT and cppia answer
set -e

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)

OUT=${OUT:-bin/hlc}
JIT=1
WANTED=

for arg in "$@"; do
	case "$arg" in
		--no-jit) JIT=0 ;;
		--help|-h) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		-*) echo "unknown argument: $arg" >&2; exit 1 ;;
		*) WANTED="$WANTED $arg" ;;
	esac
done

[ -n "$WANTED" ] || WANTED="basic callback throw corpus"

cd "$ROOT"

# Worked out the same way the tooling works it out, because the binary links libhl by path and then
# has to find it again when it runs.
RUNTIME=${HLPATH:-}
if [ -z "$RUNTIME" ]; then
	found=$(command -v hl 2>/dev/null || true)
	[ -n "$found" ] && RUNTIME=$(cd "$(dirname "$found")" && pwd)
fi
if [ -z "$RUNTIME" ]; then
	for guess in /c/hashlink /c/HaxeToolkit/hl /usr/local/lib /usr/lib; do
		[ -f "$guess/libhl.dll" ] || [ -f "$guess/libhl.so" ] || [ -f "$guess/libhl.dylib" ] || continue
		RUNTIME=$guess
		break
	done
fi

main_for() {
	case "$1" in
		basic) echo "HlcProbe" ;;
		callback) echo "CallbackProbe" ;;
		throw) echo "ThrowProbe" ;;
		corpus) echo "CorpusProbe" ;;
		*) echo "" ;;
	esac
}

paths_for() {
	case "$1" in
		corpus) echo "-cp test/hl/loader -cp test/lib" ;;
		*) echo "-cp test/hlc" ;;
	esac
}

failed=0

for name in $WANTED; do
	class=$(main_for "$name")
	if [ -z "$class" ]; then
		echo "no probe called '$name'" >&2
		exit 1
	fi

	dir="$OUT/$name"
	rm -rf "$dir"

	echo ""
	echo "=== $name ==="
	echo "generating C ..."

	# Haxe reports a missing `hashlink` haxelib after writing the C, because that library is what it
	# would have used to drive the native build. This drives it below instead, so the C is what
	# matters and the complaint is not one.
	haxe -cp src $(paths_for "$name") -D hxscript_hl -D hxscript_no_hdll \
		--macro "hxscript.macro.Keep.run()" -main "$class" -hl "$dir/main.c" 2>&1 \
		| grep -v "Library hashlink is not installed\|^Error: Build failed" || true

	[ -f "$dir/main.c" ] || { echo "no C was generated" >&2; exit 1; }

	echo "compiling ..."

	if [ "$JIT" = "1" ]; then
		sh src/hxscript/hl/hlc.sh "$dir" --out "$dir/$name.exe" >/dev/null
	else
		sh src/hxscript/hl/hlc.sh "$dir" --out "$dir/$name.exe" --no-jit >/dev/null
	fi

	[ -f "$dir/$name.exe" ] || { echo "nothing was linked" >&2; exit 1; }

	# The binary links libhl by path, and then has to find it again when it runs.
	for lib in libhl.dll libhl.so libhl.dylib; do
		[ -f "$RUNTIME/$lib" ] && cp "$RUNTIME/$lib" "$dir/"
	done

	echo "running ..."
	if ( cd "$dir" && "./$name.exe" ); then
		:
	else
		failed=$((failed + 1))
	fi
done

echo ""
if [ "$failed" = "0" ]; then
	echo "== every HL/C probe passed =="
else
	echo "== $failed HL/C probe(s) failed ==" >&2
	exit 1
fi
