import h2d.Object;

/**
 * A host instance, read and written the way a project reads and writes one.
 *
 * Every field here belongs to heaps, not to a script: `x` and `y` are properties with setters,
 * `alpha` and `name` are plain fields, `visible` is a `Bool` property, and `numChildren` is
 * read-only. None of them lives where a scripted class keeps its own, so each is a different path
 * through the compiler than the corpus can reach.
 */
class Objects {
	/** @return The names of this module's cases, which is how the runner finds them. */
	public static function cases():Array<String> {
		return ['position', 'compound', 'boolField', 'floatField', 'stringField', 'children', 'method', 'readOnly'];
	}

	/** Two host properties written and read back. */
	public static function position():Dynamic {
		var o:Object = new Object();
		o.x = 3;
		o.y = 4;
		return o.x + o.y;
	}

	/** A host property read, added to and written in one expression. */
	public static function compound():Dynamic {
		var o:Object = new Object();
		o.x = 1;
		o.x += 2;
		return o.x;
	}

	/** A `Bool` host property, which is the one cppia has no type for. */
	public static function boolField():Dynamic {
		var o:Object = new Object();
		o.visible = false;
		return o.visible;
	}

	/** A plain `Float` field rather than a property. */
	public static function floatField():Dynamic {
		var o:Object = new Object();
		o.alpha = 0.5;
		return o.alpha;
	}

	/** A plain `String` field, which is a pointer rather than a number. */
	public static function stringField():Dynamic {
		var o:Object = new Object();
		o.name = 'hi';
		return o.name;
	}

	/** A host instance really added to another, read back through the parent. */
	public static function children():Dynamic {
		var parent:Object = new Object();
		var child:Object = new Object(parent);
		return parent.numChildren;
	}

	/** A host method with two arguments. */
	public static function method():Dynamic {
		var o:Object = new Object();
		o.setPosition(2, 5);
		return o.x + o.y;
	}

	/** A host property declared `(get, never)`. */
	public static function readOnly():Dynamic {
		var o:Object = new Object();
		return o.numChildren;
	}
}
