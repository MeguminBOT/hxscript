#!/usr/bin/env bash
# Builds the hxScript Sandbox (HashLink Heaps) on Linux, macOS, or Windows under Git Bash.
#
#   ./build.sh                 build it
#   ./build.sh run             build, then launch it
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

for arg in "$@"; do
	case "$arg" in
		run) launch="yes" ;;
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

echo "Built export/sandbox.hl"

if [ "$launch" = "yes" ]; then
	exe="$vm/hl"
	[ -x "$exe" ] || exe="$vm/hl.exe"
	[ -x "$exe" ] || exe="hl"
	echo "Launching ..."
	( cd export && "$exe" sandbox.hl )
fi
