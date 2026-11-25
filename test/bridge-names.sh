#!/bin/sh
# Checks that two bridged bases whose names differ only in case get bridges whose names differ in
# more than case.
#
#   sh test/bridge-names.sh
#
# Why this exists. hxcpp writes each class to a file named after it, and Windows and macOS do not
# tell `ScriptedWebSocketEvent.h` from `ScriptedWebsocketEvent.h`. openfl with AIR's
# `openfl.events.WebSocketEvent` also has `openfl.net._internal.websocket.WebsocketEvent`, and the
# two bridges were named after them as they were: the build passed on Linux, while on Windows and
# macOS one file overwrote the other and `__boot__.cpp` failed to compile. The names are read from
# the manifest under `--interp`, so this fails on any system, not only on those two.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
WORK="$ROOT/bin_test/bridge-names"

rm -rf "$WORK"
mkdir -p "$WORK/macros" "$WORK/game/a" "$WORK/game/b"

cat > "$WORK/macros/Bases.hx" <<'EOF'
package macros;

class Bases {
	public static function init():Void {
		hxscript.setup.Presets.custom.push({
			define: 'baseslib',
			title: 'bases',
			roots: ['game'],
			ignore: [],
			types: [],
			bases: ['game.a.WebSocketEvent', 'game.b.WebsocketEvent'],
			abstractPackages: [],
			abstracts: [],
			abstractExclude: [],
			globals: []
		});
	}
}
EOF

cat > "$WORK/game/a/WebSocketEvent.hx" <<'EOF'
package game.a;

class WebSocketEvent {
	public function new() {}
}
EOF

cat > "$WORK/game/b/WebsocketEvent.hx" <<'EOF'
package game.b;

class WebsocketEvent {
	public function new() {}
}
EOF

cat > "$WORK/Subject.hx" <<'EOF'
class Subject {
	static function main() {
		var names:Array<String> = [];

		for (bridge in hxscript.wired.Manifest.bridges) {
			var base:Class<Dynamic> = Type.getSuperClass(bridge);
			if (base == game.a.WebSocketEvent || base == game.b.WebsocketEvent)
				names.push(Type.getClassName(bridge));
		}

		Sys.println('bridges: ' + names.join(', '));

		if (names.length != 2) {
			Sys.println('MISSING-BRIDGE');
			return;
		}

		if (names[0].toLowerCase() == names[1].toLowerCase()) {
			Sys.println('SAME-NAME-IGNORING-CASE');
			return;
		}

		Sys.println('NAMES-DISTINCT');
	}
}
EOF

echo "bridges to bases named alike but for case"
out=$(cd "$WORK" && haxe -cp . -D hxscript_no_banner -D baseslib -lib hxscript --macro "macros.Bases.init()" -main Subject --interp 2>&1) || true

if printf '%s' "$out" | grep -q 'NAMES-DISTINCT'; then
	echo "  ok    $(printf '%s' "$out" | grep 'bridges:')"
	echo "== ok =="
	exit 0
fi

printf '%s\n' "$out" | sed 's/^/        /' | head -12
echo "== FAILED =="
exit 1
