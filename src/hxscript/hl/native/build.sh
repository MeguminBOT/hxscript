#!/bin/sh
# Builds hxScript's native module: as hxscript.hdll for the VM, or into an HL/C program.
#
#   sh build.sh                    build hxscript.hdll next to this script
#   sh build.sh --out path.hdll    build it somewhere else
#   sh build.sh --hlc DIR          build the HL/C Haxe wrote in DIR into a native binary
#   sh build.sh --hl DIR           the HashLink installation to build against
#   sh build.sh --src DIR          a hashlink source tree, instead of the carried loader
#   sh build.sh --no-jit           leave the loader out, so every script is interpreted
#   sh build.sh --flags            print what a build of your own has to add, and build nothing
#
# The two modes are the same C reaching the same process by different routes. On the VM it is a
# library loaded by name beside the program; in an HL/C build there is no library and no VM, and it
# is compiled and linked into the executable, which is the only way to have it there at all.
#
# This is the by hand path. A build that has -lib hxscript and -D hxscript_hl does this for itself.
#
# What it needs is a HashLink installation, for hl.h and for libhl to link against. The binary
# distributions ship both. It does not need a hashlink source tree: code.c, module.c and jit.c are
# carried in vendor/, and --src is for building against a hashlink those do not match.
set -e

HERE=$(cd "$(dirname "$0")" && pwd)
VENDOR="$HERE/vendor"

HL=${HLPATH:-}
SRC=${HL_SRC:-}
OUT=
HLC=
JIT=1
FLAGS_ONLY=0

while [ $# -gt 0 ]; do
	case "$1" in
		--out) OUT=$2; shift 2 ;;
		--hlc) HLC=$2; shift 2 ;;
		--hl) HL=$2; shift 2 ;;
		--src) SRC=$2; shift 2 ;;
		--no-jit) JIT=0; shift ;;
		--flags) FLAGS_ONLY=1; shift ;;
		--help|-h) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) echo "unknown argument: $1" >&2; exit 2 ;;
	esac
done

die() { printf '%s\n' "$*" >&2; exit 1; }
note() { [ "$FLAGS_ONLY" = "1" ] || printf '%s\n' "$*"; }

case "$(uname -s 2>/dev/null || echo unknown)" in
	MINGW*|MSYS*|CYGWIN*) WINDOWS=1; EXT=hdll ;;
	Darwin) WINDOWS=0; EXT=hdll ;;
	*) WINDOWS=0; EXT=hdll ;;
esac

# --- the HashLink to build against ----------------------------------------------------------------
#
# hl.h has to be the one the running libhl was built from, so it is taken from an installation rather
# than carried. Everything else the loader needs is internal to hashlink and is not shipped, which is
# what vendor/ is for.

