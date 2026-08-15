package world;

import h3d.col.Ray;

import world.Body;
import world.Player;
import world.Slab;

/**
 * The room, what is in it, and what happens to it. No scene graph anywhere in this package.
 *
 * **Split out from the drawing on purpose, and it is the most useful thing about this example.**
 * Everything in `world` is arithmetic over time: where a shot lands, where a crate slides to,
 * whether a piece has settled. None of it needs a window, so `SelfTest` drives all of it headlessly
 * and the conformance pass compares interpreted against compiled on real gameplay rather than on a
 * list of expressions. A game whose simulation can only run inside a frame is a game whose physics
 * can only be tested by looking at it.
 *
 * A sibling of the same package still has to be imported. Haxe resolves one without, and hxScript
 * does not, so a missing line here reads as the type not existing at all.
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
				if (piece.source == body) {
					piece.alive = false;
					piece.source = null;
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
			piece.source = body;

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
