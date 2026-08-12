#!/bin/sh
# Puts hxScript's runtime compiler into an HL/C program.
#
#   sh hlc.sh --flags              print what to add to a native build you already have
#   sh hlc.sh out                  build the C in out/ into an executable
#   sh hlc.sh out --out game.exe   name the executable
#   sh hlc.sh out --no-jit         leave the loader out, so scripts are interpreted
#
# HL/C is the other way to ship HashLink: `haxe -hl out.c` writes C that compiles to an ordinary
# native binary with no VM process and no bytecode file. The extension is compiled in rather than
# loaded, and the header Haxe generates for its natives declares exactly the symbols hxscript.c
# already defines, so the same file serves both ways of shipping.
#
# What does not carry over is the `?` that makes the extension optional on HL/JIT. A dlopened
# library can be absent and leave its natives as stubs; a linked one either resolves or the link
# fails. An HL/C host therefore decides at build time whether it can compile scripts.
#
# Nothing here needs Haxe. `haxelib run hxscript hlc` does the same work, minus the fetching, which
# is why this exists separately.

set -e

CDIR=
EXE=
HL=${HLPATH:-}
SRC=${HL_SRC:-}
YES=0
JIT=1
FLAGS_ONLY=0
REPO=https://github.com/HaxeFoundation/hashlink

while [ $# -gt 0 ]; do
	case "$1" in
		--flags) FLAGS_ONLY=1; shift ;;
		--no-jit) JIT=0; shift ;;
		--out) EXE=$2; shift 2 ;;
		--hl) HL=$2; shift 2 ;;
		--src) SRC=$2; shift 2 ;;
		--yes|-y) YES=1; shift ;;
		--help|-h)
			sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'
			exit 0 ;;
		*)
			if [ -z "$CDIR" ]; then CDIR=$1; shift; else echo "unknown argument: $1" >&2; exit 1; fi ;;
	esac
done

HERE=$(cd "$(dirname "$0")" && pwd)

say() { printf '%s\n' "$*"; }
note() { [ "$FLAGS_ONLY" = "1" ] || printf '%s\n' "$*"; }
die() { printf '%s\n' "$*" >&2; exit 1; }

# Only asks when someone is there to answer. A build machine gets the default and a reason.
ask() {
	if [ "$YES" = "1" ]; then return 0; fi
	if [ ! -t 0 ]; then return 1; fi

	printf '%s [y/N] ' "$1"
	read -r reply || return 1

	case "$reply" in
		y|Y|yes|YES) return 0 ;;
		*) return 1 ;;
	esac
}

holds_runtime() {
	[ -f "$1/libhl.dll" ] || [ -f "$1/libhl.so" ] || [ -f "$1/libhl.dylib" ] || [ -f "$1/libhl.lib" ]
}

is_tree() {
	[ -f "$1/src/hl.h" ] && [ -f "$1/src/hlmodule.h" ] && [ -f "$1/src/opcodes.h" ] \
		&& [ -f "$1/src/code.c" ] && [ -f "$1/src/module.c" ] && [ -f "$1/src/jit.c" ]
}

# hl.h carries HL_VERSION as one byte each, so 0x011000 is 1.16.0.
stamped() {
	raw=$(grep -E '^#[[:space:]]*define[[:space:]]+HL_VERSION' "$1" 2>/dev/null | grep -oE '0x[0-9a-fA-F]+' | head -1 || true)
	[ -n "$raw" ] || return 1
	printf '%d.%d.%d' $(( raw >> 16 & 255 )) $(( raw >> 8 & 255 )) $(( raw & 255 ))
}

case "$(uname -s 2>/dev/null || echo unknown)" in
	MINGW*|MSYS*|CYGWIN*) WINDOWS=1 ;;
	*) WINDOWS=0 ;;
esac

# --- what is being built for ---------------------------------------------------------------------

# The machine is read only when nothing was said about it. HashLink's jit emits x86 and x86-64 and
# nothing else, and on arm64 it compiles cleanly and writes x86 bytes, so this is worth getting
# right rather than defaulting.
if [ "$JIT" = "1" ]; then
	MACHINE=$(uname -m 2>/dev/null || echo unknown)
	case "$MACHINE" in
		arm*|aarch*)
			note "$MACHINE cannot run HashLink's jit, so the loader is being left out."
			note "Scripts will be interpreted. Pass --no-jit to say so deliberately."
			JIT=0 ;;
	esac
fi

# --- where libhl is ------------------------------------------------------------------------------

if [ -n "$HL" ] && ! holds_runtime "$HL"; then
	die "no HashLink runtime in $HL"
fi

