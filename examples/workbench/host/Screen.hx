package host;

/**
 * A character grid the scripts draw into, flushed to the terminal once per frame.
 *
 * Deliberately tiny. The workbench is about scripts owning the whole program, so the host provides the
 * smallest surface a game needs, which is putting a character somewhere, writing a string and presenting,
 * and nothing that decides how the game looks.
 */
class Screen {
	/** Grid width in characters. */
	public var width:Int;

	/** Grid height in characters. */
	public var height:Int;

	/** Row-major cell buffer, `width * height` entries. */
	var cells:Array<String>;

	/**
	 * @param width Grid width in characters.
	 * @param height Grid height in characters.
	 */
	public function new(width:Int, height:Int) {
		this.width = width;
		this.height = height;
		this.cells = [];
		clear();
	}

	/** Blanks every cell. */
	public function clear():Void {
		cells = [for (i in 0...width * height) ' '];
	}

	/**
	 * Writes one character, ignoring anything off-grid so scripts need no bounds checks.
	 *
	 * @param x Column.
	 * @param y Row.
	 * @param c The character; only its first glyph is used.
	 */
	public function put(x:Int, y:Int, c:String):Void {
		if (x < 0 || x >= width || y < 0 || y >= height || c == null || c.length == 0)
			return;

		cells[y * width + x] = c.charAt(0);
	}

	/**
	 * Writes a string left to right.
	 *
	 * @param x Starting column.
	 * @param y Row.
	 * @param s The text.
	 */
	public function text(x:Int, y:Int, s:String):Void {
		if (s == null)
			return;

		for (i in 0...s.length)
			put(x + i, y, s.charAt(i));
	}

	/**
	 * Draws a rectangle outline in box-drawing characters.
	 *
	 * @param x Left column.
	 * @param y Top row.
	 * @param w Width in characters.
	 * @param h Height in characters.
	 */
	public function frame(x:Int, y:Int, w:Int, h:Int):Void {
		for (i in 1...w - 1) {
			put(x + i, y, '-');
			put(x + i, y + h - 1, '-');
		}
		for (j in 1...h - 1) {
			put(x, y + j, '|');
			put(x + w - 1, y + j, '|');
		}

		put(x, y, '+');
		put(x + w - 1, y, '+');
		put(x, y + h - 1, '+');
		put(x + w - 1, y + h - 1, '+');
	}

	/** Redraws the terminal from the buffer. */
	public function present():Void {
		var out:StringBuf = new StringBuf();

		// Cursor home rather than a clear: clearing the whole screen every frame makes the terminal
		// flicker, and on Windows it also scrolls the scrollback away.
		out.add('\x1b[H');

		for (y in 0...height) {
			var from:Int = y * width;
			for (x in 0...width)
				out.add(cells[from + x]);
			out.add('\x1b[K\n');
		}

		Sys.print(out.toString());
	}

	/** Clears the terminal and parks the cursor at the top. */
	public static function reset():Void {
		Sys.print('\x1b[2J\x1b[H');
	}
}
