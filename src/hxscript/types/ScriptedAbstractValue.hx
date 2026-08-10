package hxscript.types;

/**
 * A value boxed by a script-declared abstract.
 */
class ScriptedAbstractValue extends AbstractValue {
	/** The abstract that declares this value's behavior. */
	public var owner:ScriptedAbstract;

	/** The value this box wraps. */
	public var boxed(get, never):Dynamic;

	/** @return The underlying value this box wraps. */
	inline function get_boxed():Dynamic {
		return __a;
	}

	/**
	 * Boxes a value.
	 *
	 * @param v The underlying value.
	 * @param owner The declaring abstract.
	 */
	public function new(v:Dynamic, owner:ScriptedAbstract) {
		this.owner = owner;
		super(v);
	}

	/**
	 * Converts to one of the abstract's `to` targets. The conversion methods are `@:to`-annotated
	 * fields, so the first one whose declared return type names the target wins.
	 *
	 * @param t The target type name.
	 * @return The converted value, or null when the abstract declares no such conversion.
	 */
	override public function resolveTo(t:String):Dynamic {
		if (owner == null)
			return null;

		for (f in owner.impl.reflectListFields()) {
			var ret:String = owner.toTargets.get(f);
			if (ret != null && ret == t)
				return owner.callField(__a, f, []);
		}
		return null;
	}

	/** @return The boxed value's own string form, so an abstract prints as what it wraps. */
	public function toString():String {
		if (owner != null && owner.hasField('toString'))
			return owner.callField(__a, 'toString', []);
		return Std.string(__a);
	}
}
