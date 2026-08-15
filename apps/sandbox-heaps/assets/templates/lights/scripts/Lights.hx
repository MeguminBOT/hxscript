import h3d.Vector;
import h3d.prim.Cube;
import h3d.prim.Sphere;
import h3d.scene.Mesh;
import h3d.scene.Object;
import h3d.scene.fwd.DirLight;
import h3d.scene.fwd.PointLight;
import hxd.Key;

/**
 * The light types, side by side, with switches.
 *
 * After the `Lights` sample that ships with Heaps, rewritten for this app's lifecycle rather than
 * copied. Heaps is MIT licensed, (c) 2013 Nicolas Cannasse.
 *
 * **Two deliberate differences from the sample, and both are about the app rather than the API.**
 *
 * The sample runs PBR and this runs forward. A renderer belongs to the engine, not to a project, and
 * this app is already drawing its own interface through the one it has; a project that swapped it
 * would be changing how the window around it is drawn. So the lights here are `h3d.scene.fwd`, the
 * materials are plain colours, and what the sample says about light types still holds.
 *
 * The sample has a spot light and this does not, because forward rendering in this version of heaps
 * has a directional light and a point light and nothing else. That is a real limit rather than a
 * simplification, and it is the clearest reason a project picks PBR.
 *
 * Press **1**, **2** and **3** to switch each light off and on. Turning them off one at a time is
 * the fastest way to learn which one is doing the work.
 */
class Lights extends host.Project {
	static inline var BLOCKS:Int = 50;
	static inline var BALLS:Int = 20;

	var sun:DirLight;
	var lamps:Array<PointLight> = [];
	var orbits:Array<Orbit> = [];
	var elapsed:Float = 0;

	public function new() {
		super();
		title = 'Lights';
	}

	/** Called once, when the project starts. */
	override public function start():Void {
		var scene:h3d.scene.Scene = world();

		/** Null where nothing turned a 3D scene on, which is any run without a window. */
		if (scene == null) {
			return;
		}

		var slab:Cube = new Cube(30, 30, 0.5, true);
		slab.unindex();
		slab.addNormals();

		var ground:Mesh = new Mesh(slab, scene);
		ground.z = -0.25;
		ground.material.color.setColor(0x2B2F3A);

		var box:Cube = new Cube(1, 1, 1, true);
		box.unindex();
		box.addNormals();

		/**
		 * One primitive, fifty meshes, and every difference between them is a transform or a
		 * material. Sharing the geometry is what keeps this at one upload rather than fifty; scaling
		 * per mesh is what stops it looking like fifty copies of one box.
		 */
		for (i in 0...BLOCKS) {
			var block:Mesh = new Mesh(box, scene);
			var tall:Float = 0.35 + Math.random() * Math.random() * 3.4;

			var wide:Float = 0.3 + Math.random() * 1.2;
			var deep:Float = 0.3 + Math.random() * 1.2;

			/**
			 * Turned about z, and a few of them tipped as well.
			 *
			 * Yaw is free: a box spun about the axis it stands on still stands on it, so every one of
			 * them can have a different facing and none of them leaves the floor. Without it fifty
			 * boxes share four wall directions and the field reads as a grid however randomly it was
			 * placed, which is the giveaway that a scene was generated rather than built.
			 *
			 * Tipping is not free, because a box tipped about its centre puts a corner through the
			 * floor. So it goes to a minority, stays small, and is paid for by lifting the box by
			 * roughly what the corner drops: half the footprint times the angle, which is near enough
			 * at angles this size.
			 */
			var turn:Float = Math.random() * Math.PI * 2;
			var tips:Bool = Math.random() < 0.22;
			var tilt:Float = tips ? (Math.random() - 0.5) * 0.5 : 0;
			var roll:Float = tips ? (Math.random() - 0.5) * 0.5 : 0;

			block.x = (Math.random() - 0.5) * 24;
			block.y = (Math.random() - 0.5) * 24;
			block.z = tall * 0.5 + (Math.abs(tilt) * deep + Math.abs(roll) * wide) * 0.5;

			block.scaleX = wide;
			block.scaleY = deep;
			block.scaleZ = tall;
			block.setRotation(tilt, roll, turn);

			block.material.color.setColor(tint(Math.random()));
		}

		var ball:Sphere = new Sphere(0.55, 12, 10);
		ball.addNormals();

		for (i in 0...BALLS) {
			orbits.push(new Orbit(scene, ball, i));
		}

		/**
		 * **Raking rather than overhead.** A direction with most of its length in z lights the tops
		 * of things and leaves every upright face on ambient alone, which is what makes a scene look
		 * unlit even though a light is plainly on. Most of this one is sideways, so the faces you are
		 * looking at are the faces it reaches.
		 */
		sun = new DirLight(new Vector(-0.75, -0.5, -0.44), scene);
		sun.color.setColor(0xB9C2D6);
		sun.enableSpecular = true;

		var marker:Sphere = new Sphere(0.35, 12, 10);
		marker.addNormals();

		for (i in 0...2) {
			var glow:Int = [0xFF8A4A, 0x54A8FF][i];

			var lamp:PointLight = new PointLight(scene);
			lamp.color.setColor(glow);

			/**
			 * `params` is `(constant, linear, quadratic)` and the shader divides by
			 * `x + y*d + z*d*d`, so `x` decides the brightness at the source and `z` decides how far
			 * it carries. Below one, `x` multiplies: `0.3` is three and a third times as bright as the
			 * colour asked for, which is how a light ends up with one white face next to it and
			 * nothing beyond. One leaves the colour alone, and `9 / range^2` puts it at a tenth of
			 * that by `range`, which for a floor thirty across is about twelve.
			 */
			lamp.params.set(1, 0, 9 / (12 * 12));

			/** A ball riding inside each one, unlit, so a point light has a visible position. */
			var bulb:Mesh = new Mesh(marker, lamp);
			bulb.material.color.setColor(glow);
			bulb.material.mainPass.enableLights = false;

			lamps.push(lamp);
		}

		/**
		 * Enough that a face turned away is a colour rather than a silhouette. Every scene needs
		 * some: a real one would bounce light off the floor, and ambient is the cheap stand-in.
		 */
		scene.lightSystem.ambientLight.set(0.26, 0.27, 0.32);

		scene.camera.fovY = 45;
		scene.camera.pos.set(0, -30, 17);
		scene.camera.target.set(0, 0, 1.5);
	}

