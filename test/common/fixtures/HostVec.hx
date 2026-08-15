/** What a `HostVec` boxes, so the abstract has something real underneath it. */
class HostVecImpl {
	public var x:Float;
	public var y:Float;

	public function new(x:Float, y:Float) {
		this.x = x;
		this.y = y;
	}

	public function toString():String {
		return x + ':' + y;
	}
}

/**
 * A host abstract shaped like the ones a framework is written in.
 *
 * Every geometry type in heaps is this: `@:forward abstract` over an implementation class, with an
 * `inline function new` that assigns to `this`. `h3d.Vector`, `h3d.Matrix` and `h2d.col.Point` are
 * all it, and between them they are what every position, transform and bounds test in a project is
 * written in.
 *
 * The shape matters because the constructor has nowhere to live. Assigning to `this` has no meaning
 * as a method on a value, so Haxe emits it as a static `_new` on the implementation class, and a
 * script writing `new HostVec(3, 4)` has to reach that or mean nothing at all.
 *
 * `@:build` here rather than through a preset because this is a fixture: the corpus builds against a
 * bare host, and this is the whole of the host it needs for these cases.
 */
@:build(hxscript.macro.Abstract.build())
@:forward
abstract HostVec(HostVecImpl) from HostVecImpl to HostVecImpl {
	public inline function new(x:Float, y:Float) {
		this = new HostVecImpl(x, y);
	}

	/** A property, so the wrapper has one to forward. */
	public var length(get, never):Float;

	inline function get_length():Float {
		return Math.sqrt(this.x * this.x + this.y * this.y);
	}

	/** A method taking another of the same abstract, which is the argument shape that boxes. */
	public inline function plus(other:HostVec):HostVec {
		return new HostVec(this.x + other.x, this.y + other.y);
	}

	/** An operator, since an abstract's operators are the other half of what a wrapper re-exposes. */
	@:op(A * B) public inline function scaled(by:Float):HostVec {
		return new HostVec(this.x * by, this.y * by);
	}
}
