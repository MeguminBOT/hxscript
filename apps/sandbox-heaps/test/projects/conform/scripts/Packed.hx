import packed.Held;
import packed.Holder;
import packed.Keeper;

/**
 * A class of a package, reached from outside it and from inside it.
 *
 * Everything else in this project is flat, and so is the corpus, and a project is neither: it is
 * many modules laid out in packages. These ask the same questions on two modules, one question
 * each, so that a failure says which one.
 */
class Packed {
	/** @return The names of this module's cases. */
	public static function cases():Array<String> {
		return [
			'madeHere', 'usedHere', 'annotatedHere', 'madeInside', 'usedInside', 'passedOut', 'keptAsItsOwnType',
			'keptThenReadBack', 'storedOnOneBuiltThere'
		];
	}

	/** Constructing a packaged class from a module outside its package. */
	public static function madeHere():Dynamic {
		var h:Held = new Held();
		return 'made ' + (h != null);
	}

	/** Calling a method on one, which is where a multi-module project stops. */
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

	/** And the call, done from inside the package, which is the shape that failed. */
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

	/**
	 * A value built here, stored on the keeper itself rather than on one it built.
	 *
	 * The near miss, and worth having beside `storedOnOneBuiltThere` for exactly that: the value
	 * crosses a module and the field names its own module's type, which sounds like the same
	 * question and is not. This one always passed.
	 */
	public static function keptAsItsOwnType():Dynamic {
		var one:Held = new Held();
		one.bump();
		one.bump();

		var box:Keeper = new Keeper();
		box.keep(one);

		return 'kept ' + box.count();
	}

	/** The same value read back out of the field, so a store that quietly kept the wrong thing shows. */
	public static function keptThenReadBack():Dynamic {
		var one:Held = new Held();
		var box:Keeper = new Keeper();

		box.keep(one);
		box.kept.bump();

		return 'same ' + (one.read() == 1) + ' via ' + box.count();
	}

	/**
	 * A value built here, stored onto one the other module built, by that module.
	 *
	 * The pair that fails. Everything else here has the value and the field agreeing about which
	 * module made them, and this is the one arrangement where they do not.
	 */
	public static function storedOnOneBuiltThere():Dynamic {
		var one:Held = new Held();
		one.bump();
		one.bump();

		var box:Keeper = new Keeper();
		var fresh:Held = box.beside(one);

		return 'beside ' + (fresh.beside == null ? -1 : fresh.beside.read());
	}
}
