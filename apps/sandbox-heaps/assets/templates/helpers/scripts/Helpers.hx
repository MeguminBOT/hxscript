import h3d.Vector;
import h3d.prim.Cube;
import h3d.prim.Sphere;
import h3d.scene.Graphics;
import h3d.scene.Mesh;
import h3d.scene.Object;
import h3d.scene.fwd.DirLight;
import h3d.scene.fwd.PointLight;

/**
 * The lines you draw to see what you are doing.
 *
 * After the `Helpers` sample that ships with Heaps, rewritten for this app's lifecycle rather than
 * copied. Heaps is MIT licensed, (c) 2013 Nicolas Cannasse.
 *
 * **`h3d.scene.Graphics` is an immediate-mode line and triangle drawer in the scene graph**, and it
 * is what axes, grids, bounding boxes and normals are drawn with while a scene is being built. It
 * is not a debug overlay: it is an ordinary object, so it transforms, sorts and hides with
 * everything else, and turning it off is `visible = false` rather than a build flag.
 *
 * Its lighting is switched off here on purpose. A line has no meaningful normal, so a lit line
 * takes whatever shading the geometry around it happens to produce, which is what makes hand-drawn
 * helpers look wrong for reasons that are hard to find.
 */
class Helpers extends host.Project {
	static inline var GRID:Int = 12;
	static inline var STEP:Float = 1;

	var block:Mesh;
	var lamps:Array<PointLight> = [];
	var elapsed:Float = 0;

	public function new() {
		super();
		title = 'Helpers';
	}

	/** Called once, when the project starts. */
	override public function start():Void {
		var scene:h3d.scene.Scene = world();

		/** Null where nothing turned a 3D scene on, which is any run without a window. */
		if (scene == null) {
			return;
		}

		floor(scene);
		axes(scene);

		var prim:Cube = new Cube(1.6, 1.6, 1.6, true);
		prim.unindex();
		prim.addNormals();

		block = new Mesh(prim, scene);
		block.z = 1.6;
		block.material.color.setColor(0xBFC6D4);

		var marker:Sphere = new Sphere(0.13, 8, 6);
		marker.addNormals();

		for (i in 0...3) {
			var lamp:PointLight = new PointLight(scene);
			lamp.color.setColor([0xFF4D5E, 0x4DFF87, 0x4D8BFF][i]);
			lamp.params.set(0.5, 0, 1.1);

			var bulb:Mesh = new Mesh(marker, lamp);
			bulb.material.color.setColor([0xFF4D5E, 0x4DFF87, 0x4D8BFF][i]);
			bulb.material.mainPass.enableLights = false;

			lamps.push(lamp);
		}

		var sun:DirLight = new DirLight(new Vector(-0.4, -0.4, -0.8), scene);
		sun.color.setColor(0x2A2A33);

		scene.lightSystem.ambientLight.set(0.08, 0.08, 0.1);

		scene.camera.fovY = 45;
		scene.camera.pos.set(9, -11, 7);
		scene.camera.target.set(0, 0, 1.2);
	}

	/**
	 * A grid on the ground plane, drawn as lines rather than built as geometry.
	 *
	 * @param into The scene.
	 */
	function floor(into:Object):Void {
		var lines:Graphics = new Graphics(into);
		lines.material.mainPass.enableLights = false;

		var reach:Float = GRID * STEP * 0.5;

		for (i in 0...GRID + 1) {
			var at:Float = -reach + i * STEP;
			var edge:Bool = (i == 0 || i == GRID);

			lines.lineStyle(1, edge ? 0x6A7183 : 0x343A47);

			lines.moveTo(-reach, at, 0);
			lines.lineTo(reach, at, 0);
			lines.moveTo(at, -reach, 0);
			lines.lineTo(at, reach, 0);
		}

		lines.lineStyle();
	}

	/**
	 * The three axes at the origin, each in its own colour, which is how a scene tells you which
	 * way it is facing. Heaps is z-up, so the blue one points at the sky.
	 *
	 * @param into The scene.
	 */
	function axes(into:Object):Void {
		var marks:Graphics = new Graphics(into);
		marks.material.mainPass.enableLights = false;

		marks.lineStyle(2, 0xFF4444);
		marks.moveTo(0, 0, 0);
		marks.lineTo(3, 0, 0);

		marks.lineStyle(2, 0x44FF44);
		marks.moveTo(0, 0, 0);
		marks.lineTo(0, 3, 0);

		marks.lineStyle(2, 0x4488FF);
		marks.moveTo(0, 0, 0);
		marks.lineTo(0, 0, 3);

		marks.lineStyle();
	}

	/**
	 * Called every frame by the host.
	 *
	 * @param dt Seconds since the previous frame.
	 */
	override public function update(dt:Float):Void {
		elapsed += dt;

		block.setRotation(elapsed * 0.3, elapsed * 0.5, elapsed * 0.2);

		/** One light per axis, so each shows the direction its axis points. */
		lamps[0].setPosition(Math.sin(elapsed) * 4, 0, 1.6);
		lamps[1].setPosition(0, Math.sin(elapsed * 1.3) * 4, 1.6);
		lamps[2].setPosition(0, 0, 1.6 + Math.sin(elapsed * 0.8) * 2.4);
	}
}
