/**
 * A bridged base whose constructor inlines a public function that calls a private one.
 *
 * The private function calls itself, so the call survives inlining. The rebuilt constructor is a
 * method of the subclass and cannot name that private static.
 */
class HostPrivateStatic {
	public function new(value:Dynamic) {
		var n:Float = shown(value);
		if (n != n)
			n = 0;
	}

	public static inline function shown(value:Dynamic):Float {
		return hidden(value);
	}

	static inline function hidden(value:Dynamic):Float {
		if (Std.isOfType(value, Array)) {
			var items:Array<Dynamic> = cast value;
			return switch (items.length) {
				case 0: 0;
				case 1: hidden(items[0]);
				default: Math.NaN;
			}
		}
		return if (value == null) 0 else 1;
	}
}
