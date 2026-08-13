#!/bin/sh
# Builds the native module, a guest and a host, and checks that the host can load the guest.
#
#   sh test/hl/loader/run.sh              on the VM, then again as a native binary
#   sh test/hl/loader/run.sh --hl DIR     the HashLink installation to build against
#   sh test/hl/loader/run.sh --vm-only    skip the native binary, which is the slow half
#
# Run from the repository root. The VM half lands in bin_test/hl/loader, including the .hdll, which
# has to be beside what is running for HashLink to find it. The native half lands in bin_test/hlc.
#
# Both halves matter and they are not the same test. On the VM the loader arrives as a library beside
# the program, and the host it has to leave alone is the VM's own module. In an HL/C binary there is
# no library and no VM: the loader is compiled in, and the host it has to leave alone is generated C
# whose dynamic calls and exception unwinding go through different machinery. A load takes five
# fields of hl_setup on the VM and six here, so the half that is skipped is the half that would not
# have been checked.
set -e

ROOT=$(pwd)
OUT="$ROOT/bin_test/hl/loader"
HLC="$ROOT/bin_test/hlc/probe"
HL=${HLPATH:-}
NATIVE=1

while [ $# -gt 0 ]; do
	case "$1" in
		--hl) HL=$2; shift 2 ;;
		--vm-only) NATIVE=0; shift ;;
		*) echo "unknown argument: $1" >&2; exit 2 ;;
	esac
done

mkdir -p "$OUT"

if [ -n "$HL" ]; then
	sh src/hxscript/hl/native/build.sh --hl "$HL" --out "$OUT/hxscript.hdll"
else
	sh src/hxscript/hl/native/build.sh --out "$OUT/hxscript.hdll"
fi

haxe -cp test/hl/loader -main Guest -hl "$OUT/guest.hl"
haxe -cp src -cp test/hl/loader -D hxscript_hl -main LoadProbe -hl "$OUT/probe.hl"
haxe -cp src -cp test/hl/loader -D hxscript_hl -main WriterProbe -hl "$OUT/writer.hl"

cd "$OUT"

if command -v hl >/dev/null 2>&1; then
	VM=hl
elif [ -n "$HL" ] && [ -x "$HL/hl.exe" ]; then
	VM="$HL/hl.exe"
elif [ -n "$HL" ] && [ -x "$HL/hl" ]; then
	VM="$HL/hl"
else
	echo "no HashLink VM to run with: put hl on PATH or pass --hl DIR" >&2
	exit 1
fi

echo "-- on the VM, with the module beside it --"
"$VM" probe.hl guest.hl
"$VM" writer.hl

[ "$NATIVE" = "1" ] || exit 0

cd "$ROOT"

echo
echo "-- as a native binary, with the module compiled in --"

mkdir -p "$HLC"

# hl-ver is given because it decides what the generated C expects of libhl, and the loader compiled
# in beside it shares structure layouts with that same libhl. no-compilation is because Haxe would
# otherwise hand the native build to the hashlink haxelib, which knows nothing about compiling this
# module in.
haxe -cp src -cp test/hl/loader -D hxscript_hl -D hl-ver=1.16.0 -D no-compilation -main LoadProbe -hl "$HLC/main.c"

if [ -n "$HL" ]; then
	sh src/hxscript/hl/native/build.sh --hl "$HL" --hlc "$HLC" --out "$HLC/LoadProbe.exe"
else
	sh src/hxscript/hl/native/build.sh --hlc "$HLC" --out "$HLC/LoadProbe.exe"
fi

cp "$OUT/guest.hl" "$HLC/"
[ -n "$HL" ] && [ -f "$HL/libhl.dll" ] && cp "$HL/libhl.dll" "$HLC/"

cd "$HLC"

if [ -x ./LoadProbe.exe ]; then
	./LoadProbe.exe guest.hl
else
	./LoadProbe guest.hl
fi
