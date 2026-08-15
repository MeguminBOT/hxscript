import h3d.col.Bounds;
import h3d.col.Ray;

/**
 * The room, what is in it, and what happens to it. No scene graph anywhere in this file.
 *
 * **Split out from the drawing on purpose, and it is the most useful thing about this example.**
 * Everything here is arithmetic over time: where a shot lands, where a crate slides to, whether a
 * piece has settled. None of it needs a window, so `SelfTest` drives all of it headlessly and the
 * conformance pass compares interpreted against compiled on real gameplay rather than on a list of
 * expressions. A game whose simulation can only run inside a frame is a game whose physics can only
 * be tested by looking at it.
 *
 * Heaps is z up: `z` is height, the floor is `z = 0`, and the room is a box around the origin.
 */
class Sim {
	/** Half the room's width, so the walls stand at plus and minus this. */
	public static inline var ROOM:Float = 9;

	/** How tall the room is. */
	public static inline var HEIGHT:Float = 5;

	/** Downward acceleration, in units per second squared. */
	public static inline var GRAVITY:Float = 18;

	/** How much speed a body keeps when it hits something. */
	public static inline var BOUNCE:Float = 0.35;

	/** How much of its speed a body keeps per second while touching the floor. */
	public static inline var FRICTION:Float = 0.06;

	/** Below this speed a resting body is put to sleep, so a pile stops jittering. */
	public static inline var SLEEP:Float = 0.25;

	public var bodies:Array<Body> = [];
	public var player:Player;

	/** How many shots have been fired, and how many of those hit something. */
	public var shots:Int = 0;

	public var hits:Int = 0;

	public function new() {
		player = new Player();
	}

	/**
	 * Puts a body in the room.
	 *
	 * @param body The body.
	 * @return The same body, so a caller can keep it.
	 */
	public function add(body:Body):Body {
		bodies.push(body);
		return body;
	}

	/**
	 * Advances everything by one step.
	 *
	 * @param dt Seconds since the previous step.
	 */
	public function step(dt:Float):Void {
		player.step(dt);

		for (body in bodies) {
			if (!body.alive || body.asleep) {
				continue;
			}

			body.vz -= GRAVITY * dt;

			body.x += body.vx * dt;
			body.y += body.vy * dt;
			body.z += body.vz * dt;
			body.turn += body.spin * dt;

			contain(body);
		}
	}

	/**
	 * Keeps a body inside the room, and takes the speed a surface absorbs.
	 *
	 * Axis at a time against a box, which is all this room needs: the walls are square to the axes,
	 * so there is no case where a body is inside two of them in a way that has to be resolved
	 * together.
	 *
	 * @param body The body to put back.
	 */
	function contain(body:Body):Void {
		var edge:Float = ROOM - body.half;

		if (body.x < -edge) {
			body.x = -edge;
			body.vx = -body.vx * BOUNCE;
		} else if (body.x > edge) {
			body.x = edge;
			body.vx = -body.vx * BOUNCE;
		}

		if (body.y < -edge) {
			body.y = -edge;
			body.vy = -body.vy * BOUNCE;
		} else if (body.y > edge) {
			body.y = edge;
			body.vy = -body.vy * BOUNCE;
		}

		if (body.z > HEIGHT - body.half) {
			body.z = HEIGHT - body.half;
			body.vz = -body.vz * BOUNCE;
		}

		if (body.z <= body.half) {
			body.z = body.half;
			body.vz = -body.vz * BOUNCE;

			var kept:Float = 1 - FRICTION;
			body.vx *= kept;
			body.vy *= kept;
			body.spin *= kept;

			/**
			 * Asleep rather than merely slow. A body left with a little speed and a little bounce
			 * never quite stops, and a room of them never stops costing anything either.
			 */
			if (Math.abs(body.vz) < SLEEP && Math.abs(body.vx) < SLEEP && Math.abs(body.vy) < SLEEP) {
				body.vx = 0;
				body.vy = 0;
				body.vz = 0;
				body.spin = 0;
				body.asleep = true;
			}
		}
	}

	/**
	 * Fires from where the player is looking, and does whatever hitting implies.
	 *
	 * @return What was hit, or null when the shot found nothing.
	 */
	public function shoot():Null<Body> {
		shots++;

		var hit:Null<Body> = pick(player.x, player.y, player.z, player.dirX(), player.dirY(), player.dirZ());

		if (hit == null) {
			return null;
		}

		hits++;

		if (hit.breakable) {
			shatter(hit);
		} else {
			/** A crate takes the shot as a push along the way the shot was going. */
			hit.vx += player.dirX() * hit.shove;
			hit.vy += player.dirY() * hit.shove;
			hit.vz += player.dirZ() * hit.shove + 2;
			hit.spin += 4;
			hit.asleep = false;
		}

		return hit;
	}

