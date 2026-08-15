package world;

import h3d.col.Bounds;

import world.Body;
import world.Sim;

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
