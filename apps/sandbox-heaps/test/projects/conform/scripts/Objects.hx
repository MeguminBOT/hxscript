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
	/**
	 * Says what this project is, for somebody who opened it and pressed run.
	 *
	 * There is nothing to draw here. The cases are questions rather than a program, and asking them
	 * means running each one twice, which is the runner's job rather than a script's.
	 */
	public static function main():Void {
		log('This project is a list of questions rather than a program.');
		log('');
		log('  Sandbox --conform conform');
		log('');
		log('Every module here names its own cases, and the runner asks each one interpreted and again');
		log('compiled and says where the two disagree.');
	}

	/** @return The names of this module's cases, which is how the runner finds them. */
	public static function cases():Array<String> {
		return [
			'position', 'compound', 'boolField', 'floatField', 'stringField', 'children', 'method', 'readOnly', 'moved',
			'movedTwice', 'movedByMethod', 'movedByReflect', 'textSet'
		];
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

	/**
	 * A host property whose setter does something besides store.
	 *
	 * Reading `x` back after writing it says nothing: a write that missed `set_x` still leaves the
	 * field holding what was put there. What `set_x` also does is mark the object moved, and nothing
	 * but the framework can see that, so the question has to be asked of the framework: where does
	 * heaps think this object is.
	 */
	public static function moved():Dynamic {
		var o:Object = new Object();
		o.x = 12;
		o.y = 34;

		var at:h2d.col.Point = o.localToGlobal();
		return at.x + ',' + at.y;
	}

	/** The same, written a second time, since the first write is the one a constructor could excuse. */
	public static function movedTwice():Dynamic {
		var o:Object = new Object();
		o.x = 1;
		o.localToGlobal();
		o.x = 7;

		var at:h2d.col.Point = o.localToGlobal();
		return at.x;
	}

	/** The same move made by a method rather than a property, which says whether the reading half is sound. */
	public static function movedByMethod():Dynamic {
		var o:Object = new Object();
		o.setPosition(12, 34);

		var at:h2d.col.Point = o.localToGlobal();
		return at.x + ',' + at.y;
	}

	/** The same move made by the reflection the write is supposed to become. */
	public static function movedByReflect():Dynamic {
		var o:Object = new Object();
		Reflect.setProperty(o, 'x', 12);
		Reflect.setProperty(o, 'y', 34);

		var at:h2d.col.Point = o.localToGlobal();
		return at.x + ',' + at.y;
	}

	/**
	 * A `String` property whose setter rebuilds what the object draws.
	 *
	 * The moved cases go through the writer that takes a number; this is the one that takes a pointer,
	 * which is a different path with the same hazard. Every readout in a real project is this line,
	 * and a write that missed `set_text` leaves the string held and nothing on the screen.
	 */
	public static function textSet():Dynamic {
		var t:h2d.Text = new h2d.Text(hxd.res.DefaultFont.get());
		t.text = 'hello';
		return t.textWidth > 0;
	}
}
