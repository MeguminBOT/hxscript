package view;

import h3d.scene.Mesh;
import h3d.scene.Object;

/**
 * One shot, drawn as a streak that leaves the muzzle and arrives where the shot landed.
 *
 * A stretched box rather than a line, because a line has no thickness at distance and a shot that
 * cannot be seen might as well not be drawn. It carries no decision: the hit was settled the moment
 * the trigger went, and this is the part a player watches.
 */
class Tracer {
	/** How fast a streak travels, in units per second. */
	static inline var SPEED:Float = 90;

	/** How long the streak is. */
	static inline var LENGTH:Float = 1.4;

	var body:Mesh;
	var dx:Float;
	var dy:Float;
	var dz:Float;
	var x:Float;
	var y:Float;
	var z:Float;
	var gone:Float = 0;
	var reach:Float;

	/**
	 * From one point to another, rather than from a point along a direction.
	 *
	 * **Both ends are given because the two ends disagree.** The shot was decided from the eye and
	 * is drawn from the muzzle, and a streak that left the muzzle along the eye's direction would
	 * run beside the aim forever instead of meeting it. Handed the place it landed, it leans onto
	 * the line of sight over its flight, which is what a barrel held to one side of an eye does.
	 *
	 * @param into The scene.
	 * @param prim The shared cube.
	 * @param mx Where it starts, at the muzzle.
	 * @param my Where it starts.
	 * @param mz Where it starts.
	 * @param tx Where it ends, where the shot landed.
	 * @param ty Where it ends.
	 * @param tz Where it ends.
	 */
	public function new(into:Object, prim:h3d.prim.Primitive, mx:Float, my:Float, mz:Float, tx:Float, ty:Float,
			tz:Float) {
		/** From the muzzle, which is where a player watching expects a shot to come from. */
		x = mx;
		y = my;
		z = mz;

		dx = tx - mx;
		dy = ty - my;
		dz = tz - mz;

		reach = Math.sqrt(dx * dx + dy * dy + dz * dz);

		if (reach < 0.001) {
			reach = 0.001;
		}

		dx /= reach;
		dy /= reach;
		dz /= reach;

		body = new Mesh(prim, into);
		body.scaleX = LENGTH;
		body.scaleY = 0.045;
		body.scaleZ = 0.045;
		body.material.color.setColor(0xFFF0C0);
		body.material.mainPass.enableLights = false;
		body.material.castShadows = false;
		body.material.receiveShadows = false;

		body.setRotation(0, -Math.asin(dz), Math.atan2(dy, dx));
	}

	/**
	 * @param dt Seconds since the previous frame.
	 * @return Whether it is still going.
	 */
	public function step(dt:Float):Bool {
		gone += SPEED * dt;

		if (gone >= reach) {
			return false;
		}

		body.x = x + dx * gone;
		body.y = y + dy * gone;
		body.z = z + dz * gone;

		return true;
	}

	/** Takes it out of the scene. */
	public function drop():Void {
		body.remove();
	}
}
