/**
 * Shared by every demo, and a module rather than a class on purpose.
 *
 * Scripts are not limited to classes: a module holds the same mix of types a Haxe module does. This
 * one declares an enum, an abstract with an operator, and a class, all of which the demos import and
 * use as though they had been compiled. None of it needs anything from the host.
 *
 * The abstract is the part worth looking at twice. It boxes its underlying value at runtime and
 * carries its operators with it, and when one is handed to a native method expecting an `Int` the
 * interpreter unwraps it on the way through. So `Palette.of(Ink)` can be passed straight to
 * `graphics.beginFill` or `makeGraphic` and mean the colour it holds.
 */
enum Tone {
	Ink;
	Accent;
	Warn;
	Fade(by:Float);
}

/** A packed 0xRRGGBB colour that can be mixed with `+`. */
abstract Rgb(Int) from Int to Int {
	public function new(value:Int) {
		this = value;
	}

	/** Averages two colours channel by channel. */
	@:op(A + B) public function mix(rhs:Rgb):Rgb {
		var other:Int = rhs;
		var r:Int = Std.int((((this >> 16) & 0xFF) + ((other >> 16) & 0xFF)) / 2);
		var g:Int = Std.int((((this >> 8) & 0xFF) + ((other >> 8) & 0xFF)) / 2);
		var b:Int = Std.int(((this & 0xFF) + (other & 0xFF)) / 2);

		return new Rgb((r << 16) | (g << 8) | b);
	}

	/** Scales every channel, clamped. */
	public function scale(by:Float):Rgb {
		var r:Int = clamp(((this >> 16) & 0xFF) * by);
		var g:Int = clamp(((this >> 8) & 0xFF) * by);
		var b:Int = clamp((this & 0xFF) * by);

		return new Rgb((r << 16) | (g << 8) | b);
	}

	static function clamp(v:Float):Int {
		if (v < 0) {
			return 0;
		}
		if (v > 255) {
			return 255;
		}
		return Std.int(v);
	}
}

class Palette {
	public static var ink:Rgb = new Rgb(0xC8D0E0);
	public static var accent:Rgb = new Rgb(0x62D0A0);
	public static var warn:Rgb = new Rgb(0xE08050);

	/**
	 * The colour for a tone, opaque.
	 *
	 * The alpha matters and is easy to lose. Flixel's colours are ARGB, so a plain `0xRRGGBB` is
	 * fully transparent, so `makeGraphic` with one produces a sprite that is there, is the right size,
	 * updates every frame and cannot be seen. `FlxText.color` ignores the alpha, so the labels look
	 * fine while the sprites do not, which is a confusing way to find out.
	 *
	 * @param tone Which tone.
	 * @return Its colour, with full alpha.
	 */
	public static function of(tone:Tone):Int {
		var rgb:Int = switch (tone) {
			case Ink: ink;
			case Accent: accent;
			case Warn: warn;
			case Fade(by): ink.scale(by);
		}

		return 0xFF000000 | rgb;
	}

	/**
	 * A colour stepped around the palette, for spreading a row of things out.
	 *
	 * @param index Which item.
	 * @param count How many there are.
	 * @return A colour between the accent and the ink, with full alpha.
	 */
	public static function step(index:Int, count:Int):Int {
		var t:Float = count <= 1 ? 0 : index / (count - 1);
		var mixed:Rgb = accent.scale(1.0 - t * 0.55) + ink.scale(0.45 + t * 0.55);

		return 0xFF000000 | mixed;
	}
}
