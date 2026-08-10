package hxscript.error;

/**
 * Remembers the text of everything parsed, so a diagnostic can quote the line it is about.
 */
class Sources {
	/** Source text by origin. */
	static var text:Map<String, String> = new Map();

	/** Line start offsets by origin, computed on first use. */
	static var lines:Map<String, Array<Int>> = new Map();

	/**
	 * Records what an origin's source is.
	 *
	 * @param origin The file path or script name positions will be reported against.
	 * @param source The text.
	 */
	public static function remember(origin:String, source:String):Void {
		if (origin == null || source == null)
			return;

		text.set(origin, source);
		lines.remove(origin);
	}

	/**
	 * @param origin The origin to forget.
	 */
	public static function forget(origin:String):Void {
		text.remove(origin);
		lines.remove(origin);
	}

	/**
	 * Whether an origin is one of ours.
	 *
	 * The interpreter's own call stack mixes script frames with native ones, because a frame carries
	 * the `haxe.PosInfos` of whatever pushed it. Asking whether the source was remembered is what
	 * separates the two, and it is exact rather than a guess at path shapes.
	 *
	 * @param origin The origin to test.
	 * @return Whether a script of that origin was parsed.
	 */
	public static function known(origin:String):Bool {
		return origin != null && text.exists(origin);
	}

	/** Drops every remembered source. */
	public static function clear():Void {
		text = new Map();
		lines = new Map();
	}

	/**
	 * The source line a 1-based line number falls on.
	 *
	 * @param origin The origin to read.
	 * @param line The 1-based line number.
	 * @return The line without its terminator, or null when the source or the line is unknown.
	 */
	public static function line(origin:String, line:Int):Null<String> {
		var starts:Array<Int> = offsets(origin);
		if (starts == null || line < 1 || line > starts.length)
			return null;

		var source:String = text.get(origin);
		var from:Int = starts[line - 1];
		var to:Int = line < starts.length ? starts[line] : source.length;

		var out:String = source.substring(from, to);

		while (out.length > 0 && (out.charCodeAt(out.length - 1) == 10 || out.charCodeAt(out.length - 1) == 13))
			out = out.substr(0, out.length - 1);

		return out;
	}

	/**
	 * The 1-based column a byte offset falls on.
	 *
	 * Derived rather than carried, because the parser already has the offset and computing this at
	 * the point of failure would cost a scan on a path that is usually not taken.
	 *
	 * @param origin The origin the offset is in.
	 * @param offset The byte offset.
	 * @return The 1-based column, or 0 when the source is unknown.
	 */
	public static function column(origin:String, offset:Int):Int {
		var starts:Array<Int> = offsets(origin);
		if (starts == null || offset < 0)
			return 0;

		var lo:Int = 0;
		var hi:Int = starts.length - 1;

		while (lo < hi) {
			var mid:Int = (lo + hi + 1) >> 1;
			if (starts[mid] <= offset)
				lo = mid;
			else
				hi = mid - 1;
		}

		return offset - starts[lo] + 1;
	}

	/**
	 * The offset each line begins at, computed once per origin.
	 *
	 * @param origin The origin to index.
	 * @return The offsets, or null when the source is unknown.
	 */
	static function offsets(origin:String):Array<Int> {
		if (origin == null)
			return null;

		var known:Array<Int> = lines.get(origin);
		if (known != null)
			return known;

		var source:String = text.get(origin);
		if (source == null)
			return null;

		var starts:Array<Int> = [0];
		for (i in 0...source.length)
			if (source.charCodeAt(i) == 10)
				starts.push(i + 1);

		lines.set(origin, starts);
		return starts;
	}
}
