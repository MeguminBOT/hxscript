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
 * **A 2D project becomes an `h2d.Object`; a 3D one cannot become an `h3d.scene.Object`, and the
 * reason is worth knowing.** Extending a compiled class goes through a generated bridge, and a
 * bridge re-emits the constructor it extends. `h3d.scene.Object` inlines an abstract's constructor,
 * which assigns to `this`, and that has no meaning anywhere but inside the abstract. So the library
 * refuses to bridge it rather than generating something that would not compile.
 *
 * Nothing else is lost. `world()` hands over the scene, everything below is heaps' own class, and
 * what is added is drawn because it is in the graph. The launcher empties the scene when the run
 * ends, so nothing here has to clean up after itself.
 */
class World extends host.Project {
	static inline var RING:Int = 12;

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

		var floor:Mesh = new Mesh(new Cube(14, 14, 0.4, true), root);
		floor.z = -2;
		floor.material.color.setColor(0x1E1E28);

		var sun:DirLight = new DirLight(new Vector(-0.4, -0.6, -0.7), root);
		sun.color.setColor(0xFFF3D6);

		var lamp:PointLight = new PointLight(root);
		lamp.color.setColor(0x4466FF);
		lamp.setPosition(0, 0, 5);
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

	/** @return How many objects this put in the scene, for the self test. */
	public function pieces():Int {
		return root == null ? 0 : root.numChildren;
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

	/** @param seed Which one it is. @return A primitive, so all three kinds are built. */
	static function shapeFor(seed:Int):h3d.prim.Primitive {
		return switch (seed % 3) {
			case 0: new Cube(1.4, 1.4, 1.4, true);
			case 1: new Sphere(0.9, 12, 10);
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
