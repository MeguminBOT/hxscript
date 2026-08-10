#!/usr/bin/env bash
# Builds the hxScript sandbox on Linux, macOS, or Windows under Git Bash.
#
#   ./build.sh                 release build for this platform
#   ./build.sh run             build, then launch it
#   ./build.sh --debug         debug build
#   ./build.sh --clean         wipe the build output first
#   ./build.sh linux           build for a named target: windows | linux | mac
#   ./build.sh linux run --debug        they combine, in any order
#
# Two environment variables, both optional:
#
#   SMIDR_PATH   where SmiðrUI is checked out, if it is not a sibling of this repository
#   LIME_TARGET  a default target, if you do not want to type one
#
# The point of this script over calling lime directly is the checks. A missing haxelib fails inside
# lime with a stack trace naming a file in lime rather than the library you have not installed, and
# the `lime` command itself only exists after `haxelib run lime setup`, which is the first thing
# absent on a new machine. Everything below is about turning those into one sentence each.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"

target="${LIME_TARGET:-}"
mode="release"
clean="no"
launch="no"

for arg in "$@"; do
	case "$arg" in
		windows|linux|mac|macos|html5|hl) target="$arg" ;;
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

# `uname` rather than $OSTYPE: it is the one that answers the same way under Git Bash, MSYS and WSL.
if [ -z "$target" ]; then
	case "$(uname -s)" in
		Darwin) target="mac" ;;
		Linux) target="linux" ;;
		MINGW*|MSYS*|CYGWIN*) target="windows" ;;
		*)
			echo "build.sh: could not tell what platform this is; pass one, e.g. ./build.sh linux" >&2
			exit 2
			;;
	esac
fi

say() { printf '%s\n' "$*"; }
die() { printf '%s\n' "$*" >&2; exit 1; }

# Under Git Bash and MSYS a path looks like /c/Users/..., which haxelib writes verbatim into its dev
# file and Windows' haxe then cannot open. `cygpath` is the translation, and is present in exactly
# the environments that need it.
native() {
	if command -v cygpath >/dev/null 2>&1; then
		cygpath -w "$1"
	else
		printf '%s\n' "$1"
	fi
}

# ---- the toolchain ----------------------------------------------------------

command -v haxe >/dev/null 2>&1 || die "haxe is not on PATH. Install Haxe 4.3 or newer: https://haxe.org/download/"

say "haxe        $(haxe --version 2>&1 | head -1)"

# `haxelib run lime` rather than the `lime` alias, which only exists after `haxelib run lime setup`.
lime() { haxelib run lime "$@"; }

if ! haxelib path lime >/dev/null 2>&1; then
	die "lime is not installed. Run:  haxelib install lime"
fi

# ---- the dev haxelibs -------------------------------------------------------
#
# hxscript is this repository, and SmiðrUI is not on haxelib at all, so both have to be pointed at a
# checkout. Doing it here rather than documenting it means the build works on a fresh clone.

say "hxscript    $(native "$repo")"
haxelib dev hxscript "$(native "$repo")" >/dev/null

smidr="${SMIDR_PATH:-}"

if [ -z "$smidr" ]; then
	for guess in "$repo/../SmidrUI" "$repo/../smidr" "$HOME/SmidrUI"; do
		if [ -d "$guess/src/smidr" ]; then
			smidr="$(cd "$guess" && pwd)"
			break
		fi
	done
fi

if [ -z "$smidr" ]; then
	if haxelib path smidr >/dev/null 2>&1; then
		say "smidr       (from haxelib)"
	else
		die "SmiðrUI not found. Clone it and point this at it:
  git clone https://github.com/MeguminBOT/SmidrUI
  SMIDR_PATH=/path/to/SmidrUI ./build.sh"
	fi
else
	say "smidr       $(native "$smidr")"
	haxelib dev smidr "$(native "$smidr")" >/dev/null
fi

# ---- the rest of the haxelibs ----------------------------------------------

missing=""

for lib in openfl flixel flixel-addons flixel-ui; do
	haxelib path "$lib" >/dev/null 2>&1 || missing="$missing $lib"
done

if [ -n "$missing" ]; then
	printf '\nMissing haxelibs:%s\n\nInstall them with:\n' "$missing" >&2

	for lib in $missing; do
		printf '  haxelib install %s\n' "$lib" >&2
	done

	exit 1
fi

# ---- build ------------------------------------------------------------------

cd "$here"

if [ "$clean" = "yes" ]; then
	say "cleaning    export/"
	rm -rf export
fi

flags=""
[ "$mode" = "debug" ] && flags="-debug"

say "building    $target ($mode)"
lime build Project.xml "$target" $flags

# ---- the projects folder ----------------------------------------------------
#
# The app writes this itself on first run, from the templates it carries as assets. Creating it here
# as well means the thing that comes out of the build is already a folder somebody can drop a project
# into, without having had to run it once first.

out="$(find export -type d -name bin -path "*$target*" 2>/dev/null | head -1 || true)"

if [ -n "$out" ]; then
	mkdir -p "$out/projects"
	say "projects    $out/projects"
fi

say ""
say "built       $target ($mode)"

if [ "$launch" = "yes" ]; then
	say "running     ..."
	lime run Project.xml "$target" $flags
else
	say "run it      ./build.sh $target run"
fi
