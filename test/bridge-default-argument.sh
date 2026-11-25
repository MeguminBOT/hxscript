#!/bin/sh
# Checks that a bridged base whose constructor iterates an optional, non-basic argument still compiles.
#
#   sh test/bridge-default-argument.sh
#
# Why this exists. The bridge rebuilds its base's constructor as `__constructSuper`, and an argument
# with a default value was left untyped there, so that hxcpp does not compile a `Null<Float>` as
# `Dynamic`. A map argument (`?m:IMap<String, Int>`) became `Dynamic` too, and
# `for (k in m.keys())` in the rebuilt body failed with "You can't iterate on a Dynamic value".
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
WORK="$ROOT/bin_test/bridge-default-argument"

rm -rf "$WORK"
mkdir -p "$WORK"

cat > "$WORK/Store.hx" <<'EOF'
class Store {
	public var count = 0;

	public function new(?m:haxe.Constraints.IMap<String, Int>) {
		if (m != null)
			for (k in m.keys())
				count += m.get(k);
	}
}
EOF

cat > "$WORK/Subject.hx" <<'EOF'
class Subject {
	static function main() {
		var m = new Map<String, Int>();
		m.set("a", 2);
		m.set("b", 3);
		Sys.println("RESULT " + new Store(m).count + " " + new Store().count);
	}
}
EOF


echo "bridge to a base iterating an optional map argument"
out=$(cd "$WORK" && haxe -cp . -D hxscript_no_banner -D hxscript_bridge_types=Store -lib hxscript -main Subject --interp 2>&1) || true

if printf '%s' "$out" | grep -q '^RESULT 5 0$'; then
	echo "  ok    RESULT 5 0"
	echo "== ok =="
	exit 0
fi

printf '%s\n' "$out" | grep -v '^ ' | sed 's/^/        /' | head -12
echo "== FAILED =="
exit 1
