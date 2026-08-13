package hxscript.runtime;

import hxscript.error.ErrorKind;
import hxscript.error.InterpException;

/**
 * Raises what the interpreter raises, for a construct that fails when it runs rather than when it
 * compiles.
 *
 * An expression the interpreter throws on is not a reason to refuse a module: refusing costs every
 * other class in it its compiled form over a line that may never run. The compiled form calls this
 * instead, so the failure arrives at the same point with the same type and the same text, and a
 * script catching it cannot tell the two apart.
 */
@:keep
class Raise {
	/**
	 * @param message The text the interpreter would carry.
	 * @return Never returns; declared so a call to it can stand where a value was wanted.
	 */
	public static function custom(message:String):Dynamic {
		throw new InterpException(null, message, null, ECustom(message));
	}
}
