package hxscript.runtime;

import hxscript.runtime.Variable;

/**
 * A deferred, non-value reference stored in the imports/variables tables and materialized on lookup.
 * It lets a bare name stand for something that is not a plain value: a super call, a property, or an
 * enum constructor.
 */
enum Reference {
	/** A `super` reference carrying the captured locals and constructor to invoke. */
	RSuper(?locals:Map<String, Variable>, ?constructor:Dynamic);

	/** A property `f` on target `t`, resolved through getters/setters on access. */
	RProperty(t:Dynamic, f:String);

	/** Enum `t`'s constructor at index `i`, materialized to the value (or a builder) on use. */
	REnumValue(t:Dynamic, i:Int);

	/** Enum-abstract `t`'s constant at index `i`. */
	RAbstractEnumValue(t:Dynamic, i:Int);
}
