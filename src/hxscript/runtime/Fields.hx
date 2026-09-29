package hxscript.runtime;

import hxscript.error.ErrorKind;
import hxscript.error.InterpException;

/**
 * A host object's field, read or written by name from a compiled body.
 *
 * `Reflect.getProperty` answers null for a null object and `Reflect.setProperty` does nothing, where
 * the interpreter raises. A compiled body then ran on past the line the interpreted one stopped at,
 * with a null standing in for whatever it read. Going through here makes both fail at the same point
 * with the same text.
 */
@:keep
class Fields {
	/**
	 * @param o The object.
	 * @param f The field.
	 * @return Its value, through its getter if it has one.
	 */
	public static function get(o:Dynamic, f:String):Dynamic {
		if (o == null)
			invalid(f);

		return Reflect.getProperty(o, f);
	}

	/**
	 * @param o The object.
	 * @param f The field.
	 * @param v What to store, through its setter if it has one.
	 * @return The value stored, because an assignment is an expression.
	 */
	public static function set(o:Dynamic, f:String, v:Dynamic):Dynamic {
		if (o == null)
			invalid(f);

		Reflect.setProperty(o, f, v);
		return v;
	}

	/** @param f The field a null object was asked for. */
	static function invalid(f:String):Void {
		throw new InterpException(null, 'Invalid access to field ' + f, null, EInvalidAccess(f));
	}
}