	/**
	 * The nearest body a ray meets.
	 *
	 * Through heaps' own `Bounds.rayIntersection` rather than arithmetic written here, because the
	 * library already has it and a project should reach for that first. It answers a distance along
	 * the ray, or a negative number for a miss, so the nearest hit is the smallest number that is
	 * not one.
	 *
	 * @param ox Where the ray starts.
	 * @param oy Where the ray starts.
	 * @param oz Where the ray starts.
	 * @param dx Which way it goes, as a unit vector.
	 * @param dy Which way it goes.
	 * @param dz Which way it goes.
	 * @return The nearest body it meets, or null.
	 */
	public function pick(ox:Float, oy:Float, oz:Float, dx:Float, dy:Float, dz:Float):Null<Body> {
		var ray:Ray = Ray.fromValues(ox, oy, oz, dx, dy, dz);

		var nearest:Null<Body> = null;
		var best:Float = 1e9;

		for (body in bodies) {
			if (!body.alive) {
				continue;
			}

			var away:Float = body.bounds().rayIntersection(ray, true);

			if (away >= 0 && away < best) {
				best = away;
				nearest = body;
			}
		}

		return nearest;
	}

	/**
	 * Replaces a target with the pieces of one.
	 *
	 * Each piece leaves from the middle at its own speed, which is what makes a break read as a
	 * break rather than as an object vanishing. They are ordinary bodies afterwards, so they fall,
	 * bounce, rub along the floor and go to sleep like anything else.
	 *
	 * @param body The target that was hit.
	 */
	public function shatter(body:Body):Void {
		body.alive = false;

		for (i in 0...Body.PIECES) {
			var piece:Body = new Body(body.x, body.y, body.z, body.half * 0.34);
			var angle:Float = (i / Body.PIECES) * Math.PI * 2;
			var out:Float = 2.5 + Math.random() * 2;

			piece.breakable = false;
			piece.debris = true;
			piece.tint = body.tint;

			piece.x += Math.cos(angle) * body.half * 0.5;
			piece.y += Math.sin(angle) * body.half * 0.5;
			piece.z += (Math.random() - 0.5) * body.half;

			piece.vx = Math.cos(angle) * out + player.dirX() * 2;
			piece.vy = Math.sin(angle) * out + player.dirY() * 2;
			piece.vz = 2 + Math.random() * 3;
			piece.spin = (Math.random() - 0.5) * 12;

			add(piece);
		}
	}

	/** @return How many bodies are still whole, which is what a test counts. */
	public function standing():Int {
		var n:Int = 0;

		for (body in bodies) {
			if (body.alive && !body.debris) {
				n++;
			}
		}

		return n;
	}

	/** @return Whether everything loose has settled, which is how a test knows to stop stepping. */
	public function settled():Bool {
		for (body in bodies) {
			if (body.alive && !body.asleep) {
				return false;
			}
		}

		return true;
	}
}

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

/** Where the shooter is standing and what they are looking at. */
class Player {
	/** How high the eyes are off the floor. */
	public static inline var EYE:Float = 1.7;

	/** How fast walking is, in units per second. */
	public static inline var WALK:Float = 6;

	/** How far the head can tip before it stops, a little short of straight up. */
	public static inline var LIMIT:Float = 1.45;

	public var x:Float = 0;
	public var y:Float = -6;
	public var z:Float = EYE;

	/** Which way they face, in radians, measured about z. */
	public var yaw:Float = Math.PI * 0.5;

	/** How far up or down they are looking. */
	public var pitch:Float = 0;

	public var vz:Float = 0;
	public var onGround:Bool = true;

	public function new() {}

	/**
	 * Turns the head.
	 *
	 * @param dx How far the pointer moved across.
	 * @param dy How far the pointer moved down.
	 */
	public function look(dx:Float, dy:Float):Void {
		yaw -= dx;
		pitch -= dy;

		if (pitch > LIMIT) {
			pitch = LIMIT;
		} else if (pitch < -LIMIT) {
			pitch = -LIMIT;
		}
	}

	/**
	 * Walks, in the direction being faced rather than along the axes.
	 *
	 * Kept off the room's walls by the same margin a body is, so the camera never ends up outside
	 * the room looking back into it.
	 *
	 * @param forward How much forward, from minus one to one.
	 * @param strafe How much sideways, from minus one to one.
	 * @param dt Seconds since the previous step.
	 */
	public function walk(forward:Float, strafe:Float, dt:Float):Void {
		var fx:Float = Math.cos(yaw);
		var fy:Float = Math.sin(yaw);

		var wanted:Float = WALK * dt;
		x += (fx * forward - fy * strafe) * wanted;
		y += (fy * forward + fx * strafe) * wanted;

		var edge:Float = Sim.ROOM - 0.4;

		if (x < -edge) {
			x = -edge;
		} else if (x > edge) {
			x = edge;
		}

		if (y < -edge) {
			y = -edge;
		} else if (y > edge) {
			y = edge;
		}
	}

	/** Leaves the floor, when standing on it. */
	public function jump():Void {
		if (onGround) {
			vz = 6.5;
			onGround = false;
		}
	}

	/**
	 * Falls, and lands.
	 *
	 * @param dt Seconds since the previous step.
	 */
	public function step(dt:Float):Void {
		if (onGround) {
			return;
		}

		vz -= Sim.GRAVITY * dt;
		z += vz * dt;

		if (z <= EYE) {
			z = EYE;
			vz = 0;
			onGround = true;
		}
	}

	/** @return Which way they are looking, along x. */
	public function dirX():Float {
		return Math.cos(yaw) * Math.cos(pitch);
	}

	/** @return Which way they are looking, along y. */
	public function dirY():Float {
		return Math.sin(yaw) * Math.cos(pitch);
	}

	/** @return Which way they are looking, along z. */
	public function dirZ():Float {
		return Math.sin(pitch);
	}
}
