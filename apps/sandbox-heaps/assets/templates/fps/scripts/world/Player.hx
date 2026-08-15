package world;

import world.Sim;
import world.Slab;

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
