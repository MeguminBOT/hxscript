#!/bin/sh
# Builds hxscript.hdll, the extension a HashLink host needs to run compiled scripts.
#
#   sh hdll.sh                     ask about anything it cannot work out
#   sh hdll.sh --out bin           put it somewhere in particular
#   sh hdll.sh --out bin --yes     answer yes to everything, for a build machine
#
# Everything it can work out from this machine it works out: where HashLink is, which version, where
# a matching source tree is, and which C compiler to drive. The one thing it cannot is the hashlink
# sources when the machine has none, because the binary distributions ship hl.h and none of the rest.
# It asks before fetching those, and does nothing you did not agree to.
#
# Nothing here needs Haxe. A build with `-lib hxscript -D hxscript_hl` does the same work by itself,
# minus the fetching, which is why this exists separately.

set -e

OUT=
HL=${HLPATH:-}
SRC=${HL_SRC:-}
YES=0
REPO=https://github.com/HaxeFoundation/hashlink

while [ $# -gt 0 ]; do
	case "$1" in
		--out) OUT=$2; shift 2 ;;
		--hl) HL=$2; shift 2 ;;
		--src) SRC=$2; shift 2 ;;
		--yes|-y) YES=1; shift ;;
		--help|-h)
			sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
			exit 0 ;;
		*)
			if [ -z "$OUT" ]; then OUT=$1; shift; else echo "unknown argument: $1" >&2; exit 1; fi ;;
	esac
done

HERE=$(cd "$(dirname "$0")" && pwd)

say() { printf '%s\n' "$*"; }
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

# --- where to put it -----------------------------------------------------------------------------

if [ -z "$OUT" ]; then
	if [ -t 0 ] && [ "$YES" != "1" ]; then
		printf 'Where should hxscript.hdll go? [.] '
		read -r OUT || OUT=
	fi
	OUT=${OUT:-.}
fi

mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)

# --- the VM --------------------------------------------------------------------------------------

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

if [ -x "$HL/hl" ]; then HLEXE="$HL/hl"; elif [ -x "$HL/hl.exe" ]; then HLEXE="$HL/hl.exe"; else HLEXE=hl; fi

VERSION=$("$HLEXE" --version 2>/dev/null | head -1 | tr -d '\r' || true)
[ -n "$VERSION" ] || die "the HashLink at $HL would not report its version"

say "HashLink $VERSION at $HL"

# --- the sources ---------------------------------------------------------------------------------

if [ -n "$SRC" ] && ! is_tree "$SRC"; then
	die "no hashlink sources in $SRC"
fi

if [ -z "$SRC" ]; then
	for near in "$HL/src" "$HL/.." "$HL/../src" "$HL/../.." "./hashlink-$VERSION"; do
		if is_tree "$near" 2>/dev/null; then SRC=$(cd "$near" && pwd); break; fi
	done
fi

if [ -z "$SRC" ]; then
	say ""
	say "No hashlink sources are on this machine, and they cannot be worked out: the binary"
	say "distributions ship hl.h and none of code.c, module.c or jit.c, which this is built from."
	say ""

	if ask "Fetch the hashlink $VERSION sources from $REPO ?"; then
		command -v tar >/dev/null 2>&1 || die "tar is needed to unpack them"

		fetch=
		command -v curl >/dev/null 2>&1 && fetch="curl -fsSL -o"
		[ -z "$fetch" ] && command -v wget >/dev/null 2>&1 && fetch="wget -qO"
		[ -n "$fetch" ] || die "curl or wget is needed to fetch them"

		tarball=hashlink-$VERSION.tar.gz
		got=0

		for tag in "$VERSION" "$(echo "$VERSION" | cut -d. -f1,2)"; do
			say "fetching $REPO/archive/refs/tags/$tag.tar.gz"
			if $fetch "$tarball" "$REPO/archive/refs/tags/$tag.tar.gz" 2>/dev/null; then got=1; break; fi
		done

		[ "$got" = "1" ] || die "could not fetch them. Download the hashlink $VERSION sources yourself and pass --src"

		rm -rf "hashlink-$VERSION"
		mkdir -p "hashlink-$VERSION"
		tar -xzf "$tarball" -C "hashlink-$VERSION" --strip-components=1
		rm -f "$tarball"

		is_tree "hashlink-$VERSION" || die "what was fetched is not a hashlink source tree"
		SRC=$(cd "hashlink-$VERSION" && pwd)
		say "unpacked into $SRC"
	else
		die "nothing was fetched. Get the hashlink $VERSION sources and pass --src <directory>"
	fi
fi

# --- do they match -------------------------------------------------------------------------------

# hl.h carries the version it belongs to, and its struct layouts are shared with the running libhl,
# so a mismatched pair compiles and links cleanly and then reads fields from the wrong offsets.
STAMP=$(grep -E '^#[[:space:]]*define[[:space:]]+HL_VERSION' "$SRC/src/hl.h" 2>/dev/null | grep -oE '0x[0-9a-fA-F]+' | head -1 || true)

if [ -n "$STAMP" ]; then
	DECLARED=$(printf '%d.%d.%d' $(( STAMP >> 16 )) $(( (STAMP >> 8) & 255 )) $(( STAMP & 255 )))
	if [ "$DECLARED" != "$VERSION" ]; then
		die "the sources in $SRC are hashlink $DECLARED and the VM is $VERSION. Pass --src for a matching tree."
	fi
fi

say "sources at $SRC"

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

say "compiler $CC"

# --- build ---------------------------------------------------------------------------------------

# gc.c and allocator.c are deliberately NOT carried: they are already in the running libhl, and a
# second copy would give loaded modules their own heap, leaving their objects invisible to its
# collector.
LOADER="$SRC/src/code.c $SRC/src/module.c $SRC/src/jit.c"
FLAGS="-O2 -I$SRC/src -I$HERE"

case "$(uname -s 2>/dev/null || echo unknown)" in
	Darwin) FLAGS="$FLAGS -dynamiclib -fPIC"; LINK="-L$HL -lhl" ;;
	MINGW*|MSYS*|CYGWIN*) FLAGS="$FLAGS -shared -m64"; LINK="$HL/libhl.dll" ;;
	*) FLAGS="$FLAGS -shared -fPIC"; LINK="-L$HL -lhl" ;;
esac

say "building $OUT/hxscript.hdll"

# Named only once it is whole, so an interrupted build cannot leave something that loads.
$CC $FLAGS -o "$OUT/hxscript.hdll.building" "$HERE/hxscript.c" $LOADER $LINK
mv -f "$OUT/hxscript.hdll.building" "$OUT/hxscript.hdll"
printf '%s\n' "$VERSION" > "$OUT/hxscript.hdll.built"

say "ok"