	/**
	 * Called every frame by the host.
	 *
	 * @param dt Seconds since the previous frame.
	 */
	override public function update(dt:Float):Void {
		elapsed += dt;

		if (Key.isPressed(Key.NUMBER_1)) {
			sun.visible = !sun.visible;
		}
		if (Key.isPressed(Key.NUMBER_2)) {
			lamps[0].visible = !lamps[0].visible;
		}
		if (Key.isPressed(Key.NUMBER_3)) {
			lamps[1].visible = !lamps[1].visible;
		}

		for (orbit in orbits) {
			orbit.step(elapsed);
		}

		/**
		 * The two lamps cross the scene in opposite directions. A point light standing still is hard
		 * to tell from a coloured patch of floor; one that moves drags its falloff over everything it
		 * passes, and that is the whole difference from the directional light above.
		 */
		lamps[0].setPosition(Math.cos(elapsed * 0.5) * 9, Math.sin(elapsed * 0.5) * 9, 3.2);
		lamps[1].setPosition(Math.cos(-elapsed * 0.35 + 2) * 7, Math.sin(-elapsed * 0.35 + 2) * 7, 4.4);
	}

	/**
	 * A colour with its brightness chosen rather than left to chance.
	 *
	 * `Math.random() * 0xFFFFFF` is a random number, not a random colour: each channel is independent,
	 * so most of what comes out is dark, muddy, or both, and a scene built from it reads as grey no
	 * matter how well it is lit. Picking a hue and keeping saturation and value fixed gives colours
	 * that differ from each other in the way a person means by "different colours".
	 *
	 * @param at Where on the wheel, from 0 to 1.
	 * @return A packed RGB colour.
	 */
	public static function tint(at:Float):Int {
		var h:Float = (at * 6) % 6;
		var f:Float = h - Std.int(h);

		var v:Float = 0.92;
		var p:Float = v * (1 - 0.62);
		var q:Float = v * (1 - 0.62 * f);
		var t:Float = v * (1 - 0.62 * (1 - f));

		var r:Float;
		var g:Float;
		var b:Float;

		switch (Std.int(h)) {
			case 0: r = v; g = t; b = p;
			case 1: r = q; g = v; b = p;
			case 2: r = p; g = v; b = t;
			case 3: r = p; g = q; b = v;
			case 4: r = t; g = p; b = v;
			case _: r = v; g = p; b = q;
		}

		return (Std.int(r * 255) << 16) | (Std.int(g * 255) << 8) | Std.int(b * 255);
	}
}

/** One sphere going round a point of its own, so the floor has something moving on it. */
class Orbit {
	var body:Mesh;
	var about:Vector;
	var reach:Float;
	var phase:Float;
	var rate:Float;
	var lift:Float;

	/**
	 * @param into The scene.
	 * @param prim The shared sphere.
	 * @param seed Which one it is, which decides where it goes round and how fast.
	 */
	public function new(into:Object, prim:h3d.prim.Primitive, seed:Int) {
		/**
		 * Its own size and its own colour, off one shared sphere. They were all one size and all
		 * white, which reads as a row of markers rather than as a scene: the eye takes twenty
		 * identical things as one repeated thing however far apart they are.
		 */
		var size:Float = 0.4 + Math.random() * Math.random() * 1.9;

		body = new Mesh(prim, into);
		body.scale(size);
		body.material.color.setColor(Lights.tint(Math.random()));

		about = new Vector((Math.random() - 0.5) * 20, (Math.random() - 0.5) * 20, size);
		reach = 1.2 + Math.random() * 3.2;
		phase = Math.random() * Math.PI * 2;
		rate = 0.5 + Math.random() * 1.4;
		lift = size;
	}

	/** @param elapsed Seconds since the run began. */
	public function step(elapsed:Float):Void {
		var at:Float = elapsed * rate + phase;

		body.x = about.x + Math.cos(at) * reach;
		body.y = about.y + Math.sin(at) * reach;
		body.z = about.z + Math.abs(Math.sin(at * 2)) * lift * 0.8;
	}
}
