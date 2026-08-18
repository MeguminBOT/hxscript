#!/usr/bin/env bash
# Builds the haxelib submission zip from a committed ref, and optionally submits it.
#
# The package is the library only: src/, extraParams.hxml, the manifest, the readme and the licence.
# No examples, no tests, no docs tooling -- those are worth having in the repository and are dead
# weight in every install of the library.
#
# extraParams.hxml is not documentation and not optional. haxelib applies it to every build that says
# -lib hxscript, and it is the whole of how the setup macros come to run, so a package without it
# installs a library that quietly does nothing: no dead code kept, nothing wired, no banner, and a
# host left to write those three lines itself without being told it has to.
#
# `git archive` rather than a directory zip, for two reasons. Entry paths come out with forward
# slashes (Windows' Compress-Archive writes backslashes, which break the package on haxelib's Linux
# server), and the contents come from COMMITTED state, so a dirty working tree cannot leak into a
# release.
#
#   bash package.sh                  # package HEAD               -> hxscript.zip
#   bash package.sh v1.0.0           # package a tag              -> hxscript.zip
#   bash package.sh HEAD --submit    # package, then push to haxelib
#   bash package.sh --submit         # same thing
#
# `--submit` runs `haxelib submit`, which prompts for the account password. Submitting is
# irreversible: haxelib does not allow deleting or overwriting a published version, so the version
# in haxelib.json has to be bumped before every submission.
set -euo pipefail

ref="HEAD"
submit="no"

for arg in "$@"; do
	case "$arg" in
		--submit) submit="yes" ;;
		-h|--help)
			sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
			exit 0
			;;
		-*)
			echo "unknown option: $arg" >&2
			exit 2
			;;
		*) ref="$arg" ;;
	esac
done

out="hxscript.zip"
manifest="haxelib.json"

command -v git >/dev/null || { echo "git is not on PATH" >&2; exit 1; }
[ -f "$manifest" ] || { echo "run this from the repository root ($manifest not found)" >&2; exit 1; }

git rev-parse --verify --quiet "$ref^{commit}" >/dev/null \
	|| { echo "no such ref: $ref" >&2; exit 1; }

# Read the version out of the COMMITTED manifest, not the working copy: that is what will actually
# be inside the zip, and the two can differ.
version=$(git show "$ref:$manifest" | grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
[ -n "$version" ] || { echo "could not read version from $manifest at $ref" >&2; exit 1; }

# Everything the package ships. Anything missing from the ref is a mistake worth stopping for
# rather than silently shipping a package without a licence.
files="src extraParams.hxml $manifest README.md LICENSE"
for f in $files; do
	git cat-file -e "$ref:$f" 2>/dev/null || { echo "missing from $ref: $f" >&2; exit 1; }
done

if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
	echo "note: the working tree is dirty; packaging committed state from $ref anyway" >&2
fi

rm -f "$out"
git archive --format=zip --output="$out" "$ref" $files

echo "wrote $out from $ref (hxscript $version)"

if [ "$submit" != "yes" ]; then
	echo
	echo "submit with:  bash package.sh $ref --submit"
	echo "          or:  haxelib submit $out"
	exit 0
fi

command -v haxelib >/dev/null || { echo "haxelib is not on PATH" >&2; exit 1; }

# A published version cannot be replaced, so make the irreversible bit explicit before doing it.
echo
echo "about to publish hxscript $version to lib.haxe.org."
echo "this cannot be undone or overwritten -- a mistake needs a new version number."
printf "type the version to confirm: "
read -r typed

if [ "$typed" != "$version" ]; then
	echo "got '$typed', expected '$version' -- nothing submitted" >&2
	exit 1
fi

haxelib submit "$out"
echo "submitted hxscript $version"
