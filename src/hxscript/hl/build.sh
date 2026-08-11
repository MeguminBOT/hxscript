#!/bin/sh
# Builds hxscript.hdll, the extension that lets a HashLink host load emitted bytecode.
#
#   HL_SRC=/c/hashlink/src-1.16 HL_BIN=/c/hashlink/hashlink-1.16.0-win \
#     sh src/hxscript/hl/build.sh
#
# HL_SRC is a hashlink source tree whose tag MATCHES the VM in HL_BIN. The struct layouts in hl.h
# are shared with the running libhl, so a mismatched pair links and then misbehaves.
#
# There is no cmake or make required: the file count is small enough to drive the compiler directly,
# and that keeps the build honest about exactly which of hashlink's sources are carried.
#
# Run it from the repository root, or from an install of the library with a `-D hxscript_hl` build.
set -e

HERE=$(cd "$(dirname "$0")" && pwd)

HL_SRC=${HL_SRC:-/c/hashlink/src-1.16}
HL_BIN=${HL_BIN:-/c/hashlink/hashlink-1.16.0-win}
CC=${CC:-x86_64-w64-mingw32-gcc}
OUT=${OUT:-bin/hl}

[ -f "$HL_SRC/src/hl.h" ] || { echo "no hashlink sources at $HL_SRC" >&2; exit 1; }
[ -f "$HL_BIN/libhl.dll" ] || { echo "no HashLink VM at $HL_BIN" >&2; exit 1; }

mkdir -p "$OUT"

# hl.h works out HL_64, HL_WIN and HL_THREADS from the compiler's own defines, so passing them here
# only produces redefinition warnings and risks disagreeing with what libhl was built with.
FLAGS="-O2 -shared -m64 -I$HL_SRC/src -I$HERE"

# hashlink's own loader, carried rather than reimplemented. gc.c and allocator.c are NOT here: they
# are already in the running libhl and are exported, so a second copy would give this module its own
# heap and its objects would be invisible to the host's collector.
LOADER="$HL_SRC/src/code.c $HL_SRC/src/module.c $HL_SRC/src/jit.c"

echo "building $OUT/hxscript.hdll"
$CC $FLAGS -o "$OUT/hxscript.hdll" "$HERE/hxscript.c" $LOADER "$HL_BIN/libhl.dll"

echo "ok"

# Passing `test` also proves it works: a host program loads a SEPARATE module that Haxe produced,
# jits it and calls its entry point, all inside one stock VM. The probe lives in the test tree
# because it is not part of the library.
if [ "$1" = "test" ]; then
	haxe -cp test/hl/loader -main Guest -hl "$OUT/guest.hl"
	haxe -cp test/hl/loader -main LoadProbe -hl "$OUT/loadprobe.hl"
	( cd "$OUT" && "$HL_BIN/hl.exe" loadprobe.hl guest.hl )
fi
