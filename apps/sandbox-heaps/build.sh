#!/usr/bin/env bash
# Builds the hxScript Sandbox (HashLink Heaps) on Linux, macOS, or Windows under Git Bash.
#
#   ./build.sh                 build it as bytecode the VM runs
#   ./build.sh run             build, then launch it
#   ./build.sh bundle          build, then assemble a folder that runs without HashLink installed
#   ./build.sh hlc             build it as an ordinary native binary instead
#   ./build.sh hlc run         and launch it
#   ./build.sh hlc bundle      and assemble a folder from it
#   ./build.sh hlc --no-jit    without the loader, which is the build an arm64 target gets
#   ./build.sh --debug         debug build
#   ./build.sh --clean         wipe the build output first
#
# **The two shipping modes are the same program.** `common.hxml` is the whole build and the two
# target files add one line each, so `hlc` is a decision about how this ships rather than a different
# application. What differs afterwards is packaging, and `bundle` is where that is visible.
#
# Run setup/unix.sh once first. It installs the haxelibs, including hxscript from git, into a
# haxelib repository belonging to this folder.
#
# Three environment variables, all optional:
#
#   HXSCRIPT_PATH  where hxscript is checked out, if it is not this repository
#   HLPATH         where HashLink is, if `hl` is not on your path
#   HL_SRC         a hashlink source tree, which the HL/C loader is built from
#
# The point of this over calling haxe directly is the checks. A missing haxelib fails inside heaps
# with a stack trace naming a file in heaps rather than the library you have not installed, and a
# missing VM fails after a successful build, which reads as the build being broken. Everything below
# turns those into one sentence each.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"

mode="release"
clean="no"
launch="no"
bundle="no"
native="no"
jit="yes"

for arg in "$@"; do
	case "$arg" in
		run) launch="yes" ;;
		bundle) bundle="yes" ;;
		hlc) native="yes" ;;
		--no-jit) jit="no" ;;
		--debug|-debug) mode="debug" ;;
		--clean|-clean) clean="yes" ;;
		--help|-h)
			sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
			exit 0
			;;
		*)
			echo "build.sh: unknown argument '$arg'" >&2
			echo "try: ./build.sh --help" >&2
			exit 2
			;;
	esac
done

cd "$here"

# --- the toolchain -------------------------------------------------------------------------------

command -v haxe >/dev/null 2>&1 || {
	echo "build.sh: no haxe on your path. https://haxe.org/download" >&2
	exit 1
}

if [ ! -d ".haxelib" ]; then
	echo "build.sh: no local haxelib repository here. Run setup/unix.sh once first." >&2
	exit 1
fi

for lib in heaps hlsdl format hxscript; do
	if ! haxelib path "$lib" >/dev/null 2>&1; then
		echo "build.sh: $lib is not installed. Run setup/unix.sh once first." >&2
		exit 1
	fi
done

# A checkout of hxscript at this repository wins over whatever setup installed, so edits to the
# library are what gets built.
lib_path="${HXSCRIPT_PATH:-$repo}"
if [ -f "$lib_path/haxelib.json" ]; then
	haxelib dev hxscript "$lib_path" >/dev/null 2>&1 || true
fi

# --- the VM --------------------------------------------------------------------------------------

# Needed either way, and for different reasons. Bytecode needs it to run at all; a native binary
# never runs it but links against the libhl and the .hdll files that live beside it.
vm="${HLPATH:-}"
if [ -z "$vm" ]; then
	found="$(command -v hl 2>/dev/null || true)"
	[ -n "$found" ] && vm="$(cd "$(dirname "$found")" && pwd)"
fi

if [ -z "$vm" ]; then
	echo "build.sh: no HashLink found. Install it, or set HLPATH to the directory holding hl." >&2
	echo "          https://hashlink.haxe.org" >&2
	exit 1
fi

export HLPATH="$vm"

# --- what this program binds ---------------------------------------------------------------------

# Read rather than remembered. `hlc.json` is written beside the generated C and names every library
# the program binds, which is the only place that answer is kept honest by the compiler. A list
# written out by hand here was wrong for as long as it existed: it carried heaps and openal, which
# this app does not bind, and omitted ui and uv, which it does, so a bundle made from it was missing
# two libraries and nobody found out because nobody had run one.
#
# `std` is libhl itself and `hxscript` is the script compiler, which is a .hdll beside the output on
# the VM and linked into the binary on HL/C. Neither is a file to copy from the HashLink install.
libraries() {
	local manifest="export/hlc/hlc.json"

	if [ ! -f "$manifest" ]; then
		echo "fmt sdl ui uv"
		return
	fi

	sed -n '/"libs"/p' "$manifest" \
		| grep -oE '"[^"]+"' | tr -d '"' \
		| grep -vE '^(libs|std|hxscript)$' \
		| tr '\n' ' '
}

