/**
 * A host enum abstract whose constants collide with its own accessors.
 *
 * `flixel.util.FlxAxes` is this shape and it is not unusual: constants `X` and `Y` beside properties
 * `x` and `y`. The wrapper cannot give `X` a getter called `get_X` when `get_x` is already there, so
 * it emits the constant as a static built with `new` instead of as a lazy property, and that runs
 * while the class is still booting.
 *
 * That is the whole reason this exists. The constant's construction consulted the enum's value table,
 * which is declared after it and so was still null, and the boot re-entered itself: any program that
 * reached the type died before starting, with a stack naming only the wrapper. `HostFlag` next door
 * has no accessors and so takes the lazy path, which is why it never showed this.
 */
@:build(hxscript.macro.Abstract.build())
enum abstract HostAxes(Int) from Int to Int {
	var NONE = 0x00;
	var X = 0x01;
	var Y = 0x10;
	var XY = 0x11;

	/** An accessor whose name collides with the `X` constant, which is what forces the eager path. */
	public var x(get, never):Bool;

	inline function get_x():Bool {
		return this & 0x01 != 0;
	}

	/** The same for `Y`. */
	public var y(get, never):Bool;

	inline function get_y():Bool {
		return this & 0x10 != 0;
	}
}
