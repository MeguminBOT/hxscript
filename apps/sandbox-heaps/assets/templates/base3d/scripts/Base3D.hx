import h3d.Vector;
import h3d.mat.Texture;
import h3d.prim.Cube;
import h3d.scene.Mesh;
import h3d.scene.Object;
import h3d.scene.fwd.DirLight;

/**
 * The 3D starting point: a textured cube, a light, and a camera going round it.
 *
 * After the `Base3D` sample that ships with Heaps, rewritten for this app's lifecycle rather than
 * copied. Heaps is MIT licensed, (c) 2013 Nicolas Cannasse.
 *
 * **Three lines of it are the whole lesson**, and they are the three a first 3D project leaves out:
 *
 * - `unindex`, because a cube's corners are shared between three faces and a face wants its own
 * - `addNormals`, because without them a lit material has no buffer to read and draws nothing
 * - `addUVs`, because without them a texture has no coordinates and the image never lands
 *
 * Leaving any of them out fails at the first frame rather than at the line that caused it, which is
 * why they are here together with the reason written down.
 */
class Base3D extends host.Project {
	var spin:Mesh;
	var elapsed:Float = 0;

	public function new() {
		super();
		title = 'Base 3D';
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
		prim.addUVs();

		/**
		 * The logo the Heaps sample draws on this cube, when it is there.
		 *
		 * It is not shipped here. The Haxe logo is the Haxe Foundation's mark, and the app's own
		 * images are written by `setup/make-assets.py`, which is a script that computes pixels: using
		 * it to reproduce somebody's logo would be copying artwork rather than generating any. Heaps
		 * carries its own copy under `samples/res`.
		 *
		 * Put a `logo.png` in the app's `assets/res/` folder and this uses it. Without one the cube
		 * wears the panel texture instead, and everything the sample is about, a texture reaching a
		 * material through UVs, is the same either way.
		 */
		var named:String = hxd.Res.loader.exists('logo.png') ? 'logo.png' : 'panel.png';
		var skin:Texture = hxd.Res.load(named).toTexture();

		var block:Mesh = new Mesh(prim, scene);
		block.material.texture = skin;

		/**
		 * The second cube shares the primitive and not the material. A primitive is geometry and
		 * costs memory, so sharing one is free; a material is how it is shaded, and two objects that
		 * want different colours need two of them.
		 */
		spin = new Mesh(prim, scene);
		spin.scale(0.6);
		spin.z = 1.1;
		spin.material.color.setColor(0xE08A3C);

		var sun:DirLight = new DirLight(new Vector(-0.3, -0.5, -0.8), scene);
		sun.color.setColor(0xFFF1D0);

		scene.lightSystem.ambientLight.set(0.35, 0.35, 0.42);

		scene.camera.fovY = 40;
		scene.camera.target.set(0, 0, 0.4);
	}

	/**
	 * Called every frame by the host.
	 *
	 * @param dt Seconds since the previous frame.
	 */
	override public function update(dt:Float):Void {
		elapsed += dt;

		var scene:h3d.scene.Scene = world();
		scene.camera.pos.set(Math.cos(elapsed * 0.5) * 4.5, Math.sin(elapsed * 0.5) * 4.5, 2.4);

		spin.setRotation(elapsed * 0.8, elapsed * 0.4, 0);
	}
}
