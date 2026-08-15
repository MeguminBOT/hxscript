package packed;

import packed.Held;

/**
 * A module that constructs a class of its own package, annotates it, and calls it.
 *
 * Three separate questions, kept apart so a failure says which one it is:
 * whether the value can be made, whether it satisfies an annotation naming its type, and whether a
 * method can be called on it.
 */
class Holder {
	public var held:Held;

	public function new() {
		held = new Held();
	}

	/** @return Whether construction produced anything at all. */
	public function made():Bool {
		return held != null;
	}

	/** @return What the constructed value answers, which needs the call to land. */
	public function used():Int {
		held.bump();
		held.bump();
		return held.read();
	}
}
