package hxscript.hl;

/**
 * A type in a module's table.
 *
 * The table is written by index, so a type is identified by where it sits rather than by its shape,
 * and two structurally identical entries are two types as far as the reader is concerned. Pooling in `Bytecode`
 * is what keeps that from happening.
 */
enum TypeEntry {
	/** A primitive, carrying nothing beyond its kind. */
	TPrim(kind:TypeKind);

	/** A function or method, by the indices of its argument types and its return type. */
	TFun(args:Array<Int>, ret:Int);

	/**
	 * A class.
	 *
	 * @param name Its name, as a string-pool index.
	 * @param fields Its instance fields, in the order field access indexes them.
	 * @param protos Its methods, which take the instance as their first argument.
	 */
	TObj(name:Int, fields:Array<Field>, protos:Array<Proto>);
}

/** One instance field: its name in the string pool and its type in the type table. */
@:structInit
class Field {
	public var name:Int;
	public var type:Int;
}

/** One method: its name in the string pool and the function index that runs it. */
@:structInit
class Proto {
	public var name:Int;
	public var findex:Int;
}
