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
		return [
			'build', 'hostWrite', 'ownField', 'ownMethod', 'ownReadsHost', 'addedToHost', 'twoDeep', 'isHost', 'ownMoved',
			'hostMoved', 'sharedStatic', 'sharedFlag', 'sharedCount', 'sharedThroughMethods'
		];
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

	/**
	 * Where heaps thinks the subclass got to, rather than what its field says.
	 *
	 * `ownReadsHost` reads `x` back, and a write that stored the number without running `set_x` reads
	 * back correctly and leaves the object never told it moved. Asking heaps is the only question the
	 * two answers differ on, and it is the one a project cares about, since it is what gets drawn.
	 */
	public static function ownMoved():Dynamic {
		var m:Mover = new Mover();
		m.step();
		m.step();

		var at:h2d.col.Point = m.localToGlobal();
		return at.x;
	}

	/** The same, written from outside rather than by the subclass's own method. */
	public static function hostMoved():Dynamic {
		var m:Mover = new Mover();
		m.x = 6;

		var at:h2d.col.Point = m.localToGlobal();
		return at.x;
	}

	/**
	 * A static of another module, written and then read back.
	 *
	 * **The receiver of the read is a class that extends a host one, and that is the whole case.** A
	 * batch is one module, so `Shared` is not in this one, and a name from outside the batch has more
	 * than one thing it could be: a class the world holds, a member of the host base this class
	 * extends, or nothing at all. Reading it as a value bound once when the module loaded is the
	 * answer that looks right forever and is right only on the first frame, which is how a game ends
	 * up never leaving its title screen.
	 */
	public static function sharedStatic():Dynamic {
		var m:Mover = new Mover();
		Shared.pending = null;

		var before:Dynamic = m.peek();
		Shared.pending = 'here';

		return before + ' then ' + m.peek();
	}

	/** The same for a `Bool`, which is the shape a flag takes and a different register. */
	public static function sharedFlag():Dynamic {
		var m:Mover = new Mover();
		Shared.raised = false;

		var before:Bool = m.flag();
		Shared.raised = true;

		return before + ' then ' + m.flag();
	}

	/** And for an `Int`, read enough times that a frozen one would show. */
	public static function sharedCount():Dynamic {
		var m:Mover = new Mover();
		Shared.count = 0;

		var total:Int = 0;

		for (i in 0...5) {
			Shared.count = i;
			total += m.counted();
		}

		return total;
	}

	/** Through its methods rather than its fields, which is the other half of the same reach. */
	public static function sharedThroughMethods():Dynamic {
		var m:Mover = new Mover();
		Shared.pending = null;

		m.offer('sent');
		return Std.string(Shared.take());
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

	/** @return Another module's static, read from inside a class that extends a host one. */
	public function peek():Dynamic {
		return Shared.pending;
	}

	/** @return The same as a `Bool`. */
	public function flag():Bool {
		return Shared.raised;
	}

	/** @return The same as an `Int`. */
	public function counted():Int {
		return Shared.count;
	}

	/** @param value What to hand another module. */
	public function offer(value:Dynamic):Void {
		Shared.offer(value);
	}
}

/** A scripted class extending a scripted class extending a host one. */
class Racer extends Mover {
	public function new() {
		super();
		speed = 10;
	}
}