# Copies libhl, the .hdll files this program binds, and the shared libraries they need.
runtime_into() {
	local into="$1"
	local name

	for name in libhl.dll libhl.so libhl.dylib SDL3.dll SDL2.dll OpenAL32.dll; do
		[ -f "$vm/$name" ] && cp "$vm/$name" "$into/"
	done

	for name in $(libraries); do
		[ -f "$vm/$name.hdll" ] && cp "$vm/$name.hdll" "$into/"
	done

	return 0
}

# --- build ---------------------------------------------------------------------------------------

flags=()
[ "$mode" = "debug" ] && flags+=(-debug)

if [ "$native" = "yes" ]; then
	[ "$clean" = "yes" ] && rm -rf export/hlc

	echo "Building ($mode, HL/C) ..."
	haxe sandbox-hlc.hxml "${flags[@]}"

	echo "Compiling the native binary ..."

	# The library's own tooling rather than a compile line kept here, so this app is a consumer of
	# what hxScript ships exactly as any other host would be. It works out the hashlink sources, the
	# compiler and what to link; HL_SRC and CC override what it decides.
	native_flags=(export/hlc --out export/hlc/Sandbox.exe)
	[ "$jit" = "no" ] && native_flags+=(--no-jit)

	sh "$lib_path/src/hxscript/hl/hlc.sh" "${native_flags[@]}"

	mkdir -p export/hlc/assets
	cp -r assets/templates export/hlc/assets/
	runtime_into export/hlc

	echo "Built export/hlc/Sandbox.exe"
	[ "$jit" = "no" ] && echo "  without the loader, so every script will be interpreted"

	out="export/hlc"
	exe="./Sandbox.exe"
else
	[ "$clean" = "yes" ] && rm -rf export

	echo "Building ($mode) ..."
	haxe sandbox.hxml "${flags[@]}"

	if [ ! -f "export/hxscript.hdll" ]; then
		echo
		echo "No hxscript.hdll beside the output, so scripts will be interpreted rather than compiled."
		echo "To change that: sh $lib_path/src/hxscript/hl/hdll.sh --out export"
	fi

	# The templates are read from disk beside the executable rather than embedded, so the folder has
	# to be there for `projects/` to be seeded on a first run.
	mkdir -p export/assets
	cp -r assets/templates export/assets/

	echo "Built export/sandbox.hl"

	out="export"
	exe=""
fi

# --- bundle --------------------------------------------------------------------------------------

# Where the two shipping modes stop looking alike.
#
# Bytecode means shipping the VM: nothing is compiled or linked here, `hl` opens hlboot.dat when it
# is given no argument, so a renamed VM beside a renamed .hl is a double-clickable application. The
# script compiler is hxscript.hdll beside it and can be left out per release.
#
# HL/C means shipping the program: it is already an executable, there is no bytecode file at all, and
# the script compiler is inside it rather than beside it. libhl and the .hdll files it binds still
# have to be there, because those are dynamic libraries either way.
#
# One caveat belongs to bytecode only: hlboot.dat is opened relative to the WORKING directory rather
# than to the executable. Explorer sets that to the folder it launched from, so double-clicking
# works; a shortcut with a different "start in" does not.
if [ "$bundle" = "yes" ]; then
	dest="bundle"
	rm -rf "$dest"
	mkdir -p "$dest/assets"

	if [ "$native" = "yes" ]; then
		case "$(uname -s)" in
			MINGW*|MSYS*|CYGWIN*) cp export/hlc/Sandbox.exe "$dest/Sandbox.exe" ;;
			*) cp export/hlc/Sandbox.exe "$dest/Sandbox" ;;
		esac
	else
		vmexe="$vm/hl"
		[ -f "$vmexe" ] || vmexe="$vm/hl.exe"

		case "$(uname -s)" in
			MINGW*|MSYS*|CYGWIN*) cp "$vmexe" "$dest/Sandbox.exe" ;;
			*) cp "$vmexe" "$dest/Sandbox" ;;
		esac

		cp export/sandbox.hl "$dest/hlboot.dat"
		[ -f export/hxscript.hdll ] && cp export/hxscript.hdll "$dest/"
	fi

	cp -r assets/templates "$dest/assets/"
	runtime_into "$dest"

	echo "Bundled $dest/ - copy it anywhere and run the executable in it"
fi

# --- launch --------------------------------------------------------------------------------------

if [ "$launch" = "yes" ]; then
	echo "Launching ..."

	if [ "$native" = "yes" ]; then
		( cd "$out" && "$exe" )
	else
		vmexe="$vm/hl"
		[ -x "$vmexe" ] || vmexe="$vm/hl.exe"
		[ -x "$vmexe" ] || vmexe="hl"
		( cd export && "$vmexe" sandbox.hl )
	fi
fi
