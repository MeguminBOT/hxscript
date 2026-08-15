import h3d.Vector;
import h3d.prim.Cube;
import h3d.scene.Mesh;
import h3d.scene.Object;
import h3d.scene.fwd.DirLight;
import h3d.scene.fwd.PointLight;
import hxd.Key;

/**
 * A room, some targets, and a gun.
 *
 * **This file draws and reads input, and decides nothing.** Where a shot lands, what a crate does
 * about it and where the pieces end up are all `Sim`, which has no scene graph in it and is tested
 * without a window. What is left here is the part that genuinely needs one: geometry, lights, a
 * camera behind the player's eyes, and a mesh per body kept where the body is.
 *
 * Move with **WASD**, look with the **mouse** or the **arrow keys**, jump with **space**, and shoot
 * with the **left mouse button** or **F**. Targets come apart; crates take the hit and slide.
 */
class Shooter extends host.Project {
	static inline var TARGETS:Int = 6;
	static inline var CRATES:Int = 5;

	/** How far the head turns per pixel of pointer movement. */
	static inline var SENSITIVITY:Float = 0.005;

	/** How fast the arrow keys turn, in radians per second, for playing without a pointer. */
	static inline var KEY_TURN:Float = 1.8;

	var sim:Sim;
	var scene:h3d.scene.Scene;

	/** A mesh per body, in the same order, so the two are matched by index. */
	var shapes:Array<Mesh> = [];

	/** How many bodies had a mesh made for them, since breaking adds more. */
	var drawn:Int = 0;

	var block:Cube;
	var lastX:Float = -1;
	var lastY:Float = -1;
	var firing:Bool = false;

	public function new() {
		super();
		title = 'Shooter';
	}

	/** Called once, when the project starts. */
	override public function start():Void {
		scene = world();

		/** Null where nothing turned a 3D scene on, which is any run without a window. */
		if (scene == null) {
			return;
		}

		sim = new Sim();

		block = new Cube(1, 1, 1, true);
		block.unindex();
		block.addNormals();

		buildRoom();
		buildThings();

		var sun:DirLight = new DirLight(new Vector(-0.6, -0.5, -0.62), scene);
		sun.color.setColor(0xBFC6D6);
		sun.enableSpecular = true;

		var lamp:PointLight = new PointLight(scene);
		lamp.color.setColor(0xFFD9A0);
		lamp.params.set(1, 0, 9 / (Sim.ROOM * Sim.ROOM));
		lamp.setPosition(0, 0, Sim.HEIGHT - 0.5);

		scene.lightSystem.ambientLight.set(0.22, 0.22, 0.27);
		scene.camera.fovY = 70;

		aim();
	}

	/** The floor and four walls, as flattened cubes, which is the cheapest room that lights properly. */
	function buildRoom():Void {
		var span:Float = Sim.ROOM * 2;

		var floor:Mesh = new Mesh(block, scene);
		floor.scaleX = span;
		floor.scaleY = span;
		floor.scaleZ = 0.4;
		floor.z = -0.2;
		floor.material.color.setColor(0x2E3340);

		for (i in 0...4) {
			var wall:Mesh = new Mesh(block, scene);
			var side:Bool = i < 2;
			var far:Float = (i % 2 == 0) ? -Sim.ROOM : Sim.ROOM;

			wall.scaleX = side ? 0.4 : span;
			wall.scaleY = side ? span : 0.4;
			wall.scaleZ = Sim.HEIGHT;
			wall.x = side ? far : 0;
			wall.y = side ? 0 : far;
			wall.z = Sim.HEIGHT * 0.5;
			wall.material.color.setColor(side ? 0x3A4152 : 0x343B4A);
		}
	}

	/** The things worth shooting: targets that break, and crates that do not. */
	function buildThings():Void {
		for (i in 0...TARGETS) {
			var at:Float = (i / TARGETS) * Math.PI * 2;
			var mark:Body = new Body(Math.cos(at) * 6, Math.sin(at) * 6, 1.2 + (i % 3) * 0.9, 0.55);

			mark.breakable = true;
			mark.asleep = true;
			mark.tint = [0xFF5A5A, 0xFFC145, 0x5AD1FF, 0x9B6BFF, 0x5AFF9E, 0xFF7ACD][i % 6];

			sim.add(mark);
		}

		for (i in 0...CRATES) {
			var crate:Body = new Body((Math.random() - 0.5) * 10, (Math.random() - 0.5) * 10, 0.5, 0.5);
			crate.tint = 0x9A7B52;
			crate.asleep = true;

			sim.add(crate);
		}
	}

