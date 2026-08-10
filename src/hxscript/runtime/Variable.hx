package hxscript.runtime;

import hxscript.syntax.Expr;
import hxscript.types.AbstractValue;

/**
 * A variable slot: its value plus optional abstract box, finality, access flags, and accessors.
 */
@:structInit
class Variable {
	/** The stored value. */
	public var r:Dynamic;

	/** The abstract wrapper, when the value is a boxed abstract. */
	public var a:AbstractValue = null;

	/** The declared type, when the binding was annotated, so writes can be checked against it. */
	public var t:CType = null;

	/** Whether the binding is `final`. */
	public var isFinal:Bool = false;

	/** The field's access modifiers, when it is a class field. */
	public var access:Array<FieldAccess> = null;

	/** The getter accessor name, when it is a property. */
	public var get:String = null;

	/** The setter accessor name, when it is a property. */
	public var set:String = null;
}
