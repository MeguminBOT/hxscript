package blocks;

import blocks.Shapes;

/**
 * A seven-bag randomiser: every run of seven pieces contains each tetromino exactly once, so the
 * well never starves you of the piece you need for very long.
 *
 * The generator is seeded and written out here rather than using `Std.random`, so a run is reproducible,
 * which matters when you are iterating on a prototype and want the same game twice.
 */
class Bag {
	/** Current generator state. */
	var seed:Int;

	/** Pieces not yet dealt from the current bag. */
	var remaining:Array<Int>;

	/**
	 * @param seed Any non-zero starting value.
	 */
	public function new(seed:Int) {
		this.seed = seed == 0 ? 1 : seed;
		this.remaining = [];
	}

	/**
	 * A linear congruential step. The constants are the ones from Numerical Recipes; the masking
	 * keeps it inside 31 bits so it behaves the same on every target.
	 *
	 * @param max Exclusive upper bound.
	 * @return A value in `0...max`.
	 */
	function next(max:Int):Int {
		seed = (seed * 1664525 + 1013904223) & 0x3FFFFFFF;
		return max <= 0 ? 0 : seed % max;
	}

	/** Refills the bag with one of each piece, shuffled. */
	function refill():Void {
		remaining = [for (k in 1...Shapes.COUNT + 1) k];

		var i:Int = remaining.length - 1;
		while (i > 0) {
			var j:Int = next(i + 1);
			var swap:Int = remaining[i];
			remaining[i] = remaining[j];
			remaining[j] = swap;
			i--;
		}
	}

	/** @return The next piece kind, refilling the bag when it runs out. */
	public function take():Int {
		if (remaining.length == 0)
			refill();

		return remaining.pop();
	}
}