if [ -z "$HL" ]; then
	for guess in /c/hashlink/* /usr/local /usr /opt/hashlink "$HOME/hashlink"; do
		if [ -f "$guess/include/hl.h" ] || [ -f "$guess/hl.h" ]; then HL=$guess; break; fi
	done
fi

[ -n "$HL" ] || die "no HashLink installation found: pass --hl DIR or set HLPATH"

if [ -f "$HL/include/hl.h" ]; then
	INC="$HL/include"
elif [ -f "$HL/hl.h" ]; then
	INC="$HL"
else
	die "no hl.h under $HL"
fi

# --- the loader sources ---------------------------------------------------------------------------

LOADER_INC="$VENDOR/hl116"
ANY_VERSION=

if [ -n "$SRC" ]; then
	[ -f "$SRC/src/jit.c" ] || die "no hashlink source tree at $SRC"
	LOADER_DIR="$SRC/src"
	LOADER_INC="$SRC/src"
	# The headers and the loader come from one tree here, so the version pairing this checks is not
	# a question that can go wrong.
	ANY_VERSION="-DHXS_HL_ANY_VERSION"
	note "loader: $SRC (given)"
else
	LOADER_DIR="$VENDOR/hl116"
	note "loader: carried hashlink 1.16"
fi

LOADER="$LOADER_DIR/code.c $LOADER_DIR/module.c $LOADER_DIR/jit.c"

# --- what to compile with -------------------------------------------------------------------------

CFLAGS="-O3 -std=c11 -fvisibility=hidden -DHXS_NATIVE_TABLE $ANY_VERSION -include $VENDOR/hxs_vendor.h -I $INC -I $LOADER_INC"
SOURCES="$HERE/hxs.c"

if [ "$JIT" = "1" ]; then
	SOURCES="$SOURCES $LOADER"
else
	CFLAGS="$CFLAGS -DHXS_NO_JIT"
	note "loader: left out, every script will be interpreted"
fi

if [ "$WINDOWS" = "1" ]; then
	LINK="-L $HL -lhl"
else
	LINK="-L $HL -L $HL/lib -lhl"
fi

if [ "$FLAGS_ONLY" = "1" ]; then
	printf 'sources: %s\n' "$SOURCES"
	printf 'cflags: %s\n' "$CFLAGS"
	printf 'link: %s\n' "$LINK"
	exit 0
fi

# --- build ----------------------------------------------------------------------------------------

CC=${CC:-}
if [ -z "$CC" ]; then
	for c in clang gcc cc x86_64-w64-mingw32-gcc; do
		if command -v "$c" >/dev/null 2>&1; then CC=$c; break; fi
	done
fi

[ -n "$CC" ] || die "no C compiler found: set CC"

note "compiler: $CC"
note "hashlink: $HL"

if [ -z "$HLC" ]; then
	[ -n "$OUT" ] || OUT="$HERE/hxscript.$EXT"

	# shellcheck disable=SC2086
	$CC -shared $CFLAGS -o "$OUT" $SOURCES $LINK

	note "built: $OUT"
	exit 0
fi

# --- into an HL/C program -------------------------------------------------------------------------
#
# `haxe -hl out/main.c` writes C rather than bytecode, and hlc.json beside it names every file it
# wrote and every library the program binds. Both are read here rather than said a second time: a
# list kept by hand is wrong the moment the program's imports change, and nobody finds out until
# something is missing at run time.
#
# Only the first file is compiled, and that is not a shortcut. Haxe writes a file per type and then a
# main file that #includes every one of them unless HL_MAKE says it is being built the other way, so
# compiling the list as well would define everything twice and fail on a few hundred duplicate
# symbols. Separate compilation is faster where there are cores to spare and belongs to a real build
# system; this is the one that always works.

[ -f "$HLC/hlc.json" ] || die "no hlc.json in $HLC, so Haxe did not write HL/C there"

ENTRY=$(sed -n '/"files"/,/\]/p' "$HLC/hlc.json" | grep -oE '"[^"]+\.c"' | head -1 | tr -d '"')
[ -n "$ENTRY" ] || die "hlc.json in $HLC names no files"

# A HashLink install ships one .hdll per library and hlc.json names them the way @:hlNative did, so
# the two line up. std is libhl itself, and hxscript is this module, which is compiled in from source
# rather than linked against: that is what makes the result one binary with nothing beside it.
BINDS=$(sed -n '/"libs"/p' "$HLC/hlc.json" | grep -oE '"[^"]+"' | tr -d '"' | grep -v '^libs$' || true)

if [ "$WINDOWS" = "1" ]; then
	LINK="$HL/libhl.dll"
else
	LINK="-L$HL -L$HL/lib -lhl"
fi

for lib in $BINDS; do
	case "$lib" in
		std|hxscript) continue ;;
	esac

	if [ "$WINDOWS" = "1" ]; then
		[ -f "$HL/$lib.hdll" ] && LINK="$LINK $HL/$lib.hdll"
	else
		LINK="$LINK -l$lib"
	fi
done

if [ "$WINDOWS" = "1" ]; then
	# hlc_main.c's entry point is wmain and it resolves symbols through dbghelp. Both are what any
	# HL/C program on Windows needs, with or without this module in it.
	PLATFORM="-municode"
	LINK="$LINK -ldbghelp -luser32 -lkernel32"
	[ -n "$OUT" ] || OUT="$HLC/main.exe"
else
	PLATFORM=
	LINK="$LINK -lm -lpthread"
	[ -n "$OUT" ] || OUT="$HLC/main"
fi

note "program: $HLC/$ENTRY"
note "binds: $(echo $BINDS | tr '\n' ' ')"
note "building $OUT"

# -fvisibility=hidden belongs to a shared library and not to a program, and the generated C declares
# this module's natives HL_API, which on Windows means dllimport. The linker resolves them here
# instead and says LNK4217 once per symbol, which is expected and not worth showing.
CFLAGS=$(printf '%s' "$CFLAGS" | sed 's/-fvisibility=hidden //')

# shellcheck disable=SC2086
$CC -O2 $PLATFORM $CFLAGS -I "$HLC" -o "$OUT" "$HLC/$ENTRY" $SOURCES $LINK

note "built: $OUT"
