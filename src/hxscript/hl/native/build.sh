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

# --- the compiler, and which architecture it is building for --------------------------------------
#
# Both are needed before there is anything to decide: which backend to compile follows from the
# architecture, and so does which HashLink is the right one to link against. The compiler is asked rather than the machine: a cross build
# is for whatever CC targets, which uname does not know, and CC may be carrying the flag that decides
# it, as CC="clang -arch arm64" does on macOS.

CC=${CC:-}
if [ -z "$CC" ]; then
	for c in clang gcc cc x86_64-w64-mingw32-gcc; do
		if command -v "$c" >/dev/null 2>&1; then CC=$c; break; fi
	done
fi

[ -n "$CC" ] || die "no C compiler found: set CC"

# hxs_arch.h holds the one chain of architecture macros and hxs.c includes that same header, so what
# is decided here and what the module compiles with cannot drift apart. A probe that says nothing is
# read as an architecture with a jit, which is what this did before there was one: where there is a
# jit that keeps it, and where there is not the loader fails to compile rather than quietly going
# missing on a machine that could have had it.
PROBED=$($CC -E "$HERE/hxs_arch_probe.c" 2>/dev/null | grep -a '^hxs_arch ' | tail -1)
ARCH=$(printf '%s' "$PROBED" | awk -F'"' '{print $2}')
ARCH_JIT=$(printf '%s' "$PROBED" | awk '{print $3}')
ARCH_BACKEND=$(printf '%s' "$PROBED" | awk -F'"' '{print $4}')

if [ -z "$ARCH" ]; then
	ARCH="unknown"
	ARCH_JIT=1
	ARCH_BACKEND="vendor"
fi

note "compiler: $CC"
note "architecture: $ARCH"

# --- the HashLink to build against ----------------------------------------------------------------
#
# hl.h has to be the one the running libhl was built from, so it is taken from an installation rather
# than carried. Everything else the loader needs is internal to hashlink and is not shipped, which is
# what vendor/ is for.
#
# Every candidate also has to be for the architecture being built for, which is read out of its own
# libhl rather than assumed from where it sits. Building for one and linking against another produces
# a module that loads nowhere, and on a machine cross compiling the easiest installation to find is
# the wrong one.

# Which architecture a library was built for, read out of its header. ELF says so two bytes at
# offset 18, Mach-O says so in its second word. Anything else answers nothing, and nothing is taken
# to mean unknown rather than wrong.
machine_of_file() {
	head_hex=$(od -An -N 20 -tx1 -v "$1" 2>/dev/null | tr -d ' \n')
	[ -n "$head_hex" ] || return 0

	case "$head_hex" in
		7f454c46*)
			case "$head_hex" in
				??????????????????????????????????????3e00*) echo "x86-64" ;;
				??????????????????????????????????????b700*) echo "arm64" ;;
			esac
			;;
		cffaedfe*|cefaedfe*)
			case "$head_hex" in
				????????07000001*) echo "x86-64" ;;
				????????0c000001*) echo "arm64" ;;
			esac
			;;
		4d5a*)
			# PE keeps its header wherever the four bytes at 0x3C point, and the machine two bytes in.
			off_hex=$(od -An -j 60 -N 4 -tx1 -v "$1" 2>/dev/null | tr -d ' 
')
			[ -n "$off_hex" ] || return 0

			b0=$(printf '%s' "$off_hex" | cut -c1-2)
			b1=$(printf '%s' "$off_hex" | cut -c3-4)
			b2=$(printf '%s' "$off_hex" | cut -c5-6)
			b3=$(printf '%s' "$off_hex" | cut -c7-8)
			off=$((0x$b3$b2$b1$b0))

			case "$(od -An -j $((off + 4)) -N 2 -tx1 -v "$1" 2>/dev/null | tr -d ' 
')" in
				6486) echo "x86-64" ;;
				64aa) echo "arm64" ;;
			esac
			;;
	esac
}

# The library an installation links against, which is also the file that says what it is for.
library_of() {
	ls "$1"/libhl.* "$1"/lib/libhl.* 2>/dev/null | head -1
}

# @return 0 when this candidate is one to build against, and remembers the first wrong one.
consider() {
	[ -f "$1/include/hl.h" ] || [ -f "$1/hl.h" ] || return 1

	# An installation is where hl.h and libhl both are, because -lhl is resolved against it. A
	# directory holding only headers is part of one rather than one, and accepting it puts the wrong
	# path on the link line and reads nothing about the architecture.
	lib=$(library_of "$1")
	[ -n "$lib" ] || return 1

	said=$(machine_of_file "$lib")

	if [ -z "$said" ] || [ "$said" = "$ARCH" ]; then
		HL="$1"
		return 0
	fi

	if [ -z "$WRONG" ]; then
		WRONG="$1"
		WRONG_ARCH="$said"
	fi

	return 1
}

WRONG=
WRONG_ARCH=

if [ -n "$HL" ]; then
	CANDIDATES="$HL"
	HL=
