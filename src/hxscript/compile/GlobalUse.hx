package hxscript.compile;

/**
 * One name a compiled module reached that the host bound rather than the script declared.
 *
 * Recorded per name, not per use, so a report says what a module needs from its host rather than how
 * often it asked. What it is for is finding the ones worth giving a real home: a global read as
 * `Dynamic` is the slowest spelling there is, and a `@:scriptStatic` or a `Compiler.statics` entry
 * turns that same name into a static field read.
 */
@:structInit
class GlobalUse {
	/** The module that named it. */
	public var module:String;

	/** The name, as the script wrote it. */
	public var name:String;

	/**
	 * How the emitter spelled it.
	 *
	 * `type` for a name holding a type, which compiles to a real type path and costs nothing;
	 * `static` for one the host answers with a static of its own; a type name for a global read
	 * through a typed accessor; and `Dynamic` for the fallback.
	 */
	public var spelling:String;

	/** @return The name with its spelling, for a report. */
	public function toString():String {
		return '$module: $name as $spelling';
	}
}
