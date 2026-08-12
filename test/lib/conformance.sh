#!/bin/sh
# Collects one conformance column per execution mode, surviving cases that end the process.
#
#   sh test/lib/conformance.sh                   every mode this machine can build
#   sh test/lib/conformance.sh cppia cppia-jit   just those
#   NOBUILD=1 sh test/lib/conformance.sh cppia   run what is already built
#
# The modes, and what each one actually is:
#
#   eval-interp  the tree-walking interpreter on eval, for iterating on the interpreter
#   cpp-interp   the tree-walking interpreter on hxcpp, which is what cppia is compared against
#   cppia        hxcpp bytecode, the JIT off
#   cppia-jit    the same bytecode with the JIT on
#   hlc-interp   the tree-walking interpreter inside an HL/C binary, with no loader linked
#   hlc-jit      HashLink bytecode inside an HL/C binary, loaded and jitted
#
# A column is a file of tab-separated rows under bin_test/conformance. Nothing here compares them:
# `Table` does that, because a runner that decided what agreement meant would have to be built into
# every column, and then a column could disagree about the definition.
#
# **A case can abort rather than throw.** A bad constant reaches HashLink's jit as an assert and
# nothing in Haxe runs afterwards, and hxcpp's cppia has taken the process down more than once. So a
# run that stops early is resumed past whatever killed it and that case is recorded as `killed`,
# which is the most important reading about it rather than one to lose.
set -eu

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=${OUT:-$ROOT/bin_test/conformance}
LIMIT=${LIMIT:-1000}
NOBUILD=${NOBUILD:-0}
HL=${HLPATH:-/c/hashlink/hashlink-1.16.0-win}
HL_SRC=${HL_SRC:-/c/hashlink/src-1.16}
[ -d "$HL_SRC" ] || HL_SRC=

CP="-cp $ROOT/src -cp $ROOT/test/common -cp $ROOT/test/common/fixtures -cp $ROOT/test/lib"

# What `-lib hxscript` applies for a real host, plus one bridged base. Without the autowire step no
# bridge is generated at all, and the case that extends a host class then cannot work interpreted
# however correct the interpreter is, which reads as the compiler disagreeing with it. Naming the
# base is what a host does; the harness has to do it too or it is testing a configuration nobody
# ships. The base is a fixture rather than a standard-library class because a bridge has to be
# generatable on EVERY target and most of the library is not: `StringBuf` and `haxe.io.BytesBuffer`
# inline an abstract's constructor and are refused on HashLink, and `haxe.Timer` starts a real timer
# and ended the run. Checking that costs a real `-hl` generation, since `--no-output` does not reach
# the bridge macro's own complaint.
KEEP="--macro hxscript.macro.Keep.run() --macro hxscript.setup.Autowire.run() -D hxscript_bridge_types=HostBase -D hxscript_keep=haxe.Json,haxe.ds.Option"

cd "$ROOT"
mkdir -p "$OUT"

ALL="eval-interp cpp-interp cppia cppia-jit hlc-interp hlc-jit"
MODES=${*:-$ALL}

# Builds a mode, unless it shares a binary with one already built.
build() {
	[ "$NOBUILD" = "1" ] && return 0

	case "$1" in
		eval-interp)
			return 0
			;;
		cpp-interp)
			# The same build as `cppia` apart from the emitter, and that matters more than it looks.
			# Built without `-dce no` this column loses the standard-library members a script reaches
			# by reflection, and then every row where compiled code linked one directly reads as the
			# compiler disagreeing with the interpreter. Three rows were that and nothing else.
			haxe $CP $KEEP -D scriptable -dce no -main ConformanceProbe -cpp "$OUT/cpp-interp"
			;;
		cppia|cppia-jit)
			[ -f "$OUT/cppia/ConformanceProbe.exe" ] && return 0
			haxe $CP $KEEP -D scriptable -D hxscript_cppia -dce no -main ConformanceProbe -cpp "$OUT/cppia"
			;;
		hlc-interp)
			hlc "$1" --no-jit
			;;
		hlc-jit)
			hlc "$1"
			;;
		*)
			echo "conformance.sh: no mode called '$1'" >&2
			exit 2
			;;
	esac
}