else
	CANDIDATES="$(command -v hl 2>/dev/null | sed 's|/[^/]*$||') /c/hashlink/* /usr/local /usr /opt/hashlink $HOME/hashlink"
fi

for guess in $CANDIDATES; do
	[ -n "$guess" ] || continue
	consider "$guess" && break

	# One level down, because the binary distributions unpack into a versioned directory.
	[ -d "$guess" ] || continue

	for inside in "$guess"/*; do
		[ -d "$inside" ] || continue
		consider "$inside" && break
	done

	[ -n "$HL" ] && break
done

if [ -z "$HL" ] && [ -n "$WRONG" ]; then
	die "the HashLink at $WRONG was built for $WRONG_ARCH and this build is for $ARCH: set HLPATH to one built for $ARCH"
fi

[ -n "$HL" ] || die "no HashLink installation found: pass --hl DIR or set HLPATH"

if [ -f "$HL/include/hl.h" ]; then
	INC="$HL/include"
else
	INC="$HL"
fi

# --- the loader sources ---------------------------------------------------------------------------
#
# Where there is no jit there is nothing to carry, so this is where an architecture without one and
# --no-jit meet. jit.c guards itself with __arm__, which 64 bit ARM does not define, so it is not a
# guard there: on arm64 it compiles, emits x86, and on Windows does not get that far.

NOJIT=
if [ "$ARCH_JIT" != "1" ]; then
	NOJIT="the loader is x86-64 only and this is $ARCH"
elif [ "$JIT" = "0" ]; then
	NOJIT="it was left out"
fi

LOADER_INC="$VENDOR/hl116"
ANY_VERSION=
LOADER=

if [ -n "$NOJIT" ]; then
	note "loader: none, $NOJIT, so every script will be interpreted"
elif [ -n "$SRC" ]; then
	[ -f "$SRC/src/jit.c" ] || die "no hashlink source tree at $SRC"
	LOADER_INC="$SRC/src"
	LOADER="$SRC/src/code.c $SRC/src/module.c $SRC/src/jit.c"
	# The headers and the loader come from one tree here, so the version pairing this checks is not
	# a question that can go wrong.
	ANY_VERSION="-DHXS_HL_ANY_VERSION"
	note "loader: $SRC (given)"
elif [ "$ARCH_BACKEND" = "arm64" ]; then
	# code.c reads a module and module.c links it, and neither has an architecture in it, so both are
	# shared with the x86-64 build. Only jit.c is replaced, because only jit.c is an x86 encoder.
	LOADER="$VENDOR/hl116/code.c $VENDOR/hl116/module.c $HERE/arm64/jit_arm64.c $HERE/arm64/exec.c"
	note "loader: carried hashlink 1.16, with this library's own AArch64 jit"
else
	LOADER="$VENDOR/hl116/code.c $VENDOR/hl116/module.c $VENDOR/hl116/jit.c"
	note "loader: carried hashlink 1.16"
fi

# --- what to compile with -------------------------------------------------------------------------

CFLAGS="-O3 -std=c11 -fvisibility=hidden -DHXS_NATIVE_TABLE $ANY_VERSION -include $VENDOR/hxs_vendor.h -I $INC -I $LOADER_INC -I $HERE/arm64"
SOURCES="$HERE/hxs.c"

# -DHXS_NO_JIT is what was asked for rather than what was worked out, so a module built on an
# architecture with no loader says which architecture that was when a host asks it why.
if [ "$JIT" = "0" ]; then
	CFLAGS="$CFLAGS -DHXS_NO_JIT"
fi

if [ -z "$NOJIT" ]; then
	SOURCES="$SOURCES $LOADER"
fi

if [ "$WINDOWS" = "1" ]; then
	LINK="-L $HL -lhl"
else
	# The AArch64 jit calls fmod for the remainder of two floats, which is what hashlink's own jit
	# does on x86 as well, so libm is not optional wherever that backend is compiled in.
	LINK="-L $HL -L $HL/lib -lhl -lm"
fi

if [ "$FLAGS_ONLY" = "1" ]; then
	printf 'architecture: %s\n' "$ARCH"
	printf 'sources: %s\n' "$SOURCES"
	printf 'cflags: %s\n' "$CFLAGS"
	printf 'link: %s\n' "$LINK"
	exit 0
fi

# --- build ----------------------------------------------------------------------------------------

note "hashlink: $HL"

if [ -z "$HLC" ]; then
	[ -n "$OUT" ] || OUT="$HERE/hxscript.$EXT"

	# -fPIC belongs to every shared library and is not optional anywhere it matters. On arm64 Linux
	# the linker refuses outright, naming an ADR_PREL_PG_HI21 relocation against a symbol that may
	# bind externally; on Windows it is meaningless and ignored, and on macOS clang already does it.
	# shellcheck disable=SC2086
	$CC -shared -fPIC $CFLAGS -o "$OUT" $SOURCES $LINK

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
