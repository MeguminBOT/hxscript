#!/bin/sh
# Builds and runs the HL/C probe: a native binary that compiles and runs a script at runtime.
#
#   HL_SRC=/c/hashlink/src-1.16 HL_BIN=/c/hashlink/hashlink-1.16.0-win \
#     sh test/hlc/build.sh
#
# HL/C is the other way to ship HashLink, and the one a game with mod support is most likely to be
# built as: Haxe becomes C, the C becomes an ordinary native binary, and there is no VM process and
# no bytecode file. This answers whether such a binary can still be a host for compiled scripts.
#
# **The extension is compiled in rather than loaded.** An HL/C program resolves its natives at link
# time, and the header Haxe generates for them declares exactly the symbols `hxscript.c` already
# defines, so the same file serves both ways of shipping with nothing added to it:
#
#   HL_API hxs_module* hxscript_load(vbyte*,int);
#
# What does not carry over is the `?` that makes the extension optional on HL/JIT. A dlopened
# library can be absent and leave its natives as stubs; a linked one either resolves or the link
# fails. So an HL/C host decides at build time whether it can compile scripts, where a HL/JIT host
# decides at startup.
set -e

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)

HL_SRC=${HL_SRC:-/c/hashlink/src-1.16}
HL_BIN=${HL_BIN:-/c/hashlink/hashlink-1.16.0-win}
CC=${CC:-x86_64-w64-mingw32-gcc}
OUT=${OUT:-bin/hlc}

[ -f "$HL_SRC/src/hl.h" ] || { echo "no hashlink sources at $HL_SRC" >&2; exit 1; }
[ -f "$HL_BIN/libhl.dll" ] || { echo "no HashLink at $HL_BIN" >&2; exit 1; }

cd "$ROOT"
rm -rf "$OUT" 2>/dev/null || true

echo "generating C ..."
# Haxe reports a missing `hashlink` haxelib after writing the C, because that library is what it
# would have used to drive the native build. This drives it here instead, so the C is what matters.
haxe -cp src -cp test/hlc -D hxscript_hl -D hxscript_no_hdll \
	--macro "hxscript.macro.Keep.run()" -main HlcProbe -hl "$OUT/main.c" || true

[ -f "$OUT/main.c" ] || { echo "no C was generated" >&2; exit 1; }

echo "compiling ..."
# -municode because hlc_main.c's entry point is wmain. hashlink's own loader is carried for the same
# reason the .hdll carries it: hl_code_read and hl_module_init are not exported from libhl.
$CC -O2 -municode \
	-I "$OUT" -I "$HL_SRC/src" -I src/hxscript/hl \
	-o "$OUT/hlcprobe.exe" \
	"$OUT/main.c" src/hxscript/hl/hxscript.c \
	"$HL_SRC/src/code.c" "$HL_SRC/src/module.c" "$HL_SRC/src/jit.c" \
	"$HL_BIN/libhl.dll" -ldbghelp -luser32 -lkernel32 2>&1 \
	| grep -vE "LNK4217|trigraph|warning generated|^ *[0-9]+ \||^ *\||In file included" || true

[ -f "$OUT/hlcprobe.exe" ] || { echo "nothing was linked" >&2; exit 1; }

cp "$HL_BIN/libhl.dll" "$OUT/"

echo "running ..."
( cd "$OUT" && ./hlcprobe.exe )
