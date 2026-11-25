package hxscript.runtime;

import hxscript.error.ErrorKind;
import hxscript.error.InterpException;

/**
 * A host object's field, read or written by name from a compiled body.
 *
 * `Reflect.getProperty` answers null for a null object and `Reflect.setProperty` does nothing. With
 * `Config.strictNullAccess` both raise here instead, with the interpreter's text, so a compiled body
 * stops at the line an interpreted one stops at. Without it they keep doing what they always did.
 */
@:keep
class Fields {
	/**
	 * @param o The object.
	 * @param f The field.
	 * @return Its value, through its getter if it has one.
	 */
	public static function get(o:Dynamic, f:String):Dynamic {
		if (o == null && Config.strictNullAccess)
			nullAccess(f);

		return Reflect.getProperty(o, f);
	}

	/**
	 * @param o The object.
	 * @param f The field.
	 * @param v What to store, through its setter if it has one.
	 * @return The value stored, because an assignment is an expression.
	 */
	public static function set(o:Dynamic, f:String, v:Dynamic):Dynamic {
		if (o == null && Config.strictNullAccess)
			nullAccess(f);

		Reflect.setProperty(o, f, v);
		return v;
	}

	/** @param f The field a null object was asked for. */
	static function nullAccess(f:String):Void {
		throw new InterpException(null, 'Null access to field ' + f, null, ENullAccess(f));
	}
}
