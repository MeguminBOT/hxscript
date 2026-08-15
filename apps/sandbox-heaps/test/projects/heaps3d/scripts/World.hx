import h3d.Vector;
import h3d.mat.Material;
import h3d.prim.Cube;
import h3d.prim.Cylinder;
import h3d.prim.Sphere;
import h3d.scene.Mesh;
import h3d.scene.Object;
import h3d.scene.fwd.DirLight;
import h3d.scene.fwd.PointLight;
import hxd.Key;

/**
 * A heaps 3D project, built into the scene rather than being part of it.
 *
 * **Which of the two a project is, is a choice rather than a limit.** `h3d.scene.Object` is bridged,
 * so a script may extend it and be in the graph; `SelfTest` has three that do. This one is written
 * the other way because most 3D projects are: what a project owns is a world of its own objects, and
 * being one of them buys it nothing.
 *
 * So `world()` hands over the scene, everything below is heaps' own class, and what is added is
 * drawn because it is in the graph. The launcher empties the scene when the run ends, so nothing
 * here has to clean up after itself.
 */
class World extends host.Project {
	static inline var RING:Int = 12;

	/** How far out the scene reaches from the middle: the floor's half-width, which is the widest of it. */
	static inline var REACH:Float = 8;

	/** The lens, in degrees. Wider than heaps' own 25, which is narrow enough to read as a zoom. */
	static inline var FOV:Float = 45;

	var spinners:Array<Spinner> = [];
	var pivot:Object;
	var elapsed:Float = 0;
	var paused:Bool = false;

	var root:Object;

	public function new() {
		super();
	}

	/** Called once, when the project starts. */
	override public function start():Void {
		root = new Object(world());
		pivot = new Object(root);

		for (i in 0...RING) {
			var at:Float = (i / RING) * Math.PI * 2;
			spinners.push(new Spinner(pivot, i, Math.cos(at) * 6, Math.sin(at) * 6));
		}

		var floor:Mesh = new Mesh(lit(new Cube(14, 14, 0.4, true), true), root);
		floor.z = -2;
		floor.material.color.setColor(0x1E1E28);

		var sun:DirLight = new DirLight(new Vector(-0.4, -0.6, -0.7), root);
		sun.color.setColor(0xFFF3D6);

		var lamp:PointLight = new PointLight(root);
		lamp.color.setColor(0x4466FF);
		lamp.setPosition(0, 0, 5);

		frame();
	}

	/**
	 * Points the camera at what this built.
	 *
	 * **A 3D project has to do this and a 2D one never does**, which is the easiest thing to leave
	 * out. `h3d.Camera` starts at `(2, 3, 4)` looking at the origin through a 25 degree lens, and
	 * this scene is fourteen units across with a ring of shapes orbiting at six, so the default
	 * leaves the camera standing inside that ring: something renders, and none of it is what you
	 * meant to look at.
	 *
	 * The distance is worked out rather than guessed. Half of what has to fit is `REACH`, and a lens
	 * of `fovY` degrees covers that at `REACH / tan(fovY / 2)`, so widening the lens and moving in
	 * are the same decision made twice. Heaps is z-up, so the camera is pulled back along -y and
	 * lifted along +z rather than the other way round.
	 */
	function frame():Void {
		var scene:h3d.scene.Scene = world();

		/**
		 * `world()` answers null where nothing turned a 3D scene on, which is any run without a
		 * window. The objects above are fine without one, since an object with no parent is still an
		 * object, and a camera is not: there is nothing to point.
		 */
		if (scene == null) {
			return;
		}

		var view:h3d.Camera = scene.camera;
		var away:Float = REACH / Math.tan((FOV * 0.5) * Math.PI / 180);

		view.fovY = FOV;
		view.pos.set(0, -away * 0.85, away * 0.5);
		view.target.set(0, 0, 0);
	}

	/**
	 * Called every frame by the host.
	 *
	 * @param dt Seconds since the previous frame.
	 */
	override public function update(dt:Float):Void {
		step(dt);
	}

	/**
	 * One frame, so a test can drive it without a window.
	 *
	 * @param dt Seconds since the previous frame.
	 */
	public function step(dt:Float):Void {
		elapsed += dt;

		if (Key.isPressed(Key.SPACE)) {
			paused = !paused;
		}

		if (paused) {
			return;
		}

		pivot.setRotation(0, 0, elapsed * 0.4);

		for (spinner in spinners) {
			spinner.step(dt, elapsed);
		}
	}

	/** @return How many objects this put in the scene, both levels of it, for the self test. */
	public function pieces():Int {
		return root == null ? 0 : root.numChildren + pivot.numChildren;
	}

	/**
	 * A primitive carrying the normals a lit material needs.
	 *
	 * **heaps builds `Cube` and `Sphere` out of positions and indices and nothing else.** A material
	 * with a light on it wants a normal per vertex, so a mesh made straight from either constructor
	 * draws nothing and ends the frame with `Missing buffer input 'normal'`. `Sphere` looks like it
	 * handles this and does not: it overrides `addNormals`, but only its static `defaultUnitSphere`
	 * ever calls it. `Cylinder` hands its own normals up to `Quads` and needs none of this.
	 *
	 * `flat` unindexes first, which is what a cube wants. A normal belongs to a face there rather
	 * than to a corner, and an indexed cube shares each corner between three faces, so normals
	 * averaged across them light it as though it were round.
	 *
	 * @param prim The primitive to prepare.
	 * @param flat Whether its faces should be lit flat rather than smoothed across shared corners.
	 * @return The same primitive, ready to draw.
	 */
	public static function lit(prim:h3d.prim.Polygon, flat:Bool = false):h3d.prim.Polygon {
		if (flat) {
			prim.unindex();
		}

		prim.addNormals();
		return prim;
	}
}

/** One shape orbiting the middle, as its own scripted class. */
class Spinner {
	var body:Mesh;
	var lift:Float;
	var phase:Float;

	public function new(into:Object, seed:Int, x:Float, y:Float) {
		body = new Mesh(shapeFor(seed), into);
		body.x = x;
		body.y = y;
		body.material.color.setColor(colourOf(seed));

		lift = 1 + (seed % 3) * 0.6;
		phase = seed * 0.5;
	}

	/**
	 * Moves it.
	 *
	 * @param dt Seconds since the previous frame.
	 * @param elapsed Seconds since the run began.
	 */
	public function step(dt:Float, elapsed:Float):Void {
		body.z = Math.sin(elapsed * 1.5 + phase) * lift;
		body.setRotation(elapsed * 0.9, phase, elapsed * 0.6);
	}

	/** @return Where it is, which is what a test can compare. */
	public function height():Float {
		return body.z;
	}

	/**
	 * @param seed Which one it is.
	 * @return A primitive, so all three kinds are built, each lit the way its shape wants: the cube
	 *         flat, the sphere smoothed, and the cylinder left alone because it brings its own.
	 */
	static function shapeFor(seed:Int):h3d.prim.Primitive {
		return switch (seed % 3) {
			case 0: World.lit(new Cube(1.4, 1.4, 1.4, true), true);
			case 1: World.lit(new Sphere(0.9, 12, 10));
			case _: new Cylinder(10, 0.7, 1.6);
		}
	}

	static function colourOf(seed:Int):Int {
		return switch (seed % 3) {
			case 0: 0xF05C7C;
			case 1: 0x8A5EE0;
			case _: 0xFFCA6E;
		}
	}
}
