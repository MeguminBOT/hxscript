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
}
