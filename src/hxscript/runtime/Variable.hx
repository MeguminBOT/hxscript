package hxscript.runtime;

import hxscript.syntax.Expr;
import hxscript.types.AbstractValue;

/**
 * A variable slot: its value plus optional abstract box, finality, access flags, and accessors.
 *
 * A number is kept unboxed in `num`, because on a target where `Dynamic` is a pointer every write of
 * an `Int` to a slot would otherwise allocate. `r` reads and writes the slot whichever lane it is in,
 * so nothing that holds a `Variable` has to know which.
 */
@:structInit
class Variable {
	/** The value, when it is not in the numeric lane. Written through `r` rather than directly. */
	public var ref:Dynamic;

	/** The value, when it is a number. */
	public var num:Float = 0;

	/** Which lane holds the value. */
	public var lane:Int = REFERENCE;

	/** The value is wherever `lane` says, and is boxed on the way out when that is a number. */
	public var r(get, set):Dynamic;

	inline function get_r():Dynamic {
		return lane == REFERENCE ? ref : (lane == INT ? (Std.int(num) : Dynamic) : (num : Dynamic));
	}

	inline function set_r(v:Dynamic):Dynamic {
		lane = REFERENCE;
		return ref = v;
	}

	/** The value as an `Int`, without boxing it on the way. */
	public inline function asInt():Int {
		return lane == REFERENCE ? (ref : Int) : Std.int(num);
	}

	/** The value as a `Float`, without boxing it on the way. */
	public inline function asFloat():Float {
		return lane == REFERENCE ? (ref : Float) : num;
	}

	/** Puts an `Int` in the slot without boxing it. */
	public inline function setInt(v:Int):Void {
		lane = INT;
		num = v;
		ref = null;
	}

	/** Puts a `Float` in the slot without boxing it. */
	public inline function setFloat(v:Float):Void {
		lane = FLOAT;
		num = v;
		ref = null;
	}

	/** Whether the slot holds a number in its own lane rather than a boxed one. */
	public inline function isNumeric():Bool {
		return lane != REFERENCE;
	}

	/** The value is in `ref`. */
	public static inline var REFERENCE:Int = 0;

	/** The value is an `Int` in `num`. */
	public static inline var INT:Int = 1;

	/** The value is a `Float` in `num`. */
	public static inline var FLOAT:Int = 2;

	/** The abstract wrapper, when the value is a boxed abstract. */
	public var a:AbstractValue = null;

	/** The declared type, when the binding was annotated, so writes can be checked against it. */
	public var t:CType = null;

	/**
	 * How a write to this slot enforces its declared type, worked out once, and when.
	 *
	 * Resolving a type annotation means asking `imports` whether anything shadows the name, which is
	 * a map miss on every store, and a store is what a typed variable is for. `Interp` remembers the
	 * answer rather than working it out again, and remembers with it which state of the import table
	 * it was true of, so a table that moves throws the answer away.
	 *
	 * **One field, packed, because a `Variable` is allocated per local per frame.** Three fields
	 * measured as a 2 to 5% loss across the whole interpreter, on cases that never write a typed
	 * variable at all, which is the shape of an object that grew past what it was fitting in. The low
	 * three bits are the plan and the rest is the stamp; -1 is "never worked out".
	 */
	public var castState:Int = -1;

	/** Whether the binding is `final`. */
	public var isFinal:Bool = false;

	/** The field's access modifiers, when it is a class field. */
	public var access:Array<FieldAccess> = null;

	/** The getter accessor name, when it is a property. */
	public var get:String = null;

	/** The setter accessor name, when it is a property. */
	public var set:String = null;
}
