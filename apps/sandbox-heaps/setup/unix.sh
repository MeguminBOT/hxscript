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

# There is no step here for the script compiler, and that is the difference this app is built to
# show. A HashLink program running on the VM gets one as a .hdll placed beside it, which is a file
# that can be there or not and a decision made after the build. This one is a native binary: the
# loader, the jit and hxScript's runtime are compiled into the executable by ./build.sh, along with
# everything else. Nothing to install, nothing to ship beside it, and nothing that can go missing.

echo
echo "Finished! Build the sandbox with:  ./build.sh run"