	/**
	 * Called every frame by the host.
	 *
	 * @param dt Seconds since the previous frame.
	 */
	override public function update(dt:Float):Void {
		if (scene == null) {
			return;
		}

		read(dt);
		sim.step(dt);

		follow();
		mirror();
	}

	/**
	 * Turns what is held down into what the player does.
	 *
	 * @param dt Seconds since the previous frame.
	 */
	function read(dt:Float):Void {
		var forward:Float = 0;
		var strafe:Float = 0;

		if (Key.isDown(Key.W)) {
			forward += 1;
		}
		if (Key.isDown(Key.S)) {
			forward -= 1;
		}
		if (Key.isDown(Key.D)) {
			strafe += 1;
		}
		if (Key.isDown(Key.A)) {
			strafe -= 1;
		}

		if (forward != 0 || strafe != 0) {
			sim.player.walk(forward, strafe, dt);
		}

		/** The arrows do what the pointer does, so this is playable without capturing one. */
		if (Key.isDown(Key.LEFT)) {
			sim.player.look(-KEY_TURN * dt, 0);
		}
		if (Key.isDown(Key.RIGHT)) {
			sim.player.look(KEY_TURN * dt, 0);
		}
		if (Key.isDown(Key.UP)) {
			sim.player.look(0, -KEY_TURN * dt);
		}
		if (Key.isDown(Key.DOWN)) {
			sim.player.look(0, KEY_TURN * dt);
		}

		if (Key.isPressed(Key.SPACE)) {
			sim.player.jump();
		}

		if (Key.isPressed(Key.F) || firing) {
			firing = false;
			fire();
		}
	}

	/** Fires, and makes a mesh for anything the shot created. */
	function fire():Void {
		sim.shoot();
		mirror();
	}

	/** Puts the camera behind the player's eyes, looking where they are looking. */
	function follow():Void {
		var p:Player = sim.player;

		scene.camera.pos.set(p.x, p.y, p.z);
		scene.camera.target.set(p.x + p.dirX(), p.y + p.dirY(), p.z + p.dirZ());
	}

	/** Points the camera before the first frame, so a run does not open facing nowhere. */
	function aim():Void {
		follow();
		mirror();
	}

	/**
	 * Brings the drawing up to date with the room.
	 *
	 * A mesh per body, made when the body first appears, hidden when the body stops being alive.
	 * Breaking a target adds seven bodies in the middle of a frame, so this has to cope with the
	 * list growing rather than assume it was fixed at the start.
	 */
	function mirror():Void {
		while (drawn < sim.bodies.length) {
			var body:Body = sim.bodies[drawn];
			var mesh:Mesh = new Mesh(block, scene);

			mesh.material.color.setColor(body.tint);
			shapes.push(mesh);
			drawn++;
		}

		for (i in 0...sim.bodies.length) {
			var body:Body = sim.bodies[i];
			var mesh:Mesh = shapes[i];

			if (!body.alive) {
				mesh.visible = false;
				continue;
			}

			var size:Float = body.half * 2;
			mesh.x = body.x;
			mesh.y = body.y;
			mesh.z = body.z;
			mesh.scaleX = size;
			mesh.scaleY = size;
			mesh.scaleZ = size;
			mesh.setRotation(0, 0, body.turn);
		}
	}

	/**
	 * The pointer moved.
	 *
	 * Deltas rather than where it is, because a first person camera is about how far it moved. The
	 * first move of a run has nothing to compare against, so it only stores where the pointer was.
	 *
	 * @param x Where, in the project's own canvas.
	 * @param y Where, in the project's own canvas.
	 */
	override public function onMouseMove(x:Float, y:Float):Void {
		if (sim == null) {
			return;
		}

		if (lastX >= 0) {
			sim.player.look((x - lastX) * SENSITIVITY, (y - lastY) * SENSITIVITY);
		}

		lastX = x;
		lastY = y;
	}

	/**
	 * The pointer went down, which fires on the next frame rather than here, so a shot and the step
	 * that follows it are always in that order.
	 *
	 * @param x Where, in the project's own canvas.
	 * @param y Where, in the project's own canvas.
	 */
	override public function onMouseDown(x:Float, y:Float):Void {
		firing = true;
	}
}
