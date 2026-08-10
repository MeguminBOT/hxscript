package hxscript.compile;

/**
 * Why one module was not compiled.
 */
@:structInit
class Skip {
	/** The module's name. */
	public var name:String;

	/** What could not be expressed, phrased to be read in a report. */
	public var reason:String;

	/** The source origin, when the emitter knew where it was. */
	public var origin:Null<String> = null;

	/** The 1-based line, or 0 when unknown. */
	public var line:Int = 0;

	/** @return The reason, with its position when there is one. */
	public function toString():String {
		if (origin == null)
			return '$name: $reason';

		return '$name ($origin:$line): $reason';
	}
}
