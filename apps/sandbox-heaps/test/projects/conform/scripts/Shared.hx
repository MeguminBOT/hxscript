/**
 * Statics that change, in a module of their own.
 *
 * A batch is one module, so a class any other module declares is not in it. That is the arrangement
 * every real project is in and the corpus never is: its cases are one file. What this module is for
 * is to be the other file.
 */
class Shared {
	/** Written by one module and read by another, which is what a project's own state looks like. */
	public static var pending:Dynamic = null;

	/** The same as a `Bool`, since that is the shape a flag takes. */
	public static var raised:Bool = false;

	/** And as an `Int`, which is the shape a counter takes. */
	public static var count:Int = 0;

	/** @param value What to hand over. */
	public static function offer(value:Dynamic):Void {
		pending = value;
	}

	/** @return What was handed over, taking it. */
	public static function take():Dynamic {
		var held:Dynamic = pending;
		pending = null;
		return held;
	}
}
