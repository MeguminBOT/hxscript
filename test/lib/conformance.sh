#!/bin/sh
# Collects one conformance column per execution mode, surviving cases that end the process.
#
#   sh test/lib/conformance.sh                   every mode
#   sh test/lib/conformance.sh hxcpp-cppia hxcpp-cppia-jit   just those
#   NOBUILD=1 sh test/lib/conformance.sh hxcpp-cppia   run what is already built
#
# The modes, and what each one actually is:
#
#   eval-interp  the tree-walking interpreter on eval, for iterating on the interpreter
#   hxcpp-interp   the tree-walking interpreter on hxcpp, which is what hxcpp-cppia is compared against
#   hxcpp-cppia        hxcpp bytecode, the JIT off
#   hxcpp-cppia-jit    the same bytecode with the JIT on
#   hl-interp   the tree-walking interpreter inside an HL/C binary, with no loader linked
#   hl-bytecode      HashLink bytecode inside an HL/C binary, loaded and jitted
#
# A column is a file of tab-separated rows under bin_test/conformance. Nothing here compares them:
# `Table` does that, because a runner that decided what agreement meant would have to be built into
# every column, and then a column could disagree about the definition.
#
# **A case can abort rather than throw.** hxcpp's cppia has taken the process down more than once, so
# a run that stops early is resumed past whatever killed it and that case is recorded as `killed`,
# which is the most important reading about it rather than one to lose.
set -eu

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=${OUT:-$ROOT/bin_test/conformance}
LIMIT=${LIMIT:-1000}
NOBUILD=${NOBUILD:-0}
HL=${HLPATH:-/c/hashlink/hashlink-1.16.0-win}

CP="-cp $ROOT/src -cp $ROOT/test/common -cp $ROOT/test/common/fixtures -cp $ROOT/test/lib"

# What `-lib hxscript` applies for a real host, plus one bridged base. Without the autowire step no
# bridge is generated at all, and the case that extends a host class then cannot work interpreted
# however correct the interpreter is, which reads as the compiler disagreeing with it. Naming the
# base is what a host does; the harness has to do it too or it is testing a configuration nobody
# ships. The base is a fixture rather than a standard-library class because a bridge has to be
# generatable at all and most of the library is not: `StringBuf` and `haxe.io.BytesBuffer` inline an
# abstract's constructor, and `haxe.Timer` starts a real timer and ended the run.
KEEP="--macro hxscript.macro.Keep.run() --macro hxscript.setup.Autowire.run() -D hxscript_bridge_types=HostBase,HostQuirk,HostShaped -D hxscript_keep=haxe.Json,haxe.ds.Option,HostVec,HostVecImpl,HostFlag,HostDial,HostTint,HostAxes"

cd "$ROOT"
mkdir -p "$OUT"

# Whether this run has already built the binary hxcpp-cppia and hxcpp-cppia-jit share.
CPPIA_BUILT=0

ALL="eval-interp hxcpp-interp hxcpp-cppia hxcpp-cppia-jit hl-interp hl-bytecode"
MODES=${*:-$ALL}

# Builds a mode, unless it shares a binary with one already built.
build() {
	[ "$NOBUILD" = "1" ] && return 0

	case "$1" in
		eval-interp)
			return 0
			;;
		hxcpp-interp)
			# The same build as `hxcpp-cppia` apart from the emitter, and that matters more than it looks.
			# Built without `-dce no` this column loses the standard-library members a script reaches
			# by reflection, and then every row where compiled code linked one directly reads as the
			# compiler disagreeing with the interpreter. Three rows were that and nothing else.
			haxe $CP $KEEP -D scriptable -dce no -main ConformanceProbe -cpp "$OUT/hxcpp-interp"
			;;
		hxcpp-cppia|hxcpp-cppia-jit)
			# Built once for the two modes that share it, and once per RUN rather than once ever.
			# Testing for the binary alone skipped the build whenever a previous run had left one,
			# so both columns were collected from whatever the branch looked like then: the first
			# reading taken this way was 38 rows out, every one of them a case shifted by one
			# because the stale binary had a shorter list.
			[ "$CPPIA_BUILT" = "1" ] && return 0
			rm -rf "$OUT/hxcpp-cppia"
			haxe $CP $KEEP -D scriptable -D hxscript_cppia -dce no -main ConformanceProbe -cpp "$OUT/hxcpp-cppia"
			CPPIA_BUILT=1
			;;
		hl-interp)
			# One argument, split on the way in. Passed as two it arrives as `-D` alone, the define
			# is dropped, and what builds is a program with no main that prints nothing.
			hlc "$1" "-D hxscript_no_jit"
			;;
		hl-bytecode)
			hlc "$1"
			;;
		*)
			echo "conformance.sh: no mode called '$1'" >&2
			exit 2
			;;
	esac
}

# Generates C for the probe and links it natively.
#
# Through the setup a host gets from `-lib hxscript` rather than through the build script beside the
# sources, so that what is tested is the route a host actually takes: one haxe command, and the
# native module compiled into the binary by the same macro that wired everything else in.
hlc() {
	dir="$OUT/$1"
	rm -rf "$dir"

	HLPATH="$HL" haxe $CP $KEEP -D hxscript_hl -D hl-ver=1.16.0 -D no-compilation \
		${2:-} -main ConformanceProbe -hl "$dir/main.c"

	# Nothing here names the binary. `-D hxscript_hl` is the whole of what a host writes, and what it
	# leaves is the C file's own name, so this checks for that rather than for a name it asked for.
	[ -f "$dir/main.exe" ] || { echo "no binary was linked for $1" >&2; exit 1; }

	# The binary links libhl by path and then has to find it again when it runs. The `|| true` is not
	# decoration: the last name in the list is absent on every platform but one, so without it the
	# loop leaves a failure behind and `set -e` ends the run after a successful build.
	for lib in libhl.dll libhl.so libhl.dylib; do
		[ -f "$HL/$lib" ] && cp "$HL/$lib" "$dir/" || true
	done
}

# The command that runs a mode, and the directory to run it from. Run from beside the binary,
# because that is where each looks for what it needs.
where() {
	case "$1" in
		eval-interp) echo "$ROOT" ;;
		hxcpp-interp) echo "$OUT/hxcpp-interp" ;;
		hxcpp-cppia|hxcpp-cppia-jit) echo "$OUT/hxcpp-cppia" ;;
		hl-interp|hl-bytecode) echo "$OUT/$1" ;;
	esac
}

runner() {
	case "$1" in
		eval-interp) echo "haxe $CP $KEEP -main ConformanceProbe --interp" ;;
		hxcpp-interp) echo "./ConformanceProbe.exe" ;;
		hxcpp-cppia) echo "./ConformanceProbe.exe --nojit" ;;
		hxcpp-cppia-jit) echo "./ConformanceProbe.exe" ;;
		hl-interp|hl-bytecode) echo "./main.exe" ;;
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

		# Only well-formed rows. A dying runtime prints its own complaint on the way out, so anything
		# not `<number><tab>` is noise here.
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
	# has: two rounds of results were read off a column whose build had been failing since the round
	# before, and a stale column is worse than a missing one because the table reports it as
	# collected.
	rm -f "$OUT/$mode.tsv"

	build "$mode"
	collect "$mode"
done

printf '\ncolumns are in %s\n' "$OUT" >&2
