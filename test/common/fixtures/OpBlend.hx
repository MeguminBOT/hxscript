/**
 * Fixture shaped like `openfl.display.BlendMode` and `flixel.util.FlxAxes`: an `enum abstract`, which
 * is what scripts actually hold when they hold an abstract at all.
 *
 * Its constants are the interesting part. They have no runtime form whatsoever, because an enum abstract IS
 * its underlying value once compiled, and `OpBlend.ADD` is a `String` at the call site and nothing anywhere
 * else. The wrapper gives the interpreter something to read them from, and the emitter has to fold them into
 * the value at the point of use.
 */
@:build(hxscript.macro.Abstract.build())
enum abstract OpBlend(String) from String to String {
	/** Additive, the one a script reaches for. */
	var ADD = 'add';

	/** Ordinary alpha blending. */
	var NORMAL = 'normal';

	/**
	 * Something that is not a constant, so the emitter has a member it must refuse rather than
	 * mis-link.
	 *
	 * @param name The blend name.
	 * @return Whether it is additive.
	 */
	public static function additive(name:String):Bool {
		return name == 'add';
	}
}
