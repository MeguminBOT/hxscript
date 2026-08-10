package hxscript.compile;

/**
 * What one call to `Compiler.compile` did.
 */
@:structInit
class Report {
	/** Scripted paths that have a compiled form, including ones bound from an earlier world. */
	public var compiled:Array<String>;

	/** Modules left to the interpreter because the emitter would not emit them, each with the reason. */
	public var skipped:Array<Skip>;

	/**
	 * Modules the bytecode loader refused after the emitter had emitted them.
	 */
	public var failed:Array<Skip>;

	/** How long compiling took, in milliseconds. Zero when there was nothing to do. */
	public var ms:Float;

	/**
	 * How much bytecode was produced, in bytes.
	 */
	public var bytes:Int;

	/** Whether the world now reaches its scripted classes through their compiled form. */
	public var substituting:Bool;
}
