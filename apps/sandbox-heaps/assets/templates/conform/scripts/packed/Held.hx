package packed;

/**
 * A scripted class in a package, for another module of that package to construct.
 *
 * `Shared` next door is the same idea one step simpler: another module, no package. A project is
 * usually neither, being many modules laid out in packages, and the difference between the two turns
 * out to matter. The puzzle template is 28 modules under `puzzle.game`, `puzzle.core` and
 * `puzzle.play`, and its engine cannot call a method on the board it just constructed.
 */
class Held {
	public var n:Int = 0;

	public function new() {}

	/** A method, which is what was not reachable on one of these. */
	public function bump():Void {
		n++;
	}

	/** @return Its count, read back through a second method. */
	public function read():Int {
		return n;
	}
}
