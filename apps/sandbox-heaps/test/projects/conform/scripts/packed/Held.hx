package packed;

/**
 * A scripted class in a package, for another module of that package to construct.
 *
 * `Shared` next door is the same idea one step simpler: another module, no package. A project is
 * usually neither, being many modules laid out in packages, and the difference between the two turns
 * out to matter: a project is many modules laid out in packages, and a class that cannot call a
 * method on one its own package built is the failure this pins down.
 */
class Held {
	public var n:Int = 0;

	/** Declared as its own type, so the slot holds this module's layout rather than a dynamic. */
	public var beside:Held = null;

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

/**
 * A second class of the same module, declaring a field and a parameter as the first.
 *
 * Same module on purpose. A field annotated with a class its own module declares is stored as that
 * module's layout; one naming a class from anywhere else is stored as a dynamic and cannot be wrong
 * about it. So `Holder` next door, whose `held:Held` crosses a module, takes the safe path and
 * could never catch this.
 */
class Keeper {
	public var kept:Held;

	public function new() {}

	/** @param one Built somewhere else, which is the point of the parameter. */
	public function keep(one:Held):Void {
		kept = one;
	}

	/**
	 * Stores what it is handed onto a value this module built itself.
	 *
	 * **Both halves are needed and neither alone is enough.** The receiver has to be built here, or
	 * the store goes somewhere that casts nothing; the value has to be built elsewhere, or the two
	 * are the same shape already and there is nothing to refuse. Only the pair fails, which is why
	 * `keep` above passes either way and this is the case that pins the bug.
	 *
	 * @param one Built by another module, which is the whole point of the parameter.
	 * @return A fresh one holding it.
	 */
	public function beside(one:Held):Held {
		var fresh:Held = new Held();
		fresh.beside = one;
		return fresh;
	}

	/** @return What it was given, asked through the annotation rather than around it. */
	public function count():Int {
		return kept == null ? -1 : kept.read();
	}
}