if [ -z "$HL" ]; then
	found=$(command -v hl 2>/dev/null || true)
	if [ -n "$found" ]; then
		dir=$(cd "$(dirname "$found")" && pwd)
		holds_runtime "$dir" && HL=$dir
	fi
fi

if [ -z "$HL" ]; then
	for guess in /usr/local/lib /usr/lib /usr/lib/x86_64-linux-gnu /opt/homebrew/lib \
		"/c/HaxeToolkit/hl" "/c/hashlink" "C:/HaxeToolkit/hl" "C:/hashlink"; do
		if holds_runtime "$guess"; then HL=$guess; break; fi
	done
fi

[ -n "$HL" ] || die "no HashLink was found. Install it, or pass --hl <directory holding libhl>"

# A HashLink install ships include/hl.h, which carries the version. That is the thing to compare a
# source tree against, and it needs no VM binary, which an HL/C build otherwise has no use for.
VERSION=$(stamped "$HL/include/hl.h" 2>/dev/null || true)

if [ -z "$VERSION" ]; then
	if [ -x "$HL/hl" ]; then HLEXE="$HL/hl"; elif [ -x "$HL/hl.exe" ]; then HLEXE="$HL/hl.exe"; else HLEXE=; fi
	[ -n "$HLEXE" ] && VERSION=$("$HLEXE" --version 2>/dev/null | head -1 | tr -d '\r' || true)
fi

note "HashLink${VERSION:+ $VERSION} at $HL"

# --- the sources ---------------------------------------------------------------------------------

# Only needed for the loader. Without it this compiles one small file against hl.h, which the binary
# distributions do ship, so an architecture that cannot jit needs no source tree at all.
if [ "$JIT" = "1" ]; then
	if [ -n "$SRC" ] && ! is_tree "$SRC"; then
		die "no hashlink sources in $SRC"
	fi

	if [ -z "$SRC" ]; then
		for near in "$HL/src" "$HL/.." "$HL/../src" "$HL/../.." "./hashlink-$VERSION"; do
			if is_tree "$near" 2>/dev/null; then SRC=$(cd "$near" && pwd); break; fi
		done
	fi

	if [ -z "$SRC" ]; then
		note ""
		note "No hashlink sources are on this machine, and they cannot be worked out: the binary"
		note "distributions ship hl.h and none of code.c, module.c or jit.c, which the loader is"
		note "built from."
		note ""

		if ask "Fetch the hashlink ${VERSION:-sources} from $REPO ?"; then
			command -v tar >/dev/null 2>&1 || die "tar is needed to unpack them"

			fetch=
			command -v curl >/dev/null 2>&1 && fetch="curl -fsSL -o"
			[ -z "$fetch" ] && command -v wget >/dev/null 2>&1 && fetch="wget -qO"
			[ -n "$fetch" ] || die "curl or wget is needed to fetch them"

			tarball=hashlink-$VERSION.tar.gz
			got=0

			for tag in "$VERSION" "$(echo "$VERSION" | cut -d. -f1,2)"; do
				[ -n "$tag" ] || continue
				note "fetching $REPO/archive/refs/tags/$tag.tar.gz"
				if $fetch "$tarball" "$REPO/archive/refs/tags/$tag.tar.gz" 2>/dev/null; then got=1; break; fi
			done

			[ "$got" = "1" ] || die "could not fetch them. Download the hashlink $VERSION sources yourself and pass --src"

			rm -rf "hashlink-$VERSION"
			mkdir -p "hashlink-$VERSION"
			tar -xzf "$tarball" -C "hashlink-$VERSION" --strip-components=1
			rm -f "$tarball"

			is_tree "hashlink-$VERSION" || die "what was fetched is not a hashlink source tree"
			SRC=$(cd "hashlink-$VERSION" && pwd)
			note "unpacked into $SRC"
		else
			die "nothing was fetched. Get the hashlink ${VERSION:-} sources and pass --src <directory>, or pass --no-jit to build without the loader"
		fi
	fi

	# The struct layouts in hl.h are shared with the libhl this links against, so a mismatched pair
	# compiles and links cleanly and then reads fields from the wrong offsets.
	DECLARED=$(stamped "$SRC/src/hl.h" 2>/dev/null || true)
	if [ -n "$DECLARED" ] && [ -n "$VERSION" ] && [ "$DECLARED" != "$VERSION" ]; then
		die "the sources in $SRC are hashlink $DECLARED and $HL is $VERSION. Pass --src for a matching tree."
	fi

	note "sources at $SRC"
	INCLUDES="-I$SRC/src -I$HERE"
	CARRIED="$HERE/hxscript.c $SRC/src/code.c $SRC/src/module.c $SRC/src/jit.c"
