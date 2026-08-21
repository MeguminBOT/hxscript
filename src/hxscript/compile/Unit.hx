package hxscript.compile;

import hxscript.syntax.Expr;

/**
 * One module offered to the compiler: its parsed declarations, and a name to report it by.
 */
@:structInit
class Unit {
	/** How to name this module in a diagnostic. */
	public var name:String;

	/** Its parsed declarations. */
	public var decls:Array<ModuleDecl>;

	/**
	 * The interpreter holding whatever the host bound into this module by name.
	 *
	 * What a bare name the module never declared resolves to, both while it compiles and once it
	 * runs. Null for a host driving the backend directly, which leaves such a name refused the way it
	 * always was.
	 */
	public var scope:hxscript.runtime.Interp = null;

	/**
	 * What to call `scope` by in the emitted call, which is the module's path.
	 *
	 * Its path and not its `name`: a name is the simple one, and two modules in different packages
	 * may share it.
	 */
	public var key:String = null;
}
