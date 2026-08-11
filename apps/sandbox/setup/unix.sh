#!/bin/sh
# SETUP FOR MAC AND LINUX SYSTEMS!!!
# REMINDER THAT YOU NEED HAXE INSTALLED PRIOR TO USING THIS
# https://haxe.org/download
#
# Installs everything apps/sandbox needs into a haxelib repository of its own, so nothing here
# disturbs the libraries the rest of your machine builds against. Run it once, then build:
#
#     sh setup/unix.sh
#     ./build.sh run
cd ..

set -e

echo "Setting up local haxelib repository ..."
haxelib newrepo

# Wipe any leftover folder so haxelib never hits sys_remove_dir on read-only .git files.
install_git () {
	name="$1"
	url="$2"
	ref="$3" # optional git branch/commit to pin
	repo_root="$(haxelib config 2>/dev/null | tr -d '\r')"
	if [ -n "$repo_root" ] && [ -d "$repo_root/$name" ]; then
		echo "Cleaning existing $repo_root/$name ..."
		chmod -R u+w "$repo_root/$name" 2>/dev/null || true
		rm -rf "$repo_root/$name"
	fi
	haxelib git "$name" "$url" $ref --skip-dependencies
}

echo
echo "Installing hxcpp from git first (so no haxelib release of hxcpp ever lands on disk)..."
install_git hxcpp https://github.com/HaxeFoundation/hxcpp v4.3.148

echo
echo "Installing haxelib dependencies (--skip-dependencies, all transitive deps are pinned below)..."
echo "This might take a few moments depending on your internet speed."

haxelib install lime          8.3.2  --quiet --always --skip-dependencies
haxelib install openfl        9.5.2  --quiet --always --skip-dependencies
haxelib install flixel        6.2.0  --quiet --always --skip-dependencies
haxelib install flixel-addons 4.0.1  --quiet --always --skip-dependencies
haxelib install flixel-ui     2.6.5  --quiet --always --skip-dependencies
haxelib install hscript       2.7.0  --quiet --always --skip-dependencies

echo
echo "Installing git dependencies..."
# The interpreter this app exists to demonstrate. Its dev branch, not a release: the sandbox is
# written against the library as it currently is.
install_git hxscript https://github.com/MeguminBOT/hxscript dev
# The widget set the shell is built from. On haxelib as well, but tracked from source for the same
# reason.
install_git smidr    https://github.com/MeguminBOT/SmidrUI

# Building from a checkout of either repository rather than a release? Point haxelib at it and this
# setup stays out of the way:
#
#     haxelib dev hxscript /path/to/hxscript
#     haxelib dev smidr    /path/to/SmidrUI
#
# build.sh does exactly that when it finds a checkout beside this one.

echo
echo "Re-asserting hxcpp = git and wiping any release version folders that snuck in..."
repo_root="$(haxelib config 2>/dev/null | tr -d '\r')"
if [ -n "$repo_root" ] && [ -d "$repo_root/hxcpp" ]; then
	for v in "$repo_root/hxcpp"/*; do
		[ -d "$v" ] || continue
		name="$(basename "$v")"
		if [ "$name" != "git" ]; then
			echo "Removing stray hxcpp version $name ..."
			chmod -R u+w "$v" 2>/dev/null || true
			rm -rf "$v"
		fi
	done
fi
haxelib set hxcpp git --always

echo
echo "Building hxcpp command-line tool from source..."
if [ -f "$repo_root/hxcpp/git/tools/hxcpp/compile.hxml" ]; then
	(cd "$repo_root/hxcpp/git/tools/hxcpp" && haxe compile.hxml)
fi

echo
echo "Setting up lime..."
haxelib run lime setup -alias -y

echo
echo "Finished! Build the sandbox with:  ./build.sh run"
