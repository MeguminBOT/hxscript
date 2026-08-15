import h3d.Vector;
import h3d.prim.Cube;
import h3d.prim.Sphere;
import h3d.scene.Mesh;
import h3d.scene.fwd.DirLight;

/**
 * A moving light, and the shadows it drags across the floor.
 *
 * After the `Shadows` sample that ships with Heaps, rewritten for this app's lifecycle rather than
 * copied. Heaps is MIT licensed, (c) 2013 Nicolas Cannasse.
 *
 * **The shadow map belongs to the renderer, not to the light**, which is the thing that is hard to
 * guess: there is one map, the forward renderer owns it, and it follows whichever directional light
 * the scene has. So the settings are reached through `scene.renderer.shadow` and there is nothing to
 * switch on per light.
 *
 * `power`, `bias` and the blur are the three that decide whether this looks like shadows or like
 * artefacts. `bias` is the one to reach for first: too little and a surface shadows itself in
 * stripes, too much and every shadow floats away from the thing casting it.
 */
class Shadows extends host.Project {
	static inline var BALLS:Int = 15;

	var sun:DirLight;
	var elapsed:Float = 0;

	public function new() {
		super();
		title = 'Shadows';
	}

	/** Called once, when the project starts. */
	override public function start():Void {
		var scene:h3d.scene.Scene = world();

		/** Null where nothing turned a 3D scene on, which is any run without a window. */
		if (scene == null) {
			return;
		}

		var slab:Cube = new Cube(26, 26, 0.5, true);
		slab.unindex();
		slab.addNormals();

		var ground:Mesh = new Mesh(slab, scene);
		ground.z = -0.25;
		ground.material.color.setColor(0x3A3F4B);
		ground.material.shadows = true;

		var ball:Sphere = new Sphere(1, 16, 12);
		ball.addNormals();

		for (i in 0...BALLS) {
			var body:Mesh = new Mesh(ball, scene);
			var size:Float = 0.6 + Math.random() * 1.3;

			body.x = (Math.random() - 0.5) * 18;
			body.y = (Math.random() - 0.5) * 18;
			body.z = size;
			body.scale(size);
			body.material.color.setColor(Std.int(Math.random() * 0xFFFFFF));
			body.material.shadows = true;
		}

		sun = new DirLight(new Vector(0, -1, -1), scene);
		sun.color.setColor(0xFFF0D8);

		scene.lightSystem.ambientLight.set(0.28, 0.29, 0.36);

		var map:h3d.pass.DefaultShadowMap = scene.renderer.shadow;
		map.power = 40;
		map.bias = 0.02;
		map.blur.radius = 1;

		scene.camera.fovY = 45;
		scene.camera.pos.set(0, -26, 16);
		scene.camera.target.set(0, 0, 1);
	}

	/**
	 * Called every frame by the host.
	 *
	 * @param dt Seconds since the previous frame.
	 */
	override public function update(dt:Float):Void {
		elapsed += dt;

		/** Low on the horizon, so the shadows are long enough to read as it goes round. */
		sun.setDirection(new Vector(Math.cos(elapsed * 0.35), Math.sin(elapsed * 0.35), -0.55));
	}
}
