/**
 * A generic base whose constructor is what a bridge cannot rebuild, in the two ways reported.
 *
 * Shaped after the class the report named. `FlxSpriteGroup` is a concrete subclass of a generic
 * `FlxTypedGroup<T>`, and its constructor calls `Std.int`, and both of those defeat a bridge that
 * rebuilds a base constructor by turning the compiler's own output back into source:
 *
 *  - `Std.int` on HashLink is `extern inline function int(x) return untyped $int(x)`, so once it is
 *    inlined the body holds `$int`, which is magic no source outside `untyped` may name. Re-emitted
 *    it is `Unknown identifier : $int`, and the expression then types as `Void`.
 *  - `T` has no meaning in the bridge, which is not generic. Re-emitted it is `Type not found : T`.
 *
 * Neither is a fact about these classes. Both are facts about rebuilding a constructor out of code
 * the compiler has already finished with.
 */
class HostTyped<T> {
	/** A member whose type is the parameter, so the parameter reaches the constructor's body. */
	public var members:Array<T>;

	/** What the constructor computes, so `Std.int` has a reason to be called. */
	public var cap:Int;

	public function new(size:Float = 0) {
		members = [];
		cap = Std.int(Math.abs(size));
	}

	/** @return How many are held, so a script can be seen to reach an inherited method. */
	public function count():Int {
		return members.length;
	}
}

/**
 * A generic subclass that passes its parameter straight through, which is the middle of the chain.
 *
 * `FlxSpriteGroup` is `FlxTypedSpriteGroup<FlxSprite>` is `FlxTypedGroup<T>`, so what the bridge is
 * handed for the outermost parameter is another class's parameter rather than a type. One level is
 * not the same question and does not fail.
 */
class HostMiddle<T:HostBase> extends HostTyped<T> {
	/** Held rather than inherited, so the constructor has to name the parameter to build one. */
	public var group:HostTyped<T>;

	public function new(size:Float = 0) {
		super(size);
		group = new HostTyped<T>(size);
	}
}

/** A concrete subclass of it, which is the shape a host actually bridges. */
class HostQuirk extends HostMiddle<HostBase> {
	public function new() {
		super(4);
	}
}
