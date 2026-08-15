#!/usr/bin/env bash
# Builds the hxScript Sandbox (HashLink Heaps) on Linux, macOS, or Windows under Git Bash.
#
#   ./build.sh                 build it
#   ./build.sh run             build, then launch it
#   ./build.sh bundle          build, then assemble a folder that runs on a machine without HashLink
#   ./build.sh --with-tests    including the conformance projects, which test/all.sh drives
#   ./build.sh --no-jit        without the loader, which is the build an arm64 target gets
#   ./build.sh --debug         debug build
#   ./build.sh --clean         wipe the build output first
#
# **This ships as a native binary, not as bytecode.** Haxe writes C, the C compiles to an executable,
# and there is no VM process and no `.hl` file. That is the half worth demonstrating: on the VM a
# script compiler can be dropped in beside the program as a .hdll and this app would prove nothing
# the VM does not already do, while here it has to be compiled into the executable.
#
# Run setup/unix.sh once first. It installs the haxelibs into a haxelib repository belonging to this
# folder, so nothing here disturbs what the rest of your machine builds against.
#
# Three environment variables, all optional:
#
#   HXSCRIPT_PATH  where hxscript is checked out, if it is not this repository
#   HLPATH         where HashLink is, if `hl` is not on your path
#   HL_SRC         a hashlink source tree to build the loader from, instead of the carried one
#
# The point of this over calling haxe directly is the checks. A missing haxelib fails inside heaps
# with a stack trace naming a file in heaps rather than the library you have not installed, and a
# missing HashLink fails at the link step after minutes of compiling, which reads as the build being
# broken. Everything below turns those into one sentence each.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"

mode="release"
clean="no"
launch="no"
bundle="no"
jit="yes"
tests="no"

for arg in "$@"; do
	case "$arg" in
		run) launch="yes" ;;
		bundle) bundle="yes" ;;
		--no-jit) jit="no" ;;
		--with-tests) tests="yes" ;;
		--debug|-debug) mode="debug" ;;
		--clean|-clean) clean="yes" ;;
		--help|-h)
			sed -n '2,29p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
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

# --- HashLink ------------------------------------------------------------------------------------

# Never run, and still needed. The binary links against libhl and against the .hdll files this
# program binds, and it is compiled against that installation's hl.h.
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
# written by hand here was wrong for as long as it existed: it carried heaps and openal, which this
# app does not bind, and omitted ui and uv, which it does, so a bundle made from it was missing two
# libraries and nobody found out because nobody had run one.
#
# `std` is libhl itself and `hxscript` is the script compiler, which is compiled into the binary.
# Neither is a file to copy from the HashLink install.
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

[ "$clean" = "yes" ] && rm -rf export/hlc

echo "Building ($mode) ..."
haxe sandbox.hxml "${flags[@]}"

echo "Compiling the native binary ..."

# The library's own tooling rather than a compile line kept here, so this app is a consumer of what
# hxScript ships exactly as any other host would be. It works out the loader sources, the compiler
# and what to link; HL_SRC and CC override what it decides.
native_flags=(--hlc export/hlc --out export/hlc/Sandbox.exe)
[ "$jit" = "no" ] && native_flags+=(--no-jit)

sh "$lib_path/src/hxscript/hl/native/build.sh" "${native_flags[@]}"

# The templates are read from disk beside the executable rather than embedded, so the folder has to
# be there for `projects/` to be seeded on a first run.
#
# **Replaced rather than copied over.** `cp -r` merges into what is already there, so a script
# deleted from a template stayed in the build output forever. One did, and it declared a second
# class that won a name over the template's own. That reads as the library resolving a type
# wrongly across modules, and it cost a rebuild at an older commit to find that it was not.
rm -rf export/hlc/assets/templates export/hlc/assets/res export/hlc/assets/conformance
mkdir -p export/hlc/assets
cp -r assets/templates export/hlc/assets/
cp -r assets/res export/hlc/assets/

# The conformance projects are fixtures rather than examples: `conform` has no window to draw in and
# `heaps3d` and `widgets` carry a `SelfTest` naming cases for `--conform` to run. Shipping them put
# three test harnesses in the example list of every build, so they are copied only when asked for.
if [ "$tests" = "yes" ]; then
	cp -r test/projects export/hlc/assets/conformance
fi
runtime_into export/hlc

echo "Built export/hlc/Sandbox.exe"
[ "$tests" = "yes" ] && echo "  with the conformance projects, so test/all.sh can drive them"
[ "$jit" = "no" ] && echo "  without the loader, so every script will be interpreted"

out="export/hlc"
exe="./Sandbox.exe"

# --- bundle --------------------------------------------------------------------------------------

# Shipping a native binary is shipping the program. There is no bytecode file and no VM to carry, and
# the script compiler is inside the executable rather than beside it. libhl and the .hdll files it
# binds still have to be there, because those are dynamic libraries either way.
if [ "$bundle" = "yes" ]; then
	dest="bundle"
	rm -rf "$dest"
	mkdir -p "$dest/assets"

	case "$(uname -s)" in
		MINGW*|MSYS*|CYGWIN*) cp export/hlc/Sandbox.exe "$dest/Sandbox.exe" ;;
		*) cp export/hlc/Sandbox.exe "$dest/Sandbox" ;;
	esac

	cp -r assets/templates "$dest/assets/"
	cp -r assets/res "$dest/assets/"
	runtime_into "$dest"

	echo "Bundled into $dest"
fi

# --- run -----------------------------------------------------------------------------------------

if [ "$launch" = "yes" ]; then
	echo "Launching ..."
	(cd "$out" && exec $exe)
fi
