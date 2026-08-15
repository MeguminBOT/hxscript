package world;

import h3d.col.Bounds;

/** A box that falls, slides, and can be shot. */
class Body {
	/** How many pieces a target comes apart into. */
	public static inline var PIECES:Int = 7;

	public var x:Float;
	public var y:Float;
	public var z:Float;

	/** Half its width, and it is a cube, so half of everything. */
	public var half:Float;

	public var vx:Float = 0;
	public var vy:Float = 0;
	public var vz:Float = 0;

	/** How far it has spun about z, which only the drawing cares about. */
	public var turn:Float = 0;

	public var spin:Float = 0;

	/** Whether a shot breaks it rather than pushing it. */
	public var breakable:Bool = false;

	/** Whether it is a piece of something that was broken. */
	public var debris:Bool = false;

	/**
	 * Whether it stands where it was put: shot, it takes damage and rocks back rather than moving.
	 *
	 * A target breaks and a crate slides, and neither shows a hit landing on something that stays to
	 * take another. This is the third answer, and the only one that can be shot more than once.
	 */
	public var dummy:Bool = false;

	/** How much more it can take, for the ones that take anything. */
	public var health:Int = 5;

	/** How much it had to start with, which is what it gets back when it returns. */
	public var stock:Int = 5;

	/** Where it stands: where it returns to after being knocked, and after being destroyed. */
	public var restX:Float = 0;

	public var restY:Float = 0;
	public var restZ:Float = 0;

	/** Whether it was resting when it joined the room, which is how it rests when it rejoins one. */
	public var restAsleep:Bool = false;

	/**
	 * Seconds until it comes back, counting only while it is broken, and zero for what stays broken.
	 *
	 * Debris never gets one, so a piece is gone for good and only the thing it came off returns.
	 */
	public var waking:Float = 0;

	/** What it is a piece of, for debris, and null for anything that is a thing in its own right. */
	public var source:Body = null;

	/** How hard a shot pushes it, for the ones a shot pushes. */
	public var shove:Float = 6;

	public var alive:Bool = true;
	public var asleep:Bool = false;
	public var tint:Int = 0xC8CCD6;

	/** Kept rather than made per test, since picking asks every body on every shot. */
	var box:Bounds;

	public function new(x:Float, y:Float, z:Float, half:Float) {
		this.x = x;
		this.y = y;
		this.z = z;
		this.half = half;

		restX = x;
		restY = y;
		restZ = z;

		box = new Bounds();
	}

	/** @return Where it is, as a box, brought up to date. */
	public function bounds():Bounds {
		box.xMin = x - half;
		box.yMin = y - half;
		box.zMin = z - half;
		box.xMax = x + half;
		box.yMax = y + half;
		box.zMax = z + half;

		return box;
	}
}
