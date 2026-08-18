#!/bin/sh
# What run.sh runs once it is inside the container. Not meant to be run anywhere else: it assumes an
# aarch64 userland with libhl under /opt/hl, which is what the image is.
set -e

fail=0

# Carriage returns are stripped because hashlink ships hl.h with them, so a value read out of a
# header carries one and compares unequal to the same characters written here.
check() {
	set -- "$1" "$(printf '%s' "$2" | tr -d '')" "$3"

	if [ "$2" = "$3" ]; then
		printf '  %-42s %s\n' "$1" "$2"
	else
		printf '  %-42s %s, expected %s\n' "$1" "$2" "$3"
		fail=$((fail + 1))
	fi
}

probe() {
	gcc -E src/hxscript/hl/native/hxs_arch_probe.c | awk '/^hxs_arch /{ print $'"$1"' }' | tail -1 | tr -d '"'
}

echo "-- the machine --"
check "architecture" "$(uname -m)" "aarch64"
check "compiler target" "$(gcc -dumpmachine)" "aarch64-linux-gnu"
check "hashlink" "$(awk '/define HL_VERSION/{ print $3; exit }' /opt/hl/include/hl.h)" "0x011000"

echo
echo "-- what the build works out for itself --"
check "architecture probed" "$(probe 2)" "arm64"
check "loader available" "$(probe NF)" "0"

echo
echo "-- the module --"
sh src/hxscript/hl/native/build.sh --hl /opt/hl --out /tmp/hxscript.hdll > /tmp/build.log 2>&1 || {
	echo "  it did not build:"
	sed 's/^/    /' /tmp/build.log
	exit 1
}

check "machine it was built for" "$(readelf -h /tmp/hxscript.hdll | awk -F: '/Machine/{ gsub(/^ +/, "", $2); print $2 }')" "AArch64"
check "natives it defines" "$(nm -D --defined-only /tmp/hxscript.hdll | grep -c hxscript_)" "21"
check "jit symbols it needs" "$(nm -u /tmp/hxscript.hdll | grep -c jit || true)" "0"

gcc test/hl/arm64/ask.c -o /tmp/ask -ldl
answered=$(/tmp/ask /tmp/hxscript.hdll)

# 1 is HXS_STATE_NO_LOADER and 2 is HXS_ARCH_ARM64, which are also Loader.Availability.NoLoader and
# Loader.Architecture.Arm64, since the Haxe side reads these numbers straight out of the module.
check "the state it reports" "$(echo "$answered" | cut -d' ' -f1)" "1"
check "the architecture it reports" "$(echo "$answered" | cut -d' ' -f2)" "2"

echo
echo "-- machine code this emitted, run on this machine --"
gcc -O2 -Wall -I src/hxscript/hl/native/arm64 	test/hl/arm64/emit.c src/hxscript/hl/native/arm64/exec.c -o /tmp/emit
/tmp/emit || fail=$((fail + 1))

echo
echo "-- functions the jit compiled, run on this machine --"
N=src/hxscript/hl/native
gcc -O2 -Wall -Wextra -std=c11 -DHXS_NATIVE_TABLE 	-include $N/vendor/hxs_vendor.h -I /opt/hl/include -I $N/vendor/hl116 -I $N/arm64 	test/hl/arm64/jit.c $N/arm64/jit_arm64.c $N/arm64/exec.c 	-o /tmp/jit -L/opt/hl/lib -lhl
/tmp/jit || fail=$((fail + 1))

echo
if [ "$fail" = "0" ]; then
	echo "== everything checked passed =="
else
	echo "== $fail failed =="
	exit 1
fi
