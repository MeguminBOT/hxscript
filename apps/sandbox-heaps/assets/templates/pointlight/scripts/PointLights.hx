import h3d.Vector;
import h3d.prim.Cube;
import h3d.prim.Sphere;
import h3d.scene.Mesh;
import h3d.scene.Object;
import h3d.scene.fwd.DirLight;
import h3d.scene.fwd.PointLight;

/**
 * Coloured lights moving through plain geometry.
 *
 * After the `PointLights` sample that ships with Heaps, rewritten for this app's lifecycle rather
 * than copied. Heaps is MIT licensed, (c) 2013 Nicolas Cannasse.
 *
 * **Every cube here is the same white cube.** Nothing in the scene is coloured; the colour is
 * entirely the lights, which is the thing worth seeing before deciding a scene needs more models.
 * A small marker sphere rides inside each light so its position is visible rather than inferred.
 *
 * The forward renderer has a budget for how many lights touch one object, and that is the other
 * lesson: past it, the nearest win and the rest stop contributing, which reads as lights blinking
 * out at distance rather than as a bug.
 */
class PointLights extends host.Project {
	static inline var BLOCKS:Int = 90;
	static inline var LAMPS:Int = 7;
	static inline var SPREAD:Float = 9;

	/** How far a lamp carries, which its attenuation is worked out from. */
	static inline var REACH:Float = 8;

	var lamps:Array<Lamp> = [];
	var sun:DirLight;
	var elapsed:Float = 0;

	public function new() {
		super();
		title = 'Point lights';
	}

	/** Called once, when the project starts. */
	override public function start():Void {
		var scene:h3d.scene.Scene = world();

		/** Null where nothing turned a 3D scene on, which is any run without a window. */
		if (scene == null) {
			return;
		}

		var prim:Cube = new Cube(1, 1, 1, true);
		prim.unindex();
		prim.addNormals();

		for (i in 0...BLOCKS) {
			var block:Mesh = new Mesh(prim, scene);

			block.x = (Math.random() - 0.5) * SPREAD * 2;
			block.y = (Math.random() - 0.5) * SPREAD * 2;
			block.z = (Math.random() - 0.5) * 3;
			block.setRotation(Math.random(), Math.random(), Math.random());
			block.scale(0.5 + Math.random() * 0.7);

			/**
			 * **Nothing here casts a shadow, and that is a property of the renderer.** Forward
			 * shadows in heaps are `DefaultShadowMap`, which extends `DirShadowMap`: there is one map
			 * and it belongs to the directional light. A point light cannot cast one at all.
			 *
			 * Left on, the only thing the map does here is darken faces according to a light that is
			 * a dim fill contributing almost nothing, so the scene picks up black patches unrelated
			 * to any of the lights doing the work. Off is both correct and cheaper.
			 */
			block.material.shadows = false;
		}

		var marker:Sphere = new Sphere(0.16, 8, 6);
		marker.addNormals();

		for (i in 0...LAMPS) {
			lamps.push(new Lamp(scene, marker, i));
		}

		sun = new DirLight(new Vector(0, -1, -0.6), scene);
		sun.color.setColor(0x3A4055);

		/** Low on purpose: the point of this one is that the colour comes from the lights. */
		scene.lightSystem.ambientLight.set(0.1, 0.1, 0.13);

		scene.camera.fovY = 50;
		scene.camera.pos.set(0, -22, 11);
		scene.camera.target.set(0, 0, 0);
	}

	/**
	 * Called every frame by the host.
	 *
	 * @param dt Seconds since the previous frame.
	 */
	override public function update(dt:Float):Void {
		elapsed += dt;

		for (lamp in lamps) {
			lamp.step(elapsed);
		}

		/** The fill turns too, so nothing in shadow stays the same shade for long. */
		sun.setDirection(new Vector(Math.cos(elapsed * 0.15), Math.sin(elapsed * 0.15), -0.6));
	}
}

/** One coloured light, and the little sphere that shows where it is. */
class Lamp {
	static var COLOURS:Array<Int> = [0xFF3B6E, 0x36D6FF, 0xFFD447, 0x7CFF5A, 0xB166FF, 0xFF8A3D, 0x49FFC7];

	var light:PointLight;
	var body:Mesh;
	var phase:Float;
	var reach:Float;
	var lift:Float;

	/**
	 * @param into The scene.
	 * @param marker The shared sphere every marker draws.
	 * @param seed Which one it is, which decides its colour and its path.
	 */
	public function new(into:Object, marker:h3d.prim.Primitive, seed:Int) {
		var tint:Int = COLOURS[seed % COLOURS.length];

		light = new PointLight(into);
		light.color.setColor(tint);

		/**
		 * `params` is `(constant, linear, quadratic)`, and the shader divides the colour by
		 * `x + y*d + z*d*d`. A constant below one multiplies rather than dims: `0.4` was two and a
		 * half times the colour asked for at the source, and the quadratic term then buried it within
		 * about three units, so each light was a bright dot lighting almost nothing. One leaves the
		 * colour alone and `9 / reach^2` puts it at a tenth of that by `reach`.
		 */
		var carry:Float = PointLights.REACH;
		light.params.set(1, 0, 9 / (carry * carry));

		body = new Mesh(marker, light);
		body.material.color.setColor(tint);
		body.material.mainPass.enableLights = false;

		phase = (seed / COLOURS.length) * Math.PI * 2;
		reach = 5 + (seed % 3) * 2.2;
		lift = 1.2 + (seed % 4) * 0.7;
	}

	/** @param elapsed Seconds since the run began. */
	public function step(elapsed:Float):Void {
		var at:Float = elapsed * 0.6 + phase;

		light.x = Math.cos(at) * reach;
		light.y = Math.sin(at * 1.3) * reach;
		light.z = Math.sin(at * 0.8) * lift + 1.5;
	}
}
