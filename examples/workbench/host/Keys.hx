package host;

/**
 * Key codes and the terminal read that produces them.
 *
 * Terminal input is the one genuinely awkward part of running a game in a console, and it is host
 * work rather than script work, so it lives here and scripts only ever see a `Keys` constant.
 */
class Keys {
	public static inline var NONE:Int = 0;
	public static inline var LEFT:Int = 1;
	public static inline var RIGHT:Int = 2;
	public static inline var UP:Int = 3;
	public static inline var DOWN:Int = 4;
	public static inline var SPACE:Int = 5;
	public static inline var ENTER:Int = 6;
	public static inline var ESCAPE:Int = 7;
	public static inline var TAB:Int = 8;

	/** A letter key: `LETTER + (code of the lower-case letter)`. */
	public static inline var LETTER:Int = 100;

	/**
	 * The `Keys` constant for a letter.
	 *
	 * @param c A single character.
	 * @return Its key code.
	 */
	public static inline function of(c:String):Int {
		return LETTER + c.toLowerCase().charCodeAt(0);
	}

	/**
	 * Reads one key, blocking until there is one.
	 *
	 * Arrow keys arrive as an escape sequence (`ESC [ A`) on a terminal and as a `0xE0` prefix on a Windows
	 * console, so both are decoded here. A bare ESC is ambiguous, since it is also the start of a sequence,
	 * and is reported as `ESCAPE` only when nothing follows it.
	 *
	 * @return The key code.
	 */
	public static function read():Int {
		var c:Int = Sys.getChar(false);

		switch (c) {
			case 13, 10:
				return ENTER;
			case 32:
				return SPACE;
			case 9:
				return TAB;

			case 0, 224:
				// Windows console arrow keys: a 0 or 224 prefix, then the code.
				return switch (Sys.getChar(false)) {
					case 75: LEFT;
					case 77: RIGHT;
					case 72: UP;
					case 80: DOWN;
					default: NONE;
				}

			case 27:
				// ANSI sequence, or a real escape. `[` distinguishes them.
				var next:Int = Sys.getChar(false);
				if (next != 91)
					return ESCAPE;

				return switch (Sys.getChar(false)) {
					case 68: LEFT;
					case 67: RIGHT;
					case 65: UP;
					case 66: DOWN;
					default: NONE;
				}
		}

		if (c >= 33 && c < 127)
			return LETTER + String.fromCharCode(c).toLowerCase().charCodeAt(0);

		return NONE;
	}
}
