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
	 * @param base Another entry in this table to extend, or -1. A class extending one the world
	 *        already has leaves a bare entry here and has the loader point it at the real one.
	 * @param global A global holding the class value, one-based, or 0 when it has none.
	 */
	TObj(name:Int, fields:Array<Field>, protos:Array<Proto>, base:Int, global:Int);
}

/** One instance field: its name in the string pool and its type in the type table. */
@:structInit
class Field {
	public var name:Int;
	public var type:Int;
}

/**
 * One method: its name in the string pool, the function index that runs it, and where it sits in the
 * class's method table.
 *
 * A method that overrides an inherited one takes the position that one already has, which is what
 * makes a call through a base-typed reference reach it. A new one takes the next free position, and
 * -1 leaves it out of the table entirely, reachable only by name.
 */
@:structInit
class Proto {
	public var name:Int;
	public var findex:Int;
	public var pindex:Int = -1;
}
