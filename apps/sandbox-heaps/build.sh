#!/usr/bin/env bash
# Builds the hxScript Sandbox (HashLink Heaps) on Linux, macOS, or Windows under Git Bash.
#
#   ./build.sh                 build it
#   ./build.sh run             build, then launch it
#   ./build.sh bundle          build, then assemble a folder that runs without HashLink installed
#   ./build.sh --debug         debug build
#   ./build.sh --clean         wipe the build output first
#
# Run setup/unix.sh once first. It installs the haxelibs, including hxscript from git, into a
# haxelib repository belonging to this folder.
#
# Two environment variables, both optional:
#
#   HXSCRIPT_PATH  where hxscript is checked out, if it is not this repository
#   HLPATH         where HashLink is, if `hl` is not on your path
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

for arg in "$@"; do
	case "$arg" in
		run) launch="yes" ;;
		bundle) bundle="yes" ;;
		--debug|-debug) mode="debug" ;;
		--clean|-clean) clean="yes" ;;
		--help|-h)
			sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
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

# --- build ---------------------------------------------------------------------------------------

[ "$clean" = "yes" ] && rm -rf export

flags=()
[ "$mode" = "debug" ] && flags+=(-debug)

echo "Building ($mode) ..."
haxe sandbox.hxml "${flags[@]}"

if [ ! -f "export/hxscript.hdll" ]; then
	echo
	echo "No hxscript.hdll beside the output, so scripts will be interpreted rather than compiled."
	echo "To change that: sh ../../src/hxscript/hl/hdll.sh --out export"
fi

# The templates are read from disk beside the executable rather than embedded, so the folder has to
# be there for `projects/` to be seeded on a first run.
mkdir -p export/assets
cp -r assets/templates export/assets/

echo "Built export/sandbox.hl"

# --- bundle ---------------------------------------------------------------------------------------

# A HashLink program is bytecode the VM runs, so shipping one means shipping the VM. There is no
# linking step and nothing is compiled here: hl looks for hlboot.dat when it is given no argument,
# so a renamed VM beside a renamed .hl is a double-clickable application.
#
# hlboot.dat is opened relative to the WORKING directory rather than to the executable. Explorer
# sets that to the folder it launched from, so double-clicking works; a shortcut with a different
# "start in" does not.
if [ "$bundle" = "yes" ]; then
	out="bundle"
	rm -rf "$out"
	mkdir -p "$out"

	exe="$vm/hl"
	[ -f "$exe" ] || exe="$vm/hl.exe"

	case "$(uname -s)" in
		MINGW*|MSYS*|CYGWIN*) cp "$exe" "$out/Sandbox.exe" ;;
		*) cp "$exe" "$out/Sandbox" ;;
	esac

	cp export/sandbox.hl "$out/hlboot.dat"
	[ -f export/hxscript.hdll ] && cp export/hxscript.hdll "$out/"
	cp -r assets/templates "$out/assets-templates-tmp" 2>/dev/null || true
	mkdir -p "$out/assets"
	[ -d "$out/assets-templates-tmp" ] && mv "$out/assets-templates-tmp" "$out/assets/templates"

	# Only what this app binds: fmt, heaps, sdl and std, plus the shared libraries they need. The
	# rest of what HashLink ships is for programs that are not this one.
	for name in libhl.dll libhl.so libhl.dylib fmt.hdll heaps.hdll sdl.hdll openal.hdll SDL3.dll SDL2.dll OpenAL32.dll; do
		[ -f "$vm/$name" ] && cp "$vm/$name" "$out/"
	done

	echo "Bundled $out/ - copy it anywhere and run the executable in it"
fi

if [ "$launch" = "yes" ]; then
	exe="$vm/hl"
	[ -x "$exe" ] || exe="$vm/hl.exe"
	[ -x "$exe" ] || exe="hl"
	echo "Launching ..."
	( cd export && "$exe" sandbox.hl )
fi
