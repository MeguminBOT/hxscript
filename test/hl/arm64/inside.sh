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
check "loader available" "$(probe 3)" "1"
check "backend it selects" "$(probe 4)" "arm64"

echo
echo "-- the module --"
sh src/hxscript/hl/native/build.sh --hl /opt/hl --out /tmp/hxscript.hdll > /tmp/build.log 2>&1 || {
	echo "  it did not build:"
	sed 's/^/    /' /tmp/build.log
	exit 1
}

check "machine it was built for" "$(readelf -h /tmp/hxscript.hdll | awk -F: '/Machine/{ gsub(/^ +/, "", $2); print $2 }')" "AArch64"
# Counted as hlp_ wrappers, which DEFINE_PRIM makes exactly one of per native. Counting hxscript_
# instead counts the implementations as well, and how many of those there are depends on whether the
# loader was compiled in, which is not what this check is about.
check "natives it offers" "$(nm -D --defined-only /tmp/hxscript.hdll | grep -c ' hlp_')" "21"

# The jit is compiled in rather than linked against, so these are defined here and needed from
# nowhere. A count above zero would mean the module expects an x86 loader to turn up at run time.
check "jit entry points it carries" "$(nm /tmp/hxscript.hdll | grep -c ' [tT] hxs_jit_' || true)" "7"
check "jit symbols it needs from elsewhere" "$(nm -u /tmp/hxscript.hdll | grep -c jit || true)" "0"

gcc -I /opt/hl/include test/hl/arm64/ask.c -o /tmp/ask -ldl -L/opt/hl/lib -lhl
answered=$(/tmp/ask /tmp/hxscript.hdll)

# 0 is HXS_STATE_USABLE and 2 is HXS_ARCH_ARM64, which are also Loader.Availability.Usable and
# Loader.Architecture.Arm64, since the Haxe side reads these numbers straight out of the module. The
# state was 1 for no loader until this branch gave arm64 one.
check "the state it reports" "$(echo "$answered" | cut -d' ' -f1)" "0"
check "the architecture it reports" "$(echo "$answered" | cut -d' ' -f2)" "2"

echo
echo "-- machine code this emitted, run on this machine --"
gcc -O2 -Wall -I src/hxscript/hl/native/arm64 	test/hl/arm64/emit.c src/hxscript/hl/native/arm64/exec.c -o /tmp/emit
/tmp/emit || fail=$((fail + 1))

echo
echo "-- functions the jit compiled, run on this machine --"
N=src/hxscript/hl/native
gcc -O2 -Wall -Wextra -std=c11 -DHXS_NATIVE_TABLE 	-include $N/vendor/hxs_vendor.h -I /opt/hl/include -I $N/vendor/hl116 -I $N/arm64 	test/hl/arm64/jit.c $N/arm64/jit_arm64.c $N/arm64/exec.c $N/vendor/hl116/code.c 	-o /tmp/jit -L/opt/hl/lib -lhl -lm
/tmp/jit || fail=$((fail + 1))

if [ -f bin_test/hlc-arm64/hlc.json ]; then
	echo
	echo "-- the corpus, as a native binary with the jit compiled into it --"

	sh src/hxscript/hl/native/build.sh --hl /opt/hl --hlc bin_test/hlc-arm64 --out /tmp/corpus \
		> /tmp/corpus.log 2>&1 || {
		echo "  it did not build:"
		sed 's/^/    /' /tmp/corpus.log
		fail=$((fail + 1))
	}

	if [ -x /tmp/corpus ]; then
		# From /tmp, because the corpus writes files beside itself and the mount is the repository.
		( cd /tmp && ./corpus > /tmp/corpus.out 2>&1 ) || true

		tail -1 /tmp/corpus.out | sed 's/^/  /'

		# Refused counts as failure here. A refused module is correct behaviour in a shipped program,
		# where it means interpreting instead, but in this suite it means the jit did not compile
		# something it is supposed to and the result proves nothing about the code it would have made.
		if ! grep -q ', 0 failed ==, 0 refused' /tmp/corpus.out; then
			echo "  the corpus did not come back clean:"
			tail -20 /tmp/corpus.out | sed 's/^/    /'
			fail=$((fail + 1))
		fi
	fi
fi

if [ -f bin_test/vm/real.hl ]; then
	echo
	echo "-- hashlink's own VM, built with this jit in place of its own --"

	# jit.c is what hashlink builds hl.exe out of, and this replaces exactly that file. No renaming
	# here: the vendored copy is renamed for hxScript's module so the two cannot meet in one process,
	# and hashlink's own module.c calls the names as they are.
	( cd /opt/hashlink && gcc -O2 -std=c11 -I src -I /work/src/hxscript/hl/native/arm64 \
		-D LIBHL_EXPORTS src/code.c src/main.c src/module.c src/debugger.c src/profile.c \
		/work/src/hxscript/hl/native/arm64/jit_arm64.c /work/src/hxscript/hl/native/arm64/exec.c \
		-o /tmp/hl -L/opt/hl/lib -lhl -lm -ldl -lpthread ) > /tmp/vm.log 2>&1 || {
		echo "  the VM did not build:"
		sed 's/^/    /' /tmp/vm.log
		fail=$((fail + 1))
	}

	if [ -x /tmp/hl ]; then
		( cd bin_test/vm && /tmp/hl real.hl > /tmp/vm.out 2>&1 ) || true
		( cd bin_test/vm && /tmp/hl harder.hl >> /tmp/vm.out 2>&1 ) || true
		sed 's/^/  /' /tmp/vm.out

		# Each line is checkable by eye, so the answers are named rather than counted.
		for want in 'loop      285' 'array     6 6' 'map       42' 'object    hello world' \
			'enum      42' 'catch     thrown' 'anon      7' 'string    ab 1.5' \
			'sorted    1,2,3,4,5' 'dynamic   42' 'reflect   42' 'mapped    1,4,9,16,25' \
			'iterate   3' 'fields    2'; do
			grep -qF "$want" /tmp/vm.out || {
				echo "  missing from what it printed: $want"
				fail=$((fail + 1))
			}
		done
	fi
fi

echo
if [ "$fail" = "0" ]; then
	echo "== everything checked passed =="
else
	echo "== $fail failed =="
	exit 1
fi
