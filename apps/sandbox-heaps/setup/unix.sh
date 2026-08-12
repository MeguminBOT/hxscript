#!/bin/sh
# SETUP FOR MAC AND LINUX SYSTEMS, AND FOR GIT BASH ON WINDOWS
# REMINDER THAT YOU NEED HAXE AND HASHLINK INSTALLED PRIOR TO USING THIS
# https://haxe.org/download
# https://hashlink.haxe.org
#
# Installs everything apps/sandbox-heaps needs into a haxelib repository of its own, so nothing here
# disturbs the libraries the rest of your machine builds against. Run it once, then build:
#
#     sh setup/unix.sh
#     ./build.sh run
cd ..

set -e

echo "Setting up local haxelib repository ..."
haxelib newrepo

install_git () {
	name="$1"
	url="$2"
	ref="$3"
	repo_root="$(haxelib config 2>/dev/null | tr -d '\r')"
	if [ -n "$repo_root" ] && [ -d "$repo_root/$name" ]; then
		echo "Cleaning existing $repo_root/$name ..."
		chmod -R u+w "$repo_root/$name" 2>/dev/null || true
		rm -rf "$repo_root/$name"
	fi
	haxelib git "$name" "$url" $ref --skip-dependencies
}

echo
echo "Installing haxelib dependencies..."
echo "This might take a few moments depending on your internet speed."

# Heaps, and the two it needs. hlsdl rather than hldx because it is the same backend on all three
# platforms; the sdl.hdll it binds to already ships with HashLink.
haxelib install heaps    2.1.0  --quiet --always --skip-dependencies
haxelib install format   3.8.0  --quiet --always --skip-dependencies
haxelib install hlsdl    1.15.0 --quiet --always --skip-dependencies
haxelib install hlopenal 1.5.0  --quiet --always --skip-dependencies

echo
echo "Installing git dependencies..."
# The interpreter this app exists to demonstrate. Its dev branch, not a release: the sandbox is
# written against the library as it currently is.
install_git hxscript https://github.com/MeguminBOT/hxscript dev

# Building from a checkout rather than a release? Point haxelib at it and this setup stays out of
# the way:
#
#     haxelib dev hxscript /path/to/hxscript
#
# build.sh does exactly that when it finds a checkout at this repository.

echo
echo "Building the HashLink extension..."
# What lets a compiled script run rather than only an interpreted one. It needs a hashlink source
# tree matching your VM, and it offers to fetch one if this machine has none. Answering no is fine:
# without the extension every script is interpreted, which costs speed and nothing else.
hdll="$(cd .. 2>/dev/null && pwd)"
if [ -f "../../src/hxscript/hl/hdll.sh" ]; then
	sh ../../src/hxscript/hl/hdll.sh --out export || \
		echo "The extension was not built. Scripts will be interpreted; ./build.sh will say so again."
else
	echo "No checkout of hxscript here, so the extension was skipped."
	echo "Run haxelib run hxscript hdll export once the library is installed."
fi

echo
echo "Finished! Build the sandbox with:  ./build.sh run"
