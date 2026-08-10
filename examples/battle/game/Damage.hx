package game;

/**
 * A damage amount, as a native abstract over `Int`.
 *
 * Note what is NOT on this type: `@:build(hxscript.macro.Abstract.build())`. An abstract has no runtime
 * representation, so a script handed one would see nothing at all: no methods, no operators, no `from`/`to`.
 * The build macro emits a reflectable wrapper that gives it one, and it is applied to this type from
 * OUTSIDE, by `macros/AbstractsMacro.hx`.
 *
 * That is the arrangement worth copying: the abstracts a real host wants scriptable are mostly in
 * libraries it does not own, so it cannot annotate them. Applying the macro externally works the
 * same either way, and this type stays a plain abstract that compiled code uses without knowing
 * anything about scripting.
 *
 * None of these members is `inline`, and that is deliberate. An `inline` method has no runtime
 * representation for the wrapper to expose, so it stays invisible to scripts however the macro is applied,
 * and the call fails with `Cannot call null`. Compiled callers lose the inlining; a member a script has to
 * reach has to exist.
 */
abstract Damage(Int) from Int to Int {
	/** @param v The amount. */
	public function new(v:Int) {
		this = v;
	}

	/** Damage stacks. */
	@:op(A + B) public function add(o:Damage):Damage {
		return new Damage(this + (o : Int));
	}

	/**
	 * Scales the amount, rounding down, and never below 1 so a multiplier cannot nullify a hit.
	 *
	 * @param f The multiplier.
	 * @return The scaled amount.
	 */
	@:op(A * B) public function scale(f:Float):Damage {
		var out:Int = Std.int(this * f);
		return new Damage(out < 1 ? 1 : out);
	}

	/**
	 * A critical hit: half again, rounded down.
	 *
	 * @return The increased amount.
	 */
	public function critical():Damage {
		return scale(1.5);
	}

	/**
	 * The amount, marked when it is a heavy hit.
	 *
	 * @param baseline What counts as an ordinary hit.
	 * @return The amount, with a `!` when it exceeds the baseline.
	 */
	public function describe(baseline:Int):String {
		return this > baseline ? '$this!' : Std.string(this);
	}

	/** @return The amount, unadorned. */
	public function toString():String {
		return Std.string(this);
	}
}
