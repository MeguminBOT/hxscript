package hxscript.types;

import hxscript.types.TypeCollection;

using hxscript.types.TypeCollection;

/**
 * Runtime wrapper standing in for an abstract value at interpretation time. It boxes the underlying
 * value; the per-abstract accessors and conversions are filled in by the abstract-building macro.
 */
class AbstractValue {
	/** The wrapped underlying value (macro-overridden per abstract). */
	var value(get, set):Dynamic;

	/** The boxed underlying value. */
	var __a(default, null):Dynamic;

	/**
	 * Wraps an underlying value.
	 *
	 * @param v The value to box.
	 */
	public function new(v:Dynamic) {
		value = v;
	}

	/** @return The boxed value. */
	function get_value():Dynamic {
		return __a;
	}

	/**
	 * @param v The value to box.
	 * @return The boxed value.
	 */
	function set_value(v:Dynamic):Dynamic {
		return __a = v;
	}

	/**
	 * Converts this abstract to one of its `to` target types (macro-overridden per abstract).
	 *
	 * @param t The target type name.
	 * @return The converted value, or null in the base implementation.
	 */
	public function resolveTo(t:String):Dynamic {
		return null;
	}
}
