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
	public static inline var ROOM:Float = 26;

	/** How tall the room is. */
	public static inline var HEIGHT:Float = 9;

	/** Downward acceleration, in units per second squared. */
	public static inline var GRAVITY:Float = 18;

	/** How much speed a body keeps when it hits something. */
	public static inline var BOUNCE:Float = 0.35;

	/** How much of its speed a body keeps per second while touching the floor. */
	public static inline var FRICTION:Float = 0.06;

	/** Below this speed a resting body is put to sleep, so a pile stops jittering. */
	public static inline var SLEEP:Float = 0.25;

	/** How wide the player is, for shoving things out of the way. */
	public static inline var GIRTH:Float = 0.45;

	/** How much of the overlap two boxes give back per step, from nothing to all of it. */
	public static inline var PUSH:Float = 0.6;

	/** How hard walking into something pushes it, in units per second. */
	public static inline var WALK_SHOVE:Float = 0.9;

	/**
	 * How many pieces of broken target the room keeps.
	 *
	 * Debris never stopped existing, and every pair of bodies is considered when they are separated,
	 * so the cost of a room grew as the square of how long it had been played in.
	 */
	public static inline var DEBRIS:Int = 40;

	/** How far a shot rocks a dummy back before it returns. */
	public static inline var KNOCK:Float = 0.42;

	/** How quickly a dummy comes back upright, as the fraction of the way closed per second. */
	public static inline var SETTLE:Float = 6;

	/**
	 * How long a broken target stays broken before it is put back where it stood.
	 *
	 * A room that is shot at empties, and an example that empties is one nobody can look at twice.
	 */
	public static inline var RESPAWN:Float = 60;

	public var bodies:Array<Body> = [];

	/** The buildings: fixed boxes that are walked into, walked onto, and shot at. */
	public var blocks:Array<Slab> = [];

	public var player:Player;

	/** How many shots have been fired, and how many of those hit something. */
	public var shots:Int = 0;

	public var hits:Int = 0;

	/**
	 * Where the last shot ended up, and how far away that was.
	 *
	 * Kept because a shot is decided from the eye and drawn from the muzzle, and those are not the
	 * same place. A streak sent along the look direction from the muzzle runs parallel to the aim
	 * and never crosses it, so it lands beside whatever the crosshair was on by however far the gun
	 * is held to one side. Given the point instead, it converges on the mark like a shot does.
	 */
	public var hitX:Float = 0;

	public var hitY:Float = 0;
	public var hitZ:Float = 0;

	/** How far the last shot got before something stopped it. */
	public var range:Float = 0;

	/** How many bodies have been handed a number, which is where the next one comes from. */
	var given:Int = 0;

	public function new() {
		player = new Player();

		/** The same array, not a copy, so a building added later is one the player can already feel. */
		player.blocks = blocks;
	}

	/**
	 * Puts a building in the room.
	 *
	 * @param x Where its middle is.
	 * @param y Where its middle is.
	 * @param hx Half its width.
	 * @param hy Half its depth.
	 * @param tall How tall it is, measured from the floor.
	 * @param tint What colour.
	 * @return The building.
	 */
	public function build(x:Float, y:Float, hx:Float, hy:Float, tall:Float, tint:Int):Slab {
		var slab:Slab = new Slab(x, y, tall * 0.5, hx, hy, tall * 0.5);
		slab.tint = tint;

		blocks.push(slab);
		return slab;
	}

	/**
	 * Puts a body in the room.
	 *
	 * @param body The body.
	 * @return The same body, so a caller can keep it.
	 */
	public function add(body:Body):Body {
		/**
		 * How it was handed over is how it goes back.
		 *
		 * **A target hangs in the air, and waking one would drop it.** Whether a body rests where it
		 * is put or falls from it is the caller's decision, made after it is built and before it is
		 * added, so this is the only moment that knows. Without it every target that came back would
		 * land at the player's feet the second time round, and the room would quietly flatten itself
		 * over a few minutes of play.
		 */
		body.restAsleep = body.asleep;

		/** Never zero, so debris can name what it came off and nothing can name a body that has none. */
		body.id = ++given;

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
			if (!body.alive) {
				continue;
			}

			/** A dummy is fixed in place and only ever leans, so it never falls and never sleeps. */
			if (body.dummy) {
				var back:Float = Math.min(1, SETTLE * dt);

				body.x += (body.restX - body.x) * back;
				body.y += (body.restY - body.y) * back;
				body.turn += body.spin * dt;
				body.spin *= 1 - back;
				continue;
			}

			if (body.asleep) {
				continue;
			}

			body.vz -= GRAVITY * dt;

			body.x += body.vx * dt;
			body.y += body.vy * dt;
			body.z += body.vz * dt;
			body.turn += body.spin * dt;

			contain(body);
		}

		separate();
		shove();
		tidy();
		respawn(dt);
	}

	/**
	 * Puts broken targets back, and takes their pieces away as they go.
	 *
	 * **The pieces go at the same moment, and that is the whole reason they are tagged.** A target
	 * coming back while what it broke into is still lying at its feet reads as two of the same
	 * thing, so the return is not a target appearing, it is a target appearing and its own wreckage
	 * ceasing to be. `tidy` would eventually take the pieces anyway, but on its own schedule, and
	 * "eventually" is what makes it look like a bug rather than a rule.
	 *
	 * The inner loop only runs on the frame a target actually returns, which is at most a handful of
	 * frames a minute.
	 *
	 * @param dt Seconds since the previous step.
	 */
	function respawn(dt:Float):Void {
		for (body in bodies) {
			if (body.alive || body.waking <= 0) {
				continue;
			}

			body.waking -= dt;

			if (body.waking > 0) {
				continue;
			}

			for (piece in bodies) {
				if (piece.sourceId == body.id) {
					piece.alive = false;
					piece.sourceId = 0;
				}
			}

			body.x = body.restX;
			body.y = body.restY;
			body.z = body.restZ;
			body.vx = 0;
			body.vy = 0;
			body.vz = 0;
			body.turn = 0;
			body.spin = 0;
			body.health = body.stock;
			body.asleep = body.restAsleep;
			body.alive = true;
		}
	}

	/**
	 * Keeps boxes out of each other.
	 *
	 * Every pair, which is honest arithmetic for a room holding a few dozen things and would not be
	 * for a world holding thousands: that is when a grid earns its keep, and this is not that.
	 *
	 * Resolved along the axis they overlap least, which is what makes a stack behave. Two boxes
	 * side by side overlap least across, so they part sideways; one landing on another overlaps
	 * least vertically, so it is put on top rather than shot out from under.
	 */
	function separate():Void {
		for (i in 0...bodies.length) {
			var a:Body = bodies[i];

			if (!a.alive || a.dummy) {
				continue;
			}

			for (j in (i + 1)...bodies.length) {
				var b:Body = bodies[j];

				if (!b.alive || b.dummy) {
					continue;
				}

				/**
				 * **Two things that are both asleep cannot start touching.** Neither has moved since
				 * the last step, so whatever they were doing then they are still doing, and the pair
				 * needs no arithmetic at all.
				 *
				 * This is the whole cost of the pass in practice. Every shattered target leaves seven
				 * pieces that never go away, so a room played in for a minute holds well over a
				 * hundred bodies and the pairs between them grow as the square: the floor of settled
				 * debris was being tested against itself, every pair, every frame, forever.
				 */
				if (a.asleep && b.asleep) {
					continue;
				}

				part(a, b);
			}
		}
	}

	/**
	 * Takes the oldest debris away once there is too much of it.
	 *
	 * A limit rather than a lifetime, so a room that is being shot at steadily holds a constant
	 * amount rather than a growing one, and the pieces that go are the ones that landed longest ago.
	 */
	function tidy():Void {
		var loose:Int = 0;

		for (body in bodies) {
			if (body.alive && body.debris) {
				loose++;
			}
		}

		var over:Int = loose - DEBRIS;

		if (over <= 0) {
			return;
		}

		var i:Int = 0;

		while (over > 0 && i < bodies.length) {
			if (bodies[i].alive && bodies[i].debris) {
				bodies[i].alive = false;
				over--;
			}

			i++;
		}
	}

	/**
	 * Puts two boxes back out of one another, and trades the speed the collision takes.
	 *
	 * @param a One box.
	 * @param b The other.
	 */
	function part(a:Body, b:Body):Void {
		var dx:Float = b.x - a.x;
		var dy:Float = b.y - a.y;
		var dz:Float = b.z - a.z;

		var reach:Float = a.half + b.half;

		var ox:Float = reach - Math.abs(dx);
		var oy:Float = reach - Math.abs(dy);
		var oz:Float = reach - Math.abs(dz);

		if (ox <= 0 || oy <= 0 || oz <= 0) {
			return;
		}

		a.asleep = false;
		b.asleep = false;

		if (ox <= oy && ox <= oz) {
			var way:Float = dx < 0 ? -1 : 1;
			var give:Float = ox * PUSH * 0.5;

			a.x -= way * give;
			b.x += way * give;

			var swap:Float = (a.vx + b.vx) * 0.5;
			a.vx = swap - (a.vx - swap) * BOUNCE;
			b.vx = swap - (b.vx - swap) * BOUNCE;
		} else if (oy <= oz) {
			var way:Float = dy < 0 ? -1 : 1;
			var give:Float = oy * PUSH * 0.5;

			a.y -= way * give;
			b.y += way * give;

			var swap:Float = (a.vy + b.vy) * 0.5;
			a.vy = swap - (a.vy - swap) * BOUNCE;
			b.vy = swap - (b.vy - swap) * BOUNCE;
		} else {
			var way:Float = dz < 0 ? -1 : 1;
			var give:Float = oz * PUSH * 0.5;

			a.z -= way * give;
			b.z += way * give;

			var swap:Float = (a.vz + b.vz) * 0.5;
			a.vz = swap - (a.vz - swap) * BOUNCE;
			b.vz = swap - (b.vz - swap) * BOUNCE;
		}

		contain(a);
		contain(b);
	}

	/**
	 * Lets the player walk things out of the way.
	 *
	 * The player is a post rather than a box: a circle across, and tall enough to reach anything
	 * standing on the floor. Walking into something gives it speed rather than moving it outright,
	 * so it carries on after the player stops and settles the way anything else does.
	 */
	function shove():Void {
		for (body in bodies) {
			if (!body.alive || body.dummy) {
				continue;
			}

			/** Only what the player could actually walk into, rather than anything overhead. */
			if (body.z - body.half > player.z || body.z + body.half < 0) {
				continue;
			}

			var dx:Float = body.x - player.x;
			var dy:Float = body.y - player.y;

			var reach:Float = GIRTH + body.half;
			var away:Float = Math.sqrt(dx * dx + dy * dy);

			if (away >= reach) {
				continue;
			}

			/** Dead centre has no direction to leave in, so it is nudged along the axis instead. */
			if (away < 0.0001) {
				dx = 1;
				dy = 0;
				away = 1;
			}

			var nx:Float = dx / away;
			var ny:Float = dy / away;
			var into:Float = reach - away;

			body.x += nx * into;
			body.y += ny * into;

			body.vx += nx * WALK_SHOVE;
			body.vy += ny * WALK_SHOVE;
			body.asleep = false;

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

		for (slab in blocks) {
			slab.push(body);
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
	 * Fires exactly where the player is looking, and does whatever hitting implies.
	 *
	 * @return What was hit, or null when the shot found nothing.
	 */
	public function shoot():Null<Body> {
		return shootAlong(player.dirX(), player.dirY(), player.dirZ());
	}

	/**
	 * Fires along a given direction, which is how a shot gets to miss on purpose.
	 *
	 * **The spread is chosen by the caller, and that keeps the randomness out of here.** A gun that
	 * scattered its own shots would be a simulation nothing could assert about: every case would
	 * have to allow for wherever the die landed, which is the same as asserting nothing. So `shoot`
	 * is the exact shot the tests drive, this is the one the game fires, and the die is rolled where
	 * the trigger is pulled.
	 *
	 * @param dx Which way the shot goes, as a unit vector.
	 * @param dy Which way it goes.
	 * @param dz Which way it goes.
	 * @return What was hit, or null when the shot found nothing.
	 */
	public function shootAlong(dx:Float, dy:Float, dz:Float):Null<Body> {
		shots++;

		var hit:Null<Body> = pick(player.x, player.y, player.z, dx, dy, dz);

		if (hit == null) {
			return null;
		}

		hits++;

		if (hit.dummy) {
			/**
			 * Knocked rather than moved. It is shoved along the shot and pulled back to where it
			 * stands, so the hit reads as an impact instead of as the thing being pushed away.
			 */
			hit.health--;

			hit.x += dx * KNOCK;
			hit.y += dy * KNOCK;
			hit.spin += 2.2;

			/** Down once it has taken everything it can, and back on its feet after the same minute. */
			if (hit.health <= 0) {
				hit.alive = false;
				hit.waking = RESPAWN;
			}
		} else if (hit.breakable) {
			shatter(hit);
		} else {
			/** A crate takes the shot as a push along the way the shot was going. */
			hit.vx += dx * hit.shove;
			hit.vy += dy * hit.shove;
			hit.vz += dz * hit.shove + 2;
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

		/**
		 * A building stops a shot. Whatever stands behind one is not hit, which is the difference
		 * between cover and decoration.
		 */
		for (slab in blocks) {
			var wall:Float = slab.bounds().rayIntersection(ray, true);

			if (wall >= 0 && wall < best) {
				best = wall;
			}
		}

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

		/**
		 * Where it stopped, for whoever draws the shot rather than resolves it.
		 *
		 * **A miss still lands somewhere.** `pick` knows about buildings and bodies and nothing about
		 * the room itself, so a shot into open air comes back with no hit and no distance, and a
		 * streak drawn to that would fly forever. `clearance` walks the room's own walls, floor and
		 * ceiling and takes whichever is nearer, so every shot has an end.
		 */
		range = clearance(ox, oy, oz, dx, dy, dz, best);

		hitX = ox + dx * range;
		hitY = oy + dy * range;
		hitZ = oz + dz * range;

		return nearest;
	}

	/**
	 * How far a ray gets before a building, a wall, the floor or the ceiling stops it.
	 *
	 * The half of the room `pick` does not know about. `pick` asks the buildings and the bodies,
	 * which is everything a shot can hit and nothing a shot can merely stop at, so this answers the
	 * rest and takes whichever comes first.
	 *
	 * @param ox Where the ray starts.
	 * @param oy Where the ray starts.
	 * @param oz Where the ray starts.
	 * @param dx Which way it goes, as a unit vector.
	 * @param dy Which way it goes.
	 * @param dz Which way it goes.
	 * @param most The furthest worth knowing about.
	 * @return How far it got, never more than `most`.
	 */
	public function clearance(ox:Float, oy:Float, oz:Float, dx:Float, dy:Float, dz:Float, most:Float):Float {
		var ray:Ray = Ray.fromValues(ox, oy, oz, dx, dy, dz);
		var best:Float = most;

		for (slab in blocks) {
			var wall:Float = slab.bounds().rayIntersection(ray, true);

			if (wall >= 0 && wall < best) {
				best = wall;
			}
		}

		/** The room's own shell, which is not a building and stops a shot just as well. */
		var edge:Float = ROOM;

		if (dx > 0.0001) {
			best = Math.min(best, (edge - ox) / dx);
		} else if (dx < -0.0001) {
			best = Math.min(best, (-edge - ox) / dx);
		}

		if (dy > 0.0001) {
			best = Math.min(best, (edge - oy) / dy);
		} else if (dy < -0.0001) {
			best = Math.min(best, (-edge - oy) / dy);
		}

		if (dz > 0.0001) {
			best = Math.min(best, (HEIGHT - oz) / dz);
		} else if (dz < -0.0001) {
			best = Math.min(best, -oz / dz);
		}

		return best < 0 ? 0 : best;
	}

	/**
	 * @param x Where.
	 * @param y Where.
	 * @return How high the ground is there: a roof if one is over that spot, the floor otherwise.
	 */
	public function groundAt(x:Float, y:Float):Float {
		var best:Float = 0;

		for (slab in blocks) {
			if (slab.over(x, y, 0) && slab.top() > best) {
				best = slab.top();
			}
		}

		return best;
	}

	/**
	 * Whether something of this size can stand here without being inside a building.
	 *
	 * What keeps a scattered room from putting half its crates through a wall. Checked against the
	 * sides only: something resting on a roof is standing on a building rather than in one, and
	 * `groundAt` is what puts it there.
	 *
	 * @param x Where.
	 * @param y Where.
	 * @param z Where, vertically.
	 * @param half Half its width.
	 * @return Whether the spot is clear.
	 */
	public function free(x:Float, y:Float, z:Float, half:Float):Bool {
		for (slab in blocks) {
			if (!slab.over(x, y, half)) {
				continue;
			}

			/** Above the roof is clear; anything overlapping the body of it is not. */
			if (z - half < slab.top() - 0.02 && z + half > slab.z - slab.hz) {
				return false;
			}
		}

		return true;
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
		body.waking = RESPAWN;

		for (i in 0...Body.PIECES) {
			var piece:Body = new Body(body.x, body.y, body.z, body.half * 0.34);
			var angle:Float = (i / Body.PIECES) * Math.PI * 2;
			var out:Float = 2.5 + Math.random() * 2;

			piece.breakable = false;
			piece.debris = true;
			piece.tint = body.tint;

			/** Whose piece it is, so it can be taken away on the frame that one comes back. */
			piece.sourceId = body.id;

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

	/** Which body this is, given out by `Sim.add` and never reused. */
	public var id:Int = 0;

	/**
	 * Which body this is a piece of, for debris, and zero for anything that is a thing in itself.
	 *
	 * **A number rather than the body itself, and that is worth a word.** The obvious way to write
	 * this is `source:Body`, and it does not survive the trip through the compiler: a field declared
	 * as another scripted class is stored as the compiled layout of that class, and a body that
	 * reached this function as an argument from interpreted code is still the interpreter's own
	 * object, so the store refuses it. `sourceId` is an `Int` on both sides of that line.
	 *
	 * It is also the better model regardless. A reference from the wreckage to what it came off
	 * keeps the broken thing reachable for as long as any piece of it is, which is the wrong way
	 * round: the pieces are the temporary half.
	 */
	public var sourceId:Int = 0;

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


/** Where the shooter is standing and what they are looking at. */
class Player {
	/** How high the eyes are off the floor, standing and crouched. */
	public static inline var EYE:Float = 1.7;

	public static inline var CROUCH_EYE:Float = 1;

	/** How much faster sprinting is, and how much slower crouching is. */
	public static inline var SPRINT:Float = 1.75;

	public static inline var CREEP:Float = 0.45;

	/** How fast walking is, in units per second. */
	public static inline var WALK:Float = 6;

	/**
	 * How hard the air can be steered, in units per second squared.
	 *
	 * Small next to `WALK` on purpose. It is enough to place a landing and not enough to walk about
	 * in mid air, which is the difference between a jump you aim and a jump you fly.
	 */
	public static inline var AIR:Float = 14;

	/**
	 * How fast the air may be steered, measured only along the direction being asked for.
	 *
	 * **Along that direction and no other, which is the whole trick.** Capping the total speed
	 * instead looks equivalent and is not: every unit of sideways speed then has to come out of the
	 * forward speed, so steering a jump quietly bleeds it away and a leap turns into a shuffle. The
	 * cap here asks how fast the player is already going the way they are pushing, and only makes up
	 * the difference, so a push across a jump cannot touch the jump.
	 *
	 * It also means holding forward in mid air does nothing once running: the speed along forward is
	 * already past this, so there is nothing to add.
	 */
	public static inline var AIR_CAP:Float = 3;

	/** How quickly a standing player stops, as the fraction of speed shed per second. */
	public static inline var STOP:Float = 12;

	/**
	 * How high a lip can be and still be walked over rather than into.
	 *
	 * Without one, a doorstep is a wall: a surface a hair above the feet is something to be pushed
	 * out of, and every join in the floor stops a player dead.
	 */
	public static inline var STEP:Float = 0.7;

	/** How far the head can tip before it stops, a little short of straight up. */
	public static inline var LIMIT:Float = 1.45;

	/** How far one shot throws the aim up, in radians. */
	public static inline var KICK:Float = 0.026;

	/** How fast the aim comes back down afterwards, in radians per second. */
	public static inline var RECOVER:Float = 2.2;

	/**
	 * Which way round the horizontal axis runs once it is on screen.
	 *
	 * **Strafing and turning share this, and that is the point of it being one number.** heaps builds
	 * its camera left handed unless told otherwise, so the horizontal axis of the world arrives on
	 * screen mirrored against what the right hand rule says: `forward` crossed with `up` is the
	 * correct right in the world and the left of the picture. Turning is mirrored by exactly the same
	 * amount, because it is the same axis.
	 *
	 * So they were wrong together and could only be fixed together. Flipping the sign of the cross
	 * product on its own swapped strafing and left the mouse turning the other way, which reads as
	 * two bugs and is one. Change this to `1` and both go back.
	 */
	public static inline var HAND:Float = -1;

	/** @return How high the eyes are, between standing and crouched. */
	public function eye():Float {
		return EYE - (EYE - CROUCH_EYE) * stance;
	}

	/**
	 * @return How fast they are trying to move.
	 *
	 * Sprinting is ignored while crouched, because a player asking for both is asking for the one
	 * that has a posture attached to it.
	 */
	public function pace():Float {
		if (stance > 0.4) {
			return WALK * CREEP;
		}

		return sprinting ? WALK * SPRINT : WALK;
	}

	/** @return Which way they face, flattened onto the ground. */
	public function dirFlatX():Float {
		return Math.cos(yaw);
	}

	/** @return Which way they face, flattened onto the ground. */
	public function dirFlatY():Float {
		return Math.sin(yaw);
	}

	/**
	 * @return The right of the picture, along x.
	 *
	 * **Everything that means "to the right" comes from here.** Walking and whatever the player is
	 * holding were each working it out separately, and one of them had `HAND` on the distance rather
	 * than on the direction, which is the same expression with the opposite sign. Strafing was right
	 * and the gun was on the wrong side of the screen, twice, for that reason alone.
	 */
	public function rightX():Float {
		return Math.sin(yaw) * HAND;
	}

	/** @return The right of the picture, along y. */
	public function rightY():Float {
		return -Math.cos(yaw) * HAND;
	}

	public var x:Float = 0;
	public var y:Float = -6;
	public var z:Float = EYE;

	/** Which way they face, in radians, measured about z. */
	public var yaw:Float = Math.PI * 0.5;

	/** How far up or down they are looking. */
	public var pitch:Float = 0;

	/** How much of the recoil climb has still to be given back. */
	public var owed:Float = 0;

	public var vz:Float = 0;

	/**
	 * How fast they are moving across the ground.
	 *
	 * **Momentum, which movement did not have.** Walking used to write straight to the position, so
	 * there was nothing to carry: a jump forward went forward only for as long as forward was held,
	 * and touching strafe in the air replaced the whole movement with a sideways one. Speed is kept
	 * here now and the position follows from it, so a jump keeps what it left the ground with.
	 */
	public var vx:Float = 0;

	public var vy:Float = 0;

	public var onGround:Bool = true;

	/** The buildings, shared with the room so one added later is felt immediately. */
	public var blocks:Array<Slab> = [];

	/**
	 * How far down the player is, from standing to fully crouched.
	 *
	 * A number rather than a flag because the eyes have to travel: cutting between two heights reads
	 * as the world jumping rather than as the player ducking. Everything that asks how high the eyes
	 * are goes through `eye`, so nothing has to know the difference.
	 */
	public var stance:Float = 0;

	/** What the controls are asking for this step. */
	public var crouching:Bool = false;

	public var sprinting:Bool = false;

	/** Which way the controls are asking to go this step, and whether they are asking at all. */
	var wishX:Float = 0;

	var wishY:Float = 0;
	var steering:Bool = false;

	public function new() {}

	/**
	 * Turns the head.
	 *
	 * @param dx How far the pointer moved across.
	 * @param dy How far the pointer moved down.
	 */
	public function look(dx:Float, dy:Float):Void {
		yaw -= dx * HAND;
		pitch -= dy;

		if (pitch > LIMIT) {
			pitch = LIMIT;
		} else if (pitch < -LIMIT) {
			pitch = -LIMIT;
		}

		/**
		 * **Pulling down cancels the climb rather than adding to it.** A player fighting recoil pulls
		 * the aim down themselves, and if the automatic recovery still owed that much it would take it
		 * again a moment later and drag the view below where they put it. So their correction is spent
		 * against the debt: whatever they pull down is that much less the gun has left to give back.
		 */
		if (dy > 0 && owed > 0) {
			owed -= dy;

			if (owed < 0) {
				owed = 0;
			}
		}
	}

	/**
	 * Throws the aim up, the way firing does.
	 *
	 * **Up, because that is where a gun goes.** The barrel sits above the hand holding it, so the
	 * push from a shot passes over the wrist and rotates the whole thing back and up. Firing a burst
	 * therefore walks the shots up the target, and holding the trigger down costs accuracy, which is
	 * the entire reason a game bothers to model recoil rather than just flashing the muzzle.
	 *
	 * What it takes is recorded rather than assumed, so a shot fired while already looking straight
	 * up owes nothing back and cannot pull the view below where it started.
	 *
	 * @param up How far, in radians.
	 */
	public function kick(up:Float):Void {
		var was:Float = pitch;

		pitch += up;

		if (pitch > LIMIT) {
			pitch = LIMIT;
		}

		owed += pitch - was;
	}

	/**
	 * Lets the aim back down after it has been kicked up.
	 *
	 * @param dt Seconds since the previous step.
	 */
	function settle(dt:Float):Void {
		if (owed <= 0) {
			return;
		}

		var back:Float = Math.min(owed, RECOVER * dt);

		pitch -= back;
		owed -= back;
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
		wishX = dirFlatX() * forward + rightX() * strafe;
		wishY = dirFlatY() * forward + rightY() * strafe;

		/** Held to one unit, so going diagonally is not faster than going straight. */
		var length:Float = Math.sqrt(wishX * wishX + wishY * wishY);

		if (length > 0.0001) {
			wishX /= length;
			wishY /= length;
			steering = true;
		}
	}

	/**
	 * Turns what the controls asked for into speed, and speed into distance.
	 *
	 * **The ground and the air are different on purpose.** On the ground the controls own the
	 * velocity outright, which is what makes walking feel immediate rather than skated. In the air
	 * they may only add to it, a little, so a jump keeps the speed it took off with and steering
	 * places the landing instead of replacing the leap.
	 *
	 * Air steering never subtracts. It adds along the direction asked for, and only enough to bring
	 * the speed in that direction up to `AIR_CAP`, so a jump keeps everything it left with.
	 *
	 * @param dt Seconds since the previous step.
	 */
	function move(dt:Float):Void {
		if (onGround) {
			if (steering) {
				vx = wishX * pace();
				vy = wishY * pace();
			} else {
				var shed:Float = Math.max(0, 1 - STOP * dt);
				vx *= shed;
				vy *= shed;
			}
		} else if (steering) {
			/** How fast they are already going the way they are pushing, which may be backwards. */
			var into:Float = vx * wishX + vy * wishY;
			var room:Float = AIR_CAP - into;

			if (room > 0) {
				var add:Float = Math.min(AIR * dt, room);

				vx += wishX * add;
				vy += wishY * add;
			}
		}

		x += vx * dt;
		y += vy * dt;

		/**
		 * Out of any building the step landed inside.
		 *
		 * Only the ones that are genuinely in the way. A roof at or below knee height is something to
		 * walk up onto, handled by `support`, so pushing out of it here would stop the player at the
		 * foot of every stair.
		 */
		var feet:Float = z - eye();

		for (slab in blocks) {
			if (slab.top() <= feet + STEP || slab.z - slab.hz >= z) {
				continue;
			}

			var dx:Float = x - slab.x;
			var dy:Float = y - slab.y;

			var ox:Float = (slab.hx + Sim.GIRTH) - Math.abs(dx);
			var oy:Float = (slab.hy + Sim.GIRTH) - Math.abs(dy);

			if (ox <= 0 || oy <= 0) {
				continue;
			}

			if (ox <= oy) {
				x += dx < 0 ? -ox : ox;
				vx = 0;
			} else {
				y += dy < 0 ? -oy : oy;
				vy = 0;
			}
		}

		/** Stopped at the wall rather than pressed into it, so nothing builds up against one. */
		var edge:Float = Sim.ROOM - 0.4;

		if (x < -edge) {
			x = -edge;
			vx = 0;
		} else if (x > edge) {
			x = edge;
			vx = 0;
		}

		if (y < -edge) {
			y = -edge;
			vy = 0;
		} else if (y > edge) {
			y = edge;
			vy = 0;
		}

		wishX = 0;
		wishY = 0;
		steering = false;
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
		settle(dt);

		/** Eased rather than snapped, so ducking is a movement and not a cut. */
		var wants:Float = crouching ? 1 : 0;
		stance += (wants - stance) * Math.min(1, dt * 11);

		move(dt);

		var under:Float = support();

		if (onGround) {
			/** Walked off the edge of something: fall from here rather than snapping to the floor. */
			if (z > under + eye() + 0.05) {
				onGround = false;
			} else {
				z = under + eye();
				return;
			}
		}

		vz -= Sim.GRAVITY * dt;
		z += vz * dt;

		if (z <= under + eye()) {
			z = under + eye();
			vz = 0;
			onGround = true;
		}
	}

	/**
	 * @return How high the ground is beneath the player: a roof if they are over one, the floor if
	 *         not.
	 *
	 * Only roofs at or below the feet count, plus the step allowance. A building the player is
	 * standing beside is not something they are standing on, however tall it is, and treating it as
	 * such would teleport them onto anything they walked up to.
	 */
	public function support():Float {
		var best:Float = 0;
		var feet:Float = z - eye();

		for (slab in blocks) {
			if (!slab.over(x, y, Sim.GIRTH)) {
				continue;
			}

			var roof:Float = slab.top();

			if (roof <= feet + STEP && roof > best) {
				best = roof;
			}
		}

		return best;
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


/**
 * A building: a box that never moves, and everything else has to deal with it.
 *
 * Separate from `Body` on purpose. A body falls, sleeps, is pushed and can be broken, and none of
 * that applies to a wall; giving one infinite mass and hoping would leave every rule in `Body`
 * carrying a special case for the thing it can never move.
 */
class Slab {
	public var x:Float;
	public var y:Float;
	public var z:Float;

	public var hx:Float;
	public var hy:Float;
	public var hz:Float;

	public var tint:Int = 0x4A5164;

	var box:h3d.col.Bounds;

	public function new(x:Float, y:Float, z:Float, hx:Float, hy:Float, hz:Float) {
		this.x = x;
		this.y = y;
		this.z = z;
		this.hx = hx;
		this.hy = hy;
		this.hz = hz;

		box = new h3d.col.Bounds();
	}

	/** @return How high its roof is. */
	public inline function top():Float {
		return z + hz;
	}

	/** @return Where it is, as a box, brought up to date. */
	public function bounds():h3d.col.Bounds {
		box.xMin = x - hx;
		box.yMin = y - hy;
		box.zMin = z - hz;
		box.xMax = x + hx;
		box.yMax = y + hy;
		box.zMax = z + hz;

		return box;
	}

	/**
	 * @param at A point.
	 * @param pad How much room to leave around the building.
	 * @return Whether the point is inside it, seen from above.
	 */
	public inline function over(px:Float, py:Float, pad:Float):Bool {
		return Math.abs(px - x) < hx + pad && Math.abs(py - y) < hy + pad;
	}

	/**
	 * Puts a body back out of this building, along whichever face it is least far through.
	 *
	 * @param body The body to move.
	 */
	public function push(body:Body):Void {
		var dx:Float = body.x - x;
		var dy:Float = body.y - y;
		var dz:Float = body.z - z;

		var ox:Float = (hx + body.half) - Math.abs(dx);
		var oy:Float = (hy + body.half) - Math.abs(dy);
		var oz:Float = (hz + body.half) - Math.abs(dz);

		if (ox <= 0 || oy <= 0 || oz <= 0) {
			return;
		}

		if (oz <= ox && oz <= oy) {
			body.z += dz < 0 ? -oz : oz;

			/** Landing on a roof is landing: it keeps the floor's rules, including going to sleep. */
			if (dz > 0) {
				body.vz = body.vz < 0 ? -body.vz * Sim.BOUNCE : body.vz;

				var kept:Float = 1 - Sim.FRICTION;
				body.vx *= kept;
				body.vy *= kept;

				if (Math.abs(body.vz) < Sim.SLEEP && Math.abs(body.vx) < Sim.SLEEP && Math.abs(body.vy) < Sim.SLEEP) {
					body.vx = 0;
					body.vy = 0;
					body.vz = 0;
					body.asleep = true;
				}
			} else {
				body.vz = -Math.abs(body.vz) * Sim.BOUNCE;
			}
		} else if (ox <= oy) {
			body.x += dx < 0 ? -ox : ox;
			body.vx = -body.vx * Sim.BOUNCE;
		} else {
			body.y += dy < 0 ? -oy : oy;
			body.vy = -body.vy * Sim.BOUNCE;
		}
	}
}
