#!/bin/sh
# Checks that a record a host pushes into `Presets.custom` reaches the build.
#
#   sh test/preset.sh
#
# The record is pushed from an init macro of the host's, which is the only way to add one, and the
# whole of what this asks is whether it arrives when that macro runs AFTER the setup macro rather
# than before it. Both orders are run, because only the second one was ever broken and a check that
# tried one order could pass while the case that matters fails.
#
# Why this exists. `-lib hxscript` expands `extraParams.hxml` at the position of the `-lib`, and lime
# resolves each haxelib and writes its `extraParams.hxml` at the top of the generated hxml, beside
# that library's class path, while the project's own flags land some fifty lines below. So a host's
# `--macro` is always the later of the two and there is no build file that can reorder them. Until
# 2.0.6 the setup read the list of active libraries as it ran, so the push always landed after the
# list had been taken: the record was accepted, ignored, and never mentioned again. The build
# succeeded, wired nothing for it, and a script failed at runtime with `Type not found` for a class
# the host had plainly described.
#
# Nothing else here covers it. No example, test or sandbox app fills `Presets.custom`, and the two
# apps that describe host classes go through `-D hxscript_host`, which reads a define and scans files
# on disk and so was never sensitive to when it ran.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
WORK="$ROOT/bin_test/preset"

rm -rf "$WORK"
mkdir -p "$WORK/macros" "$WORK/game"

# The host's own init macro. A record naming a package root, which is the part `-D hxscript_host`
# cannot express and so the part that has to come through this route.
cat > "$WORK/macros/Late.hx" <<'EOF'
package macros;

class Late {
	public static function init():Void {
		hxscript.setup.Presets.custom.push({
			define: 'latelib',
			title: 'late record',
			roots: ['game'],
			ignore: [],
			types: [],
			bases: [],
			abstractPackages: [],
			abstracts: [],
			abstractExclude: [],
			globals: []
		});
	}
}
EOF

# Under the root above, and referenced by nothing. Force-compiling it is the record's job, so its
# presence at runtime is what says the root was acted on rather than merely listed.
cat > "$WORK/game/Widget.hx" <<'EOF'
package game;

class Widget {
	public function new() {}
}
EOF

cat > "$WORK/Subject.hx" <<'EOF'
class Subject {
	static function main() {
		var wired:Array<String> = hxscript.wired.Manifest.libraries;
		Sys.println('wired: ' + wired.join(', '));

		if (wired.indexOf('late record') < 0) {
			Sys.println('MISSING-RECORD');
			return;
		}

		// A record's `define` replaces a shipped preset that shares it, so one carrying its own define
		// has to leave the shipped set alone. Asserted because the replacement is silent.
		if (wired.indexOf('hxscript') < 0) {
			Sys.println('LOST-SHIPPED-PRESET');
			return;
		}

		if (Type.resolveClass('game.Widget') == null) {
			Sys.println('MISSING-ROOT');
			return;
		}

		Sys.println('RECORD-WIRED');
	}
}
EOF

# `-D hxscript_no_banner` because the banner prints what was wired and this has to read that from the
# manifest instead: a report agreeing with itself is what made the original failure so quiet.
ask() { # label, flags in order
  label=$1
  shift

  out=$(cd "$WORK" && haxe -cp . -D hxscript_no_banner -D latelib "$@" -main Subject --interp 2>&1) || true

  if printf '%s' "$out" | grep -q 'RECORD-WIRED'; then
    echo "  ok    $label"
    return 0
  fi

  echo "  FAIL  $label"
  printf '%s\n' "$out" | sed 's/^/        /' | head -12
  return 1
}

echo "custom preset record, both macro orders"
failed=0
ask "host macro after the setup macro " -lib hxscript --macro "macros.Late.init()" || failed=1
ask "host macro before the setup macro" --macro "macros.Late.init()" -lib hxscript || failed=1

[ "$failed" = "0" ] || { echo "== FAILED =="; exit 1; }
echo "== ok =="
