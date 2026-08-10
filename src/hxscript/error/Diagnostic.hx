package hxscript.error;

/**
 * One thing that went wrong, in the shape a host can render or route.
 */
@:structInit
class Diagnostic {
	/** Which part of the pipeline this came from. */
	public var phase:Phase;

	/** What happened, as one line where possible. */
	public var message:String;

	/** Where it happened: a file path or script name. Null when the phase has no source. */
	public var origin:Null<String> = null;

	/** 1-based line number, or 0 when unknown. */
	public var line:Int = 0;

	/** 1-based column, or 0 when unknown. */
	public var column:Int = 0;

	/** The source line the position falls on, when the source is known. */
	public var excerpt:Null<String> = null;

	/** What usually causes this, and what to do about it. Null when there is nothing useful to add. */
	public var hint:Null<String> = null;

	/** A call stack, interpreter or native, already rendered. */
	public var stack:Null<String> = null;

	/** Whether this stopped something. A warning means the run continued in a reduced form. */
	public var fatal:Bool = true;

	/** @return The diagnostic rendered the way a compiler renders one. */
	public function toString():String {
		return Printer.render(this);
	}
}
