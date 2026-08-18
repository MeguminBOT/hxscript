#!/bin/sh
# The arm64 half, in the container that stands in for a machine this repository does not have.
#
#   sh test/hl/arm64/run.sh             check what arm64 can be checked without hardware
#   sh test/hl/arm64/run.sh --rebuild   build the image again, after changing the Dockerfile
#   sh test/hl/arm64/run.sh --shell     a shell in there, for working on the JIT by hand
#
# Run from the repository root. Needs Docker with linux/arm64 emulation, which Docker Desktop has by
# default; the first run builds an image and compiles libhl under emulation, which takes minutes, and
# every run after that is seconds.
#
# What this is for: hashlink's jit is x86-64 only, so there is no arm64 HashLink to install and no
# arm64 machine here to build one on. Everything below runs on a real aarch64 userland against a
# libhl built from the same hashlink the vendored loader was taken from, which is the only way the
# struct layouts they share can be trusted to line up.
set -e

IMAGE=hxscript-arm64

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)

REBUILD=0
SHELL_ONLY=0

while [ $# -gt 0 ]; do
	case "$1" in
		--rebuild) REBUILD=1; shift ;;
		--shell) SHELL_ONLY=1; shift ;;
		--help|-h) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) echo "unknown argument: $1" >&2; exit 2 ;;
	esac
done

command -v docker >/dev/null 2>&1 || { echo "docker is not on the path" >&2; exit 1; }

docker version >/dev/null 2>&1 || {
	echo "the docker daemon is not answering: start Docker Desktop" >&2
	exit 1
}

# Git for Windows rewrites anything that looks like a path in an argument, which turns a container
# path into a drive letter. This is the documented way to stop it, and it does nothing anywhere else.
MSYS_NO_PATHCONV=1
export MSYS_NO_PATHCONV

# Docker wants a path its own daemon can see, which on Windows is the drive letter form.
if MOUNT=$(cd "$ROOT" && pwd -W 2>/dev/null) && [ -n "$MOUNT" ]; then
	:
else
	MOUNT="$ROOT"
fi

if [ "$REBUILD" = "1" ] || ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
	echo "-- building $IMAGE, which compiles libhl under emulation and is the slow part --"
	docker build --platform linux/arm64 -t "$IMAGE" "$HERE"
fi

if [ "$SHELL_ONLY" = "1" ]; then
	exec docker run --rm -it --platform linux/arm64 -v "$MOUNT:/work" "$IMAGE" /bin/sh
fi

# The corpus that a real module has to get through, generated out here because Haxe is out here and
# the container has none. HL/C is portable C, so what it writes is compiled for arm64 inside.
#
# EmitProbe rather than LoadProbe: the module it loads is one hxScript's own emitter produced, so it
# stays inside the opcodes this jit compiles. LoadProbe loads a module Haxe compiled, which uses the
# rest of the instruction set and is refused rather than run.
if command -v haxe >/dev/null 2>&1; then
	echo "-- generating the HL/C corpus, since Haxe is here and the container has none --"
	rm -rf "$ROOT/bin_test/hlc-arm64"
	( cd "$ROOT" && haxe -cp src -cp test/hl/loader -D hxscript_hl -D hxscript_no_native \
		-D hl-ver=1.16.0 -D no-compilation -main EmitProbe -hl bin_test/hlc-arm64/main.c )

	# An ordinary Haxe program as bytecode, for hashlink's own VM to run on this jit. Nothing to do
	# with hxScript: it is the wider instruction set, which a jit written for the narrower one has no
	# right to handle unless it really is complete.
	mkdir -p "$ROOT/bin_test/vm"
	( cd "$ROOT" && haxe -cp test/hl/arm64/vm -main Real -hl bin_test/vm/real.hl )
	( cd "$ROOT" && haxe -cp test/hl/arm64/vm -main Harder -hl bin_test/vm/harder.hl )
else
	echo "-- no Haxe here, so the corpus is skipped and only the jit's own checks run --" >&2
fi

docker run --rm --platform linux/arm64 -v "$MOUNT:/work" "$IMAGE" sh test/hl/arm64/inside.sh