# Generates C for the probe and links it natively, through the library's own tooling so that what is
# tested is what ships.
hlc() {
	dir="$OUT/$1"
	rm -rf "$dir"

	haxe $CP $KEEP -D hxscript_hl -D hxscript_no_hdll -main ConformanceProbe -hl "$dir/main.c" 2>&1 \
		| grep -v "Library hashlink is not installed\|^Error: Build failed" || true

	[ -f "$dir/main.c" ] || { echo "no C was generated for $1" >&2; exit 1; }

	# Told rather than guessed. hlc.sh finds a runtime and a source tree on its own and asks before
	# fetching one, and nothing here is attached to a terminal to answer.
	src=""
	[ -n "$HL_SRC" ] && src="--src $HL_SRC"

	sh src/hxscript/hl/hlc.sh "$dir" --hl "$HL" $src --out "$dir/probe.exe" ${2:-} >/dev/null

	# The binary links libhl by path and then has to find it again when it runs. The `|| true` is not
	# decoration: the last name in the list is absent on every platform but one, so without it the
	# loop leaves a failure behind and `set -e` ends the run after a successful build.
	for lib in libhl.dll libhl.so libhl.dylib; do
		[ -f "$HL/$lib" ] && cp "$HL/$lib" "$dir/" || true
	done
}

# The command that runs a mode, and the directory to run it from. Run from beside the binary,
# because that is where each looks for what it needs, and a HashLink build that cannot find its
# loader reports every single case refused, which reads like a result and is not one.
where() {
	case "$1" in
		eval-interp) echo "$ROOT" ;;
		cpp-interp) echo "$OUT/cpp-interp" ;;
		cppia|cppia-jit) echo "$OUT/cppia" ;;
		hlc-interp|hlc-jit) echo "$OUT/$1" ;;
	esac
}

runner() {
	case "$1" in
		eval-interp) echo "haxe $CP $KEEP -main ConformanceProbe --interp" ;;
		cpp-interp) echo "./ConformanceProbe.exe" ;;
		cppia) echo "./ConformanceProbe.exe --nojit" ;;
		cppia-jit) echo "./ConformanceProbe.exe" ;;
		hlc-interp|hlc-jit) echo "./probe.exe" ;;
	esac
}

# One column, resuming past anything that ends the process.
collect() {
	mode=$1
	file="$OUT/$mode.tsv"
	: > "$file"

	dir=$(where "$mode")
	run=$(runner "$mode")
	log="$OUT/$mode.log"
	: > "$log"
	at=0

	# **Stderr goes to a file and never to /dev/null.** On Windows a shell's /dev/null is NUL, and an
	# hxcpp binary writing its first report to it ends there and then: nine cases read as having
	# killed the process, every one of them a refusal that had simply printed its reason. Keeping the
	# stream also keeps the reasons, which is what a refusal is worth reading for.
	while [ "$at" -lt "$LIMIT" ]; do
		out=$(cd "$dir" && HXS_CONFORMANCE="--rows --from $at" $run 2>>"$log" || true)

		# Only well-formed rows. A dying runtime prints its own complaint on the way out, and
		# HashLink's jit puts its assert on stdout, so anything not `<number><tab>` is noise here.
		got=$(printf '%s\n' "$out" | grep -E '^[0-9]+	' || true)
		[ -n "$got" ] && printf '%s\n' "$got" >> "$file"

		printf '%s' "$out" | grep -q '^#done' && break

		if [ -z "$got" ]; then
			# Nothing came back before it died, so the case being resumed at is the one that aborts.
			culprit=$at
		else
			# It died after the last row it printed, so the next one is the culprit.
			culprit=$(( $(printf '%s\n' "$got" | tail -1 | cut -f1) + 1 ))
		fi

		printf '%s\tcase %s\tkilled\tinterp\tended the process\n' "$culprit" "$culprit" >> "$file"
		at=$((culprit + 1))
		printf '  %s: resuming at %s\n' "$mode" "$at" >&2
	done

	printf '%-12s %s rows\n' "$mode" "$(wc -l < "$file" | tr -d ' ')" >&2
}

for mode in $MODES; do
	printf '\n=== %s ===\n' "$mode" >&2

	# The old column goes before the build does, so a build that fails cannot leave one behind. It
	# has: two rounds of results were read off a HashLink column whose build had been failing since
	# the round before, and a stale column is worse than a missing one because the table reports it
	# as collected.
	rm -f "$OUT/$mode.tsv"

	build "$mode"
	collect "$mode"
done

printf '\ncolumns are in %s\n' "$OUT" >&2
