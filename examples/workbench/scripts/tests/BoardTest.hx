package tests;

import blocks.Board;
import blocks.Shapes;

/**
 * A test, written as a script like everything else.
 *
 * `Workbench test` finds every scripted class declaring `static function test()` and runs it. A test returns
 * an empty string when it passes and a description of the first failure when it does not, so a red run says
 * what broke rather than only that something did.
 *
 * The point is that the tests live next to the code they cover and reload with it: a rule can be
 * changed and re-checked without a build.
 */
class BoardTest {
	/**
	 * Checks the well's rules.
	 *
	 * @return An empty string when everything held, otherwise the first failure.
	 */
	public static function test():String {
		var board = new Board(10, 18);

		if (board.get(0, 0) != 0)
			return 'a new board should be empty';

		if (!board.collides(1, 0, -5, 0))
			return 'a piece off the left wall should collide';

		if (!board.collides(1, 0, 0, 17))
			return 'a piece through the floor should collide';

		// A piece is allowed to spawn partly above the ceiling.
		if (board.collides(3, 0, 4, -1))
			return 'a piece overlapping the ceiling should be allowed';

		// Fill every row but one column, then check that clearing takes exactly the full rows.
		board.reset();
		for (x in 0...9) {
			board.settle(2, 0, x, 16);
		}

		if (board.clearLines() != 0)
			return 'an incomplete row should not clear';

		board.reset();
		for (y in 16...18)
			for (x in 0...10)
				board.cells[y * 10 + x] = 1;

		if (board.clearLines() != 2)
			return 'two full rows should clear as two';

		if (board.get(0, 17) != 0)
			return 'the well should be empty after clearing';

		return '';
	}
}
