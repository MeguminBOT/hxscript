import h2d.Object;

/**
 * A scripted class that really is an `h2d.Object`.
 *
 * This is the shape the corpus cannot reach at all: extending a class the host compiled goes through
 * a generated bridge, and every field read, field write, method call and `super` on one is different
 * code from the same thing on a class a script declared. What a project does all day.
 */
class Extend {
	/** @return The names of this module's cases. */
	public static function cases():Array<String> {
		return ['build', 'hostWrite', 'ownField', 'ownMethod', 'ownReadsHost', 'addedToHost', 'twoDeep', 'isHost'];
	}

	/** The subclass exists and starts where the base says it does. */
	public static function build():Dynamic {
		var m:Mover = new Mover();
		return m.x;
	}

	/** A field of the base, written through the subclass. */
	public static function hostWrite():Dynamic {
		var m:Mover = new Mover();
		m.x = 9;
		return m.x;
	}

	/** A field the subclass declares, beside the base's. */
	public static function ownField():Dynamic {
		var m:Mover = new Mover();
		m.speed = 4;
		return m.speed;
	}

	/** A method the subclass declares. */
	public static function ownMethod():Dynamic {
		var m:Mover = new Mover();
		return m.doubled(21);
	}

	/** The subclass's own method writing the base's field, which is `this` reaching across the bridge. */
	public static function ownReadsHost():Dynamic {
		var m:Mover = new Mover();
		m.step();
		m.step();
		return m.x;
	}

	/** A scripted instance handed to heaps, which has to accept it as one of its own. */
	public static function addedToHost():Dynamic {
		var parent:Object = new Object();
		var m:Mover = new Mover();
		parent.addChild(m);
		return parent.numChildren;
	}

	/** Scripted extending scripted extending host. */
	public static function twoDeep():Dynamic {
		var r:Racer = new Racer();
		r.step();
		return r.x;
	}

	/** `is` against the base the host compiled. */
	public static function isHost():Dynamic {
		var m:Mover = new Mover();
		return m is Object;
	}
}

/** A scripted `h2d.Object` with a field and a method of its own. */
class Mover extends Object {
	/** A field the base knows nothing about. */
	public var speed:Float = 1;

	public function new() {
		super();
	}

	/** Moves along the base's own property. */
	public function step():Void {
		x += speed;
	}

	/** @return Twice what it was given, so a call can be told from a field. */
	public function doubled(n:Int):Int {
		return n * 2;
	}
}

/** A scripted class extending a scripted class extending a host one. */
class Racer extends Mover {
	public function new() {
		super();
		speed = 10;
	}
}
