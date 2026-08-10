/**
 * Fixture abstract for `AbstractTest` declaring no operators at all, so comparing or combining two
 * of them has to fall back to the values they box rather than to wrapper identity.
 */
@:build(hxscript.macro.Abstract.build())
abstract OpBare(Int) from Int to Int {
	/**
	 * Wraps an underlying value.
	 *
	 * @param v The value to box.
	 */
	public inline function new(v:Int) {
		this = v;
	}

	/** The boxed value. */
	public var raw(get, never):Int;

	inline function get_raw():Int {
		return this;
	}
}
