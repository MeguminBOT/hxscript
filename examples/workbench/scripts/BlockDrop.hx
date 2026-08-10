import blocks.Bag;
import blocks.Board;
import blocks.Scoring;
import blocks.Shapes;

/**
 * A falling-block game, written entirely as scripts.
 *
 * Nothing about this program is compiled. The host owns a screen, a keyboard and a clock; the well, the
 * pieces, the rotation, the scoring and every pixel of the layout are here and in `blocks/`. Edit any of it
 * and run again, because there is no build step between the two.
 *
 * The game steps once per keypress, which is what a terminal can honestly do: there is no portable
 * non-blocking key poll. Gravity is still real time, so holding a key down drops you faster than
 * thinking about it does.
 */
class BlockDrop extends App {
	/** Well width in cells. */
	public static var COLS:Int = 10;

	/** Well height in cells. */
	public static var ROWS:Int = 18;

	var board:Board;
	var bag:Bag;
	var scoring:Scoring;

	/** The falling piece, its rotation, and where its origin sits. */
	var kind:Int = 0;

	var state:Int = 0;
	var px:Int = 0;
	var py:Int = 0;

	/** The piece after this one. */
	var queued:Int = 0;

	/** Seconds owed to gravity. */
	var fall:Float = 0;

	/** Rows the player pushed the current piece down by hand. */
	var pushed:Int = 0;

	/** Set when the well tops out. */
	var lost:Bool = false;

	public function new() {
		super();

		title = 'BlockDrop: arrows move, up rotates, space drops, q quits';
		width = 46;
		height = ROWS + 4;
	}

	override public function start(screen:Screen):Void {
		board = new Board(COLS, ROWS);
		bag = new Bag(20260801);
		scoring = new Scoring();

		queued = bag.take();
		spawn();
	}

	/** Takes the next piece from the bag, or ends the run if it does not fit. */
	function spawn():Void {
		kind = queued;
		queued = bag.take();
		state = 0;
		px = Std.int(COLS / 2) - 2;
		py = -1;
		pushed = 0;

		if (board.collides(kind, state, px, py))
			lost = true;
	}

	/**
	 * Moves the piece if the destination is clear.
	 *
	 * @param dx Columns to move by.
	 * @param dy Rows to move by.
	 * @return Whether it moved.
	 */
	function move(dx:Int, dy:Int):Bool {
		if (board.collides(kind, state, px + dx, py + dy))
			return false;

		px += dx;
		py += dy;
		return true;
	}

	/**
	 * Rotates the piece, nudging it sideways when the rotation would clip a wall.
	 *
	 * @param by 1 for clockwise, -1 for counter-clockwise.
	 */
	function rotate(by:Int):Void {
		var want:Int = ((state + by) % 4 + 4) % 4;

		for (nudge in [0, -1, 1, -2, 2]) {
			if (!board.collides(kind, want, px + nudge, py)) {
				state = want;
				px += nudge;
				return;
			}
		}
	}

	/** Settles the piece, scores it, and brings on the next one. */
	function lock():Void {
		board.settle(kind, state, px, py);
		scoring.place(board.clearLines(), pushed);
		spawn();
	}

	override public function key(k:Int):Void {
		if (k == Keys.of('q')) {
			done = true;
			return;
		}

		if (lost) {
			if (k == Keys.ENTER) {
				board.reset();
				scoring = new Scoring();
				lost = false;
				spawn();
			}
			return;
		}

		if (k == Keys.LEFT)
			move(-1, 0);
		else if (k == Keys.RIGHT)
			move(1, 0);
		else if (k == Keys.UP)
			rotate(1);
		else if (k == Keys.of('z'))
			rotate(-1);
		else if (k == Keys.DOWN) {
			if (move(0, 1)) {
				pushed++;
				fall = 0;
			}
		} else if (k == Keys.SPACE) {
			while (move(0, 1))
				pushed++;
			lock();
		}
	}

	override public function step(elapsed:Float):Void {
		if (lost)
			return;

		fall += elapsed;
		if (fall < scoring.gravity())
			return;

		fall = 0;
		if (!move(0, 1))
			lock();
	}

	override public function draw(screen:Screen):Void {
		var left:Int = 1;
		var top:Int = 1;

		screen.frame(left, top, COLS + 2, ROWS + 2);

		for (y in 0...ROWS)
			for (x in 0...COLS) {
				var at:Int = board.get(x, y);
				if (at != 0)
					screen.put(left + 1 + x, top + 1 + y, Shapes.GLYPHS[at]);
			}

		if (!lost) {
			var shape:Array<Int> = Shapes.cells(kind, state);
			var i:Int = 0;
			while (i < 8) {
				var x:Int = px + shape[i];
				var y:Int = py + shape[i + 1];
				if (y >= 0)
					screen.put(left + 1 + x, top + 1 + y, Shapes.GLYPHS[kind]);
				i += 2;
			}
		}

		var panel:Int = left + COLS + 4;
		screen.text(panel, top + 1, 'score  ${scoring.score}');
		screen.text(panel, top + 2, 'lines  ${scoring.lines}');
		screen.text(panel, top + 3, 'level  ${scoring.level}');
		screen.text(panel, top + 5, 'next   ${Shapes.GLYPHS[queued]}');

		screen.text(panel, top + 7, 'arrows move');
		screen.text(panel, top + 8, 'up/z   rotate');
		screen.text(panel, top + 9, 'space  hard drop');
		screen.text(panel, top + 10, 'q      quit');

		if (lost) {
			// The well's interior is COLS wide, so a banner has to fit in it or it spills over the
			// frame and into the side panel.
			screen.text(left + 1, top + Std.int(ROWS / 2), 'TOPPED OUT');
			screen.text(left + 1, top + Std.int(ROWS / 2) + 1, 'enter=redo');
		}
	}
}
