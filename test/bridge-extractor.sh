#!/bin/sh
# Checks that a bridged base whose constructor switches with an extractor naming a type still compiles.
#
#   sh test/bridge-extractor.sh
#
# Why this exists. The rebuilt constructor lives in another module than its base, so the names the
# body uses are qualified, but a switch's patterns were left as written, extractors included:
# `case (_ == Kinds.BIG => true)` named `Kinds`, imported by the base's module only ("Type not
# found : Kinds"). An extractor's expression is not a pattern. (A constant `Kinds.BIG` declared
# `inline` is still not found: the typed body holds its value, not the type.)
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
WORK="$ROOT/bin_test/bridge-extractor"

rm -rf "$WORK"
mkdir -p "$WORK"
mkdir -p "$WORK/kinds"

cat > "$WORK/kinds/Kinds.hx" <<'EOF'
package kinds;

class Kinds {
	public static var BIG = "big";
}
EOF

cat > "$WORK/Store.hx" <<'EOF'
import kinds.Kinds;

class Store {
	public var label = "";

	public function new(kind:String) {
		switch (kind) {
			case (_ == Kinds.BIG => true):
				label = "B";
			default:
				label = "other";
		}
	}
}
EOF

cat > "$WORK/Subject.hx" <<'EOF'
class Subject {
	static function main() {
		Sys.println("RESULT " + new Store("big").label + " " + new Store("x").label);
	}
}
EOF


echo "bridge to a base switching with an extractor"
out=$(cd "$WORK" && haxe -cp . -D hxscript_no_banner -D hxscript_bridge_types=Store -lib hxscript -main Subject --interp 2>&1) || true

if printf '%s' "$out" | grep -q '^RESULT B other$'; then
	echo "  ok    RESULT B other"
	echo "== ok =="
	exit 0
fi

printf '%s\n' "$out" | grep -v '^ ' | sed 's/^/        /' | head -12
echo "== FAILED =="
exit 1
