#!/bin/sh
# Builds the native module, a guest and a host, and checks that the host can load the guest.
#
#   sh test/hl/loader/run.sh              build everything and run it
#   sh test/hl/loader/run.sh --hl DIR     the HashLink installation to build against
#
# Run from the repository root. Everything lands in bin_test/hl/loader, including the .hdll, which
# has to be beside what is running for HashLink to find it.
set -e

ROOT=$(pwd)
OUT="$ROOT/bin_test/hl/loader"
HL=${HLPATH:-}

while [ $# -gt 0 ]; do
	case "$1" in
		--hl) HL=$2; shift 2 ;;
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

"$VM" probe.hl guest.hl
"$VM" writer.hl
