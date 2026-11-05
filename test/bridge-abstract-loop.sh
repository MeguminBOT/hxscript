#!/bin/sh
# Checks that a bridged base whose constructor loops over an abstract with an inline iterator still compiles.
#
#   sh test/bridge-abstract-loop.sh
#
# Why this exists. The bridge rebuilds its base's constructor from `getTypedExpr`, which prints the
# iterator such a loop calls (OpenFL's `Vector` is an abstract over an interface) as
# `for (x in (cast v).iterator())`. That `cast` has no type, so the rebuilt loop iterated a `Dynamic`
# value, which the compiler rejects.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
WORK="$ROOT/bin_test/bridge-abstract-loop"

rm -rf "$WORK"
mkdir -p "$WORK"

cat > "$WORK/Bag.hx" <<'EOF'
interface IBag<T> {
	function iterator():Iterator<T>;
}

class ArrayBag<T> implements IBag<T> {
	var items:Array<T>;

	public function new(items:Array<T>)
		this.items = items;

	public function iterator():Iterator<T>
		return items.iterator();
}

abstract Bag<T>(IBag<T>) {
	public function new(items:Array<T>)
		this = new ArrayBag(items);

	public inline function iterator():Iterator<T>
		return this.iterator();
}
EOF

cat > "$WORK/Store.hx" <<'EOF'
class Store {
	public var count = 0;

	public function new(v:Bag<Int>) {
		for (x in v)
			count += x;
	}
}
EOF

cat > "$WORK/Subject.hx" <<'EOF'
class Subject {
	static function main() {
		Sys.println("RESULT " + new Store(new Bag([1, 2])).count);
	}
}
EOF


echo "bridge to a base looping over an abstract"
out=$(cd "$WORK" && haxe -cp . -D hxscript_no_banner -D hxscript_bridge_types=Store -lib hxscript -main Subject --interp 2>&1) || true

if printf '%s' "$out" | grep -q '^RESULT 3$'; then
	echo "  ok    RESULT 3"
	echo "== ok =="
	exit 0
fi

printf '%s\n' "$out" | grep -v '^ ' | sed 's/^/        /' | head -12
echo "== FAILED =="
exit 1
