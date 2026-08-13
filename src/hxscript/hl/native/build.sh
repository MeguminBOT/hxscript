#!/bin/sh
# Builds hxscript.hdll, the module that lets a running HashLink process load bytecode.
#
#   sh build.sh                    build it next to this script
#   sh build.sh --out path.hdll    build it somewhere else
#   sh build.sh --hl DIR           the HashLink installation to build against
#   sh build.sh --src DIR          a hashlink source tree, instead of the carried loader
#   sh build.sh --no-jit           leave the loader out, so every script is interpreted
#   sh build.sh --flags            print what an HL/C build has to add, and build nothing
#
# This is the by hand path. A build that has -lib hxscript and -D hxscript_hl does this for itself,
# and an HL/C build compiles the same files straight into the program rather than into a library.
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
JIT=1
FLAGS_ONLY=0

while [ $# -gt 0 ]; do
	case "$1" in
		--out) OUT=$2; shift 2 ;;
		--hl) HL=$2; shift 2 ;;
		--src) SRC=$2; shift 2 ;;
		--no-jit) JIT=0; shift ;;
		--flags) FLAGS_ONLY=1; shift ;;
		--help|-h) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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

[ -n "$OUT" ] || OUT="$HERE/hxscript.$EXT"

note "compiler: $CC"
note "hashlink: $HL"

# shellcheck disable=SC2086
$CC -shared $CFLAGS -o "$OUT" $SOURCES $LINK

note "built: $OUT"