else
	if [ -n "$SRC" ] && [ -f "$SRC/src/hl.h" ]; then
		INCLUDES="-I$SRC/src -I$HERE"
	elif [ -f "$HL/include/hl.h" ]; then
		INCLUDES="-I$HL/include -I$HERE"
	else
		die "no hl.h was found. Pass --src <a hashlink source tree>, or use an install that ships include/hl.h"
	fi

	CARRIED="$HERE/hxscript.c"
	INCLUDES="-DHXS_NO_JIT $INCLUDES"
fi

# --- print and stop ------------------------------------------------------------------------------

if [ "$FLAGS_ONLY" = "1" ]; then
	say "$INCLUDES $CARRIED"
	exit 0
fi

[ -n "$CDIR" ] || die "name the directory Haxe generated the HL/C into, or pass --flags"
[ -f "$CDIR/hlc.json" ] || die "there is no hlc.json in $CDIR, so Haxe did not generate HL/C there"

# --- the compiler --------------------------------------------------------------------------------

if [ -z "$CC" ] || ! command -v "$CC" >/dev/null 2>&1; then
	CC=
	for name in cc gcc clang x86_64-w64-mingw32-gcc; do
		if command -v "$name" >/dev/null 2>&1; then CC=$name; break; fi
	done
fi

if [ -z "$CC" ]; then
	case "$(uname -s 2>/dev/null || echo unknown)" in
		Darwin) die "no C compiler was found. Install the command line tools with: xcode-select --install" ;;
		MINGW*|MSYS*|CYGWIN*) die "no C compiler was found. Install mingw-w64, or set CC" ;;
		*) die "no C compiler was found. Install build-essential, or set CC" ;;
	esac
fi

note "compiler $CC"

# --- what Haxe wrote -----------------------------------------------------------------------------

# hlc.json names every file Haxe generated and every library the program binds, so it is read rather
# than the same thing being said twice. The key names hold no ".c", so the file list falls out of it
# without needing a JSON parser.
#
# Only the first is compiled, and that is not a shortcut. Haxe writes a file per type and then a main
# file that #includes every one of them, unless HL_MAKE says it is being built the other way, so
# compiling the list as well would define everything twice and fail the link on a few hundred
# duplicate symbols. Separate compilation is faster on a machine with cores to spare and is what a
# real build system should do; this is the fallback for someone with none.
ENTRY=$(sed -n '/"files"/,/\]/p' "$CDIR/hlc.json" | grep -oE '"[^"]+\.c"' | head -1 | tr -d '"')
[ -n "$ENTRY" ] || die "hlc.json in $CDIR names no files"

GENERATED="$CDIR/$ENTRY"

# A HashLink install ships one .hdll per library, and hlc.json names them the way @:hlNative did, so
# the two line up. std is libhl itself, and hxscript is compiled in from source rather than linked
# against, which is what makes the result one binary with nothing to ship beside it.
LIBS=$(sed -n '/"libs"/p' "$CDIR/hlc.json" | grep -oE '"[^"]+"' | tr -d '"' | grep -v '^libs$' || true)

if [ "$WINDOWS" = "1" ]; then
	LINK="$HL/libhl.dll"
else
	LINK="-L$HL -lhl"
fi

for lib in $LIBS; do
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
	# hlc_main.c's entry point is wmain, and it resolves symbols through dbghelp. Both are what an
	# HL/C program on Windows needs whether or not hxScript is in it, which is why neither is part of
	# what --flags prints.
	PLATFORM="-municode"
	LINK="$LINK -ldbghelp -luser32 -lkernel32"
else
	PLATFORM=
	LINK="$LINK -lm -lpthread"
fi

[ -n "$EXE" ] || { if [ "$WINDOWS" = "1" ]; then EXE="$CDIR/main.exe"; else EXE="$CDIR/main"; fi; }

# --- build ---------------------------------------------------------------------------------------

note "building $EXE"
[ "$JIT" = "1" ] || note "without the loader, so every script will be interpreted"

# LNK4217 is expected and is not worth showing. Haxe's generated natives.h declares the extension's
# functions HL_API, which on Windows is an import, and this build defines them in the same binary.
# The linker resolves them locally and says so once per symbol.
LOG=$(mktemp 2>/dev/null || echo "$CDIR/hxscript-build.log")
STATUS=0
$CC -O2 $PLATFORM $INCLUDES -I"$CDIR" -o "$EXE" $GENERATED $CARRIED $LINK 2>"$LOG" || STATUS=$?

grep -v "LNK4217" "$LOG" >&2 || true
rm -f "$LOG"

[ "$STATUS" = "0" ] || exit "$STATUS"

note "ok"
