/**
 * Fixture shaped like `flixel.util.FlxColor`, which is the real abstract this library has to survive
 * when a host opts it in: an `Int` underlying with two `from` and two `to` types, `inline` static
 * constants of the abstract's own type (which have no runtime form at all), get/set properties that
 * rewrite `this`, and arithmetic operators.
 */
@:build(hxscript.macro.Abstract.build())
abstract OpColor(Int) from Int from UInt to Int to UInt {
	/** Opaque red, as an inline constant of the abstract's own type. */
	public static inline var RED:OpColor = 0xFFFF0000;

	/** Opaque blue. */
	public static inline var BLUE:OpColor = 0xFF0000FF;

	/** The red channel. */
	public var red(get, set):Int;

	/** The alpha channel, read-only. */
	public var alpha(get, never):Int;

	inline function get_red():Int {
		return (this >> 16) & 0xFF;
	}

	inline function set_red(v:Int):Int {
		this = (this & 0xFF00FFFF) | (v << 16);
		return v;
	}

	inline function get_alpha():Int {
		return (this >> 24) & 0xFF;
	}

	/**
	 * @param v The underlying value.
	 */
	public inline function new(v:Int) {
		this = v;
	}

	/**
	 * @param rhs The colour to add.
	 * @return The channel-wise sum, saturating at 255.
	 */
	@:op(A + B) public function add(rhs:OpColor):OpColor {
		var r:Int = red + (rhs : OpColor).red;
		return new OpColor((this & 0xFF00FFFF) | ((r > 255 ? 255 : r) << 16));
	}

	/**
	 * @return The colour as `AARRGGBB` hex.
	 */
	public function toHexString():String {
		return StringTools.hex(this, 8);
	}
}
