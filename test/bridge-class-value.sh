#!/bin/sh
# Checks that a bridged base whose constructor holds a class as a value still compiles.
#
#   sh test/bridge-class-value.sh
#
# Why this exists. `var cls = Store; cls.created++` types `cls` with the statics of `Store`, which
# `getTypedExpr` names with a path that is the printed type, `Class<Store>`. The rebuilt constructor
# declared it with that path, which nothing declares ("Type not found : Class<Store>"), and
# `Class<Store>` itself has none of the statics.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
WORK="$ROOT/bin_test/bridge-class-value"

rm -rf "$WORK"
mkdir -p "$WORK"

cat > "$WORK/Store.hx" <<'EOF'
class Store {
	public static var created = 0;

	public var id = 0;

	public function new() {
		var cls = Store;
		id = cls.created++;
	}
}
EOF

cat > "$WORK/Subject.hx" <<'EOF'
class Subject {
	static function main() {
		new Store();
		Sys.println("RESULT " + new Store().id + " " + Store.created);
	}
}
EOF


echo "bridge to a base reading a static through its class as a value"
out=$(cd "$WORK" && haxe -cp . -D hxscript_no_banner -D hxscript_bridge_types=Store -lib hxscript -main Subject --interp 2>&1) || true

if printf '%s' "$out" | grep -q '^RESULT 1 2$'; then
	echo "  ok    RESULT 1 2"
	echo "== ok =="
	exit 0
fi

printf '%s\n' "$out" | grep -v '^ ' | sed 's/^/        /' | head -12
echo "== FAILED =="
exit 1
