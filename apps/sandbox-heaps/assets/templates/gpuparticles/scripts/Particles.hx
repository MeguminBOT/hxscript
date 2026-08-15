import h3d.Vector;
import h3d.parts.GpuParticles;
import h3d.scene.Box;
import h3d.scene.fwd.DirLight;

/**
 * Ten thousand particles that cost about as much as one object.
 *
 * After the `GpuParticles` sample that ships with Heaps, rewritten for this app's lifecycle rather
 * than copied, and without the slider panel the sample carries. Heaps is MIT licensed,
 * (c) 2013 Nicolas Cannasse.
 *
 * **A group is a description, not a list.** Nothing here holds ten thousand of anything: the group
 * carries the rules, the GPU works out where each particle is from its index and the clock, and
 * `nparts` is a number in that description rather than an allocation. That is why the count can be
 * changed by an order of magnitude and the frame time barely moves, and it is also the constraint:
 * a particle cannot be told anything individually, because there is no object to tell.
 *
 * `bounds` is the other half worth knowing. The system reports the volume its particles occupy, and
 * culling uses it, so a group whose particles travel outside their declared bounds gets cut off at
 * the edge of a volume nothing can see. Drawing the box is how that stops being mysterious.
 */
class Particles extends host.Project {
	var parts:GpuParticles;
	var elapsed:Float = 0;

	public function new() {
		super();
		title = 'GPU particles';
	}

	/** Called once, when the project starts. */
	override public function start():Void {
		var scene:h3d.scene.Scene = world();

		/** Null where nothing turned a 3D scene on, which is any run without a window. */
		if (scene == null) {
			return;
		}

		parts = new GpuParticles(scene);

		var group:GpuPartGroup = parts.addGroup();
		group.nparts = 10000;
		group.emitMode = Cone;
		group.emitAngle = 0.35;
		group.emitDist = 1.2;
		group.emitLoop = true;

		group.life = 2;
		group.lifeRand = 0.4;
		group.speed = 4.5;
		group.speedRand = 0.5;
		group.gravity = -2.6;

		group.size = 0.09;
		group.sizeRand = 0.7;
		group.rotSpeed = 2.4;
		group.rotSpeedRand = 1;

		group.fadeIn = 0.15;
		group.fadeOut = 0.55;
		group.fadePower = 1.4;

		parts.volumeBounds = null;

		/**
		 * The bounds the system reports, drawn as they are rather than as a guess. `Box` takes a
		 * `h3d.col.Bounds` and outlines it, so this updates itself as the group settles.
		 */
		var shell:Box = new Box(0x2E7BFF, parts.bounds, scene);
		shell.material.mainPass.enableLights = false;

		var sun:DirLight = new DirLight(new Vector(-0.4, -0.5, -0.7), scene);
		sun.color.setColor(0xFFFFFF);

		scene.lightSystem.ambientLight.set(0.4, 0.4, 0.45);

		scene.camera.fovY = 45;
		scene.camera.pos.set(0, -14, 5);
		scene.camera.target.set(0, 0, 3);
	}

	/**
	 * Called every frame by the host.
	 *
	 * @param dt Seconds since the previous frame.
	 */
	override public function update(dt:Float):Void {
		elapsed += dt;

		/** The emitter leans as it turns, so the cone sweeps rather than standing still. */
		parts.setRotation(Math.sin(elapsed * 0.4) * 0.4, 0, elapsed * 0.5);
	}
}
