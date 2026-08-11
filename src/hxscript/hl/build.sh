#!/bin/sh
# Runs the HashLink probe chain, building the extension it needs first.
#
#   sh src/hxscript/hl/build.sh          # just the extension
#   sh src/hxscript/hl/build.sh test     # the extension, then every probe
#
# The extension is built by hdll.sh beside this, which finds the VM, reads its version, finds a
# matching hashlink source tree and picks a compiler, so nothing here has to be told any of that.
# HLPATH, HL_SRC and CC override what it works out.
set -e

OUT=${OUT:-bin/hl}
mkdir -p "$OUT"

sh "$(dirname "$0")/hdll.sh" --out "$OUT" --yes

if [ "$1" = "test" ]; then
	# Whatever the extension was built against, so the probes run on the VM it matches.
	HL=${HL:-${HLPATH:+$HLPATH/hl}}
	HL=${HL:-hl}

	haxe -cp test/hl/loader -main Guest -hl "$OUT/guest.hl"
	haxe -cp src -cp test/hl/loader -D hxscript_hl -main LoadProbe -hl "$OUT/loadprobe.hl"
	( cd "$OUT" && "$HL" loadprobe.hl guest.hl )

	haxe -cp src -cp test/hl/loader -D hxscript_hl -main WriterProbe -hl "$OUT/writerprobe.hl"
	( cd "$OUT" && "$HL" writerprobe.hl )

	haxe -cp src -cp test/hl/loader -D hxscript_hl --macro "hxscript.macro.Keep.run()" -main EmitProbe -hl "$OUT/emitprobe.hl"
	( cd "$OUT" && "$HL" emitprobe.hl )

	haxe -cp src -cp test/hl/loader -D hxscript_hl --macro "hxscript.macro.Keep.run()" -main HostProbe -hl "$OUT/hostprobe.hl"
	( cd "$OUT" && "$HL" hostprobe.hl )
fi
