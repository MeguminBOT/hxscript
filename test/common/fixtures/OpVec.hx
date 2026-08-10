/**
 * Fixture abstract for `AbstractTest`. Each operator deliberately returns something the underlying
 * `Int` arithmetic would not, so a test can tell an `@:op` dispatch apart from a fallback to the
 * boxed value.
 */
@:build(hxscript.macro.Abstract.build())
abstract OpVec(Int) from Int to Int {
	/**
	 * Wraps an underlying value.
	 *
	 * @param v The value to box.
	 */
	public inline function new(v:Int) {
		this = v;
	}

	/** The zero vector, a static of the abstract's own type. */
	public static var ZERO:OpVec = 0;

	/** The boxed value. */
	public var raw(get, never):Int;

	inline function get_raw():Int {
		return this;
	}

	/**
	 * @param rhs The right operand.
	 * @return The sum, scaled so it cannot be confused with plain `Int` addition.
	 */
	@:op(A + B) public function add(rhs:OpVec):OpVec {
		return new OpVec(this + (rhs : Int) * 10);
	}

	/**
	 * @param rhs The right operand.
	 * @return The difference, scaled so it cannot be confused with plain `Int` subtraction.
	 */
	@:op(A - B) public function sub(rhs:OpVec):OpVec {
		return new OpVec(this - (rhs : Int) * 10);
	}

	/**
	 * @param rhs The right operand.
	 * @return The product, offset so it cannot be confused with plain `Int` multiplication.
	 */
	@:op(A * B) public function mul(rhs:OpVec):OpVec {
		return new OpVec(this * (rhs : Int) + 1);
	}

	/**
	 * @param rhs The right operand.
	 * @return Whether the boxed values differ by no more than one, so equality is not identity.
	 */
	@:op(A == B) public function eq(rhs:OpVec):Bool {
		var d:Int = this - (rhs : Int);
		return d >= -1 && d <= 1;
	}

	/**
	 * @param rhs The right operand.
	 * @return The reverse of the natural ordering, so a fallback is visible.
	 */
	@:op(A > B) public function gt(rhs:OpVec):Bool {
		return this < (rhs : Int);
	}

	/**
	 * @return A form of its own, so a declared `toString` is visibly preferred over the boxed value.
	 */
	public function toString():String {
		return 'V' + this;
	}

	/**
	 * @return The negation, offset so it cannot be confused with plain `Int` negation.
	 */
	@:op(-A) public function neg():OpVec {
		return new OpVec(-this - 100);
	}

	/**
	 * @return Whether the boxed value is odd, so this is not the plain truthiness of the value.
	 */
	@:op(!A) public function not():Bool {
		return this % 2 != 0;
	}

	/**
	 * @param k The element key.
	 * @return The boxed value scaled by the key, so the getter is distinguishable.
	 */
	@:arrayAccess public function get(k:Int):Int {
		return this * 100 + k;
	}
}
