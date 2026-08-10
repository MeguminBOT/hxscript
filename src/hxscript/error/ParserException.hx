package hxscript.error;

/** A parse error, carrying the error kind and its source position. */
class ParserException extends haxe.Exception {
	/** The specific error. */
	public var e:ErrorKind;

	/** Start byte offset of the offending token. */
	public var pmin:Int;

	/** End byte offset of the offending token. */
	public var pmax:Int;

	/** The source origin (file path or script name). */
	public var origin:String;

	/**
	 * The 1-based line number.
	 */
	public var lineNumber:Int;

	/**
	 * Creates a parser exception.
	 *
	 * @param e The error kind.
	 * @param pmin Start byte offset of the offending token.
	 * @param pmax End byte offset of the offending token.
	 * @param origin The source origin.
	 * @param line The 1-based line number.
	 */
	public function new(e:ErrorKind, pmin:Int, pmax:Int, origin:String, line:Int) {
		super(Printer.errorAt(e, origin, line));

		this.e = e;
		this.pmin = pmin;
		this.pmax = pmax;
		this.origin = origin;
		this.lineNumber = line;
	}

	/** @return The error formatted with its source position. */
	public override function toString():String {
		return Printer.errorToString(this.e, this);
	}

	/**
	 * The same error as a diagnostic, with the column and source line worked out.
	 *
	 * The column is derived here rather than carried, because the parser already holds the byte
	 * offset and turning it into a column costs a scan of the source. Carrying it would mean paying
	 * that on every token to have it on the one that fails.
	 *
	 * @return The diagnostic.
	 */
	public function toDiagnostic():Diagnostic {
		return {
			phase: PParse,
			message: Printer.errorMessage(e),
			origin: origin,
			line: lineNumber,
			column: Sources.column(origin, pmin),
			excerpt: Sources.line(origin, lineNumber),
			hint: Hint.forKind(e)
		};
	}
}
