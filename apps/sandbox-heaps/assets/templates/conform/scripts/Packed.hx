import packed.Held;
import packed.Holder;

/**
 * A class of a package, reached from outside it and from inside it.
 *
 * Everything else in this project is flat, and so is the corpus, and a project is neither: it is
 * many modules laid out in packages. The puzzle template is the first thing here shaped that way and
 * it does not run, so these ask the same questions on two modules instead of on twenty-eight, one
 * question each so that a failure says which one.
 */
class Packed {
	/** @return The names of this module's cases. */
	public static function cases():Array<String> {
		return ['madeHere', 'usedHere', 'annotatedHere', 'madeInside', 'usedInside', 'passedOut'];
	}

	/** Constructing a packaged class from a module outside its package. */
	public static function madeHere():Dynamic {
		var h:Held = new Held();
		return 'made ' + (h != null);
	}

	/** Calling a method on one, which is where the puzzle engine stops. */
	public static function usedHere():Dynamic {
		var h:Held = new Held();
		h.bump();
		return h.read();
	}

	/** Whether the value satisfies an annotation naming its own type. */
	public static function annotatedHere():Dynamic {
		var h:Held = new Held();
		var again:Held = h;
		return 'kept ' + (again != null);
	}

	/** The same construction, done by a module of that package instead. */
	public static function madeInside():Dynamic {
		var owner:Holder = new Holder();
		return 'made ' + owner.made();
	}

	/** And the call, done from inside the package, which is the puzzle shape exactly. */
	public static function usedInside():Dynamic {
		var owner:Holder = new Holder();
		return owner.used();
	}

	/** A packaged value handed back across the package boundary and used here. */
	public static function passedOut():Dynamic {
		var owner:Holder = new Holder();
		owner.held.bump();
		return owner.held.read();
	}
}
