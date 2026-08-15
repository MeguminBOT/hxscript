import h3d.Vector;
import h3d.prim.Cube;
import h3d.scene.Mesh;
import h3d.scene.Object;
import h3d.scene.fwd.DirLight;
import h3d.scene.fwd.PointLight;
import hxd.Key;
import view.Tracer;
import world.Body;
import world.Player;
import world.Sim;
import world.Slab;

/**
 * A room, some targets, and a gun.
 *
 * **This file draws and reads input, and decides nothing.** Where a shot lands, what a crate does
 * about it and where the pieces end up are all `Sim`, which has no scene graph in it and is tested
 * without a window. What is left here is the part that genuinely needs one: geometry, lights, a
 * camera behind the player's eyes, and a mesh per body kept where the body is.
 *
 * Move with **WASD**, look with the **mouse** or the **arrow keys**, jump with **space**, sprint with
 * **shift** and crouch with **ctrl**. **Left** fires and holds for automatic, **right** raises the
 * sights. Targets come apart, crates take the hit and slide, and dummies stay up to take another.
 */
class Shooter extends host.Project {
	static inline var TARGETS:Int = 14;
	static inline var CRATES:Int = 18;

	/** How many standing dummies, which are the only things that take more than one shot. */
	static inline var DUMMIES:Int = 6;

	/** How wide a cone counts as being in front of the player, for deciding what to draw. */
	static inline var IN_VIEW:Float = 0.35;

	/** How far the head turns per pixel of pointer movement. */
	static inline var SENSITIVITY:Float = 0.0022;

	/** How far a stick has to be pushed before it counts, so a resting one does not drift the view. */
	static inline var STICK_DEAD:Float = 0.15;

	/** How fast a fully pushed stick turns, in radians per second. */
	static inline var STICK_TURN:Float = 2.6;

	/** Seconds between shots while the trigger is held. */
	static inline var RATE:Float = 0.11;

	/** The lens while hip firing, and while looking down the sights. */
	static inline var FOV_HIP:Float = 70;

	static inline var FOV_AIM:Float = 42;

	/** How much slower the view turns while aiming, which is what makes sights worth using. */
	static inline var AIM_STEADY:Float = 0.45;

	/**
	 * How far off the aim a shot may leave, in radians, from the hip and down the sights.
	 *
	 * Small on purpose. A hundredth of a radian is a little over half a degree, which puts a shot a
	 * hand's width off at twenty paces: enough that a burst scatters, far too little to excuse a
	 * miss anyone could see.
	 */
	static inline var SPRAY_HIP:Float = 0.0095;

	static inline var SPRAY_AIM:Float = 0.0022;

	/** How much of the way to fully bloomed one shot takes the spread. */
	static inline var BLOOM_GAIN:Float = 0.2;

	/** How much wider than its resting self a fully bloomed cone is. */
	static inline var BLOOM_WIDTH:Float = 1.7;

	/** How quickly the cone closes again once the trigger is let go, as a fraction per second. */
	static inline var BLOOM_CALM:Float = 2.4;

	/** How far along the gun the muzzle is, for the flash and for where a streak starts. */
	static inline var MUZZLE:Float = 0.66;

	/** How far the muzzle flash carries, which is a pool around the player rather than a room light. */
	static inline var FLASH_REACH:Float = 7;

	/**
	 * How much of its own size the held weapon is drawn at.
	 *
	 * Everything about where it sits is written at full size and scaled by this on the way out, so
	 * the shape stays readable while the whole of it fits inside the empty sphere around the eye.
	 */
	static inline var VIEW:Float = 0.34;

	/** How fast the arrow keys turn, in radians per second, for playing without a pointer. */
	static inline var KEY_TURN:Float = 1.8;

	var sim:Sim;
	var scene:h3d.scene.Scene;

	/** A mesh per body, in the same order, so the two are matched by index. */
	var shapes:Array<Mesh> = [];

	/** How many bodies had a mesh made for them, since breaking adds more. */
	var drawn:Int = 0;

	var block:Cube;

	/** Whether the trigger is held, which is what makes fire automatic rather than per click. */
	var firing:Bool = false;

	/** Seconds until the next shot may leave, so holding fires at a rate rather than every frame. */
	var cooling:Float = 0;

	/** Whether the sights are up, and how far the view has moved towards them. */
	var sighting:Bool = false;

	var sighted:Float = 0;

	/**
	 * How far through the walking cycle the held weapon is.
	 *
	 * Advanced by distance covered rather than by time, so it keeps step with the feet: a player
	 * standing still stops mid stride instead of swaying on the spot, and one walking slowly bobs
	 * slowly without any of it being timed separately.
	 */
	var bob:Float = 0;

	/** The flash at the muzzle, and how much of its moment is left. */
	var flash:Mesh;

	var flare:PointLight;
	var flashing:Float = 0;

	/** The tracers in flight, each one a streak travelling from the muzzle to where the shot landed. */
	var tracers:Array<Tracer> = [];

	/** The gun held in view, and how far it is still kicking back. */
	var gun:Object;

	/** The player's own body, seen by looking down at it. */
	var body:Object;

	/** The mark in the middle of the screen, which is where a shot goes. */
	var cross:h2d.Graphics;

	var recoil:Float = 0;

	/** How far the cone has opened from being fired steadily, from nothing to all of it. */
	var bloom:Float = 0;

	/** Where the muzzle ended up this frame, worked out where the gun is placed and used twice. */
	var muzzleX:Float = 0;

	var muzzleY:Float = 0;
	var muzzleZ:Float = 0;

	/** The pad, once one turns up. Null until then, and null is the ordinary case. */
	var pad:hxd.Pad;

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

		buildSky();
		buildRoom();
		buildTown();
		buildThings();

		/**
		 * **A room is lit differently from an open scene, and this was lit like an open one.**
		 * Outdoors a single hard light is right, because the sky fills everything it misses. Indoors
		 * there is no sky: what a surface does not get from a lamp it gets from the walls, and with
		 * nothing standing in for that a room is one lit face and five black ones.
		 *
		 * So the fill is the biggest number here rather than an afterthought, and the lamps carry far
		 * enough to reach the corners. `reach` is the distance at which a lamp falls to a tenth, which
		 * is why it is larger than the room rather than half of it.
		 *
		 * **The sun is nearly overhead, and leans just enough to be read.** Straight down would light
		 * every roof and floor evenly and leave the walls to the fill alone, with shadows hidden
		 * directly beneath whatever cast them; the small lean puts a shadow beside each building
		 * rather than under it, which is what makes the heights legible from the ground.
		 */
		var sun:DirLight = new DirLight(new Vector(-0.2, -0.15, -0.97), scene);
		sun.color.setColor(0x9AA6BE);
		sun.enableSpecular = true;

		var reach:Float = Sim.ROOM * 1.1;

		for (i in 0...3) {
			var lamp:PointLight = new PointLight(scene);
			lamp.color.setColor(i % 2 == 0 ? 0xFFE3B8 : 0xB8CCFF);
			lamp.params.set(1, 0, 9 / (reach * reach));

			/** Four in the corners and one in the middle, so a room this size has no dead quarter. */
			var spread:Float = Sim.ROOM * 0.5;
			var corner:Float = (i / 3) * Math.PI * 2;

			lamp.setPosition(Math.cos(corner) * spread, Math.sin(corner) * spread, Sim.HEIGHT - 1.2);
		}

		scene.lightSystem.ambientLight.set(0.42, 0.43, 0.5);

		/**
		 * **A shadow is a colour, and its default is black.** `DefaultShadowMap.color` starts as a
		 * plain `h3d.Vector`, which is `(0, 0, 0)`, and a surface the map covers is multiplied by it.
		 * That is not a dark surface: it is an absence of one, and no amount of ambient light reaches
		 * it, because the multiply happens after the ambient is added.
		 *
		 * So a room lit correctly still comes out as flat black cut-outs with hard edges, and the
		 * instinct to turn the lights up cannot fix it. What fixes it is saying what a shadow is: a
		 * little cooler and darker than the fill, which is what a shadow in a lit room looks like.
		 */
		var shade:h3d.pass.DefaultShadowMap = scene.renderer.shadow;
		shade.color.set(0.34, 0.36, 0.46);
		shade.power = 12;
		shade.bias = 0.02;

		/**
		 * **Fixed to the room rather than fitted to the view.** `autoShrink` re-fits the shadow map
		 * to whatever the camera can currently see, which is the right default for an open world and
		 * wrong here: turning on the spot changes what is in view, so the map changes size, so every
		 * shadow in the room shifts and crawls, and the edge of the fitted area sweeps across the
		 * walls as a hard diagonal.
		 *
		 * The room never changes size, so one map over a fixed distance is both steadier and
		 * cheaper.
		 */
		/**
		 * Fitted again, and that was the wrong call last time. Holding one map over a fixed distance
		 * is steady in a small room and useless in a large one: spread across seventy units, a
		 * thousand texels leave a shadow too coarse to see, which is why they went missing when the
		 * room grew. Fitting keeps the resolution where the player is; `maxDist` stops it reaching so
		 * far that the same thing happens again.
		 */
		shade.autoShrink = true;
		shade.maxDist = 45;
		scene.camera.fovY = FOV_HIP;

		buildGun();
		buildFlash();
		buildBody();
		buildCross();

		/**
		 * Takes the pointer: hidden, held inside the window, and reporting how far it moved rather
		 * than where it is. The host gives it back when this project stops, however it stops.
		 */
		captureMouse(true);

		/** Whenever one arrives, rather than only if one is already plugged in. */
		hxd.Pad.wait(function(found:hxd.Pad):Void pad = found);

		aim();
	}

	/**
	 * The sky, as a sphere turned outside in.
	 *
	 * The room has no ceiling, so everything above the walls was the empty frame behind the scene:
	 * flat black, and plainly nothing rather than plainly sky.
	 *
	 * Inside out by scaling one axis negative, which mirrors the geometry and so reverses which way
	 * every triangle winds. The faces that were pointing away now point inwards and the ordinary
	 * culling rule draws them, with no enum to name and no culling mode to set. Lighting is off,
	 * because a sky is not lit by the room, and it casts nothing for the same reason.
	 *
	 * @return Nothing; the sphere is added to the scene.
	 */
	function buildSky():Void {
		var dome:h3d.prim.Sphere = new h3d.prim.Sphere(1, 24, 16);
		dome.addNormals();

		var sky:Mesh = new Mesh(dome, scene);
		var far:Float = Sim.ROOM * 6;

		sky.scale(far);
		sky.scaleX = -far;
		sky.z = Sim.HEIGHT * 0.5;

		sky.material.color.setColor(0x243049);
		sky.material.mainPass.enableLights = false;
		sky.material.castShadows = false;
		sky.material.receiveShadows = false;
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

	/**
	 * Some buildings, arranged so there is something to get behind, onto, and between.
	 *
	 * Deliberately a range of heights. Anything at or below the step allowance is walked over without
	 * noticing, waist height is cover to crouch behind and a place to climb from, and the tall ones
	 * are solid: the interest is in the ones a player can chain together to reach a roof they could
	 * not jump to directly.
	 */
	function buildTown():Void {
		var far:Float = Sim.ROOM;

		var plan:Array<Array<Float>> = [
			[-0.45, 0.35, 0.16, 0.16, 5.5],
			[-0.2, 0.55, 0.1, 0.1, 2.6],
			[-0.62, 0.1, 0.09, 0.22, 3.4],
			[0.4, 0.42, 0.18, 0.13, 6.5],
			[0.15, 0.6, 0.08, 0.08, 1.2],
			[0.62, 0.2, 0.12, 0.12, 4.2],
			[0.3, -0.3, 0.2, 0.14, 3],
			[0.05, -0.55, 0.1, 0.18, 4.8],
			[-0.35, -0.4, 0.15, 0.15, 2.1],
			[-0.6, -0.62, 0.11, 0.11, 5.9],
			[0.68, -0.55, 0.13, 0.1, 1.6],
			[-0.05, 0.08, 0.07, 0.07, 0.9],
			[0.22, 0.1, 0.06, 0.16, 0.5],
			[-0.22, -0.12, 0.14, 0.06, 1.9]
		];

		for (i in 0...plan.length) {
			var at:Array<Float> = plan[i];

			solid(at[0] * far, at[1] * far, at[2] * far, at[3] * far, at[4],
				[0x4A5164, 0x555C71, 0x424858, 0x5C6478][i % 4]);
		}

		/** Two halls to go inside, and a flight of ledges up to the roof of one of them. */
		hall(-far * 0.12, far * 0.3, far * 0.13, far * 0.1, 4.2, 0x5A6178);
		hall(far * 0.42, -far * 0.12, far * 0.11, far * 0.13, 3.6, 0x4E556A);

		for (i in 0...5) {
			solid(far * 0.42 - far * 0.11 - 0.7 - i * 1.3, -far * 0.12, 0.65, far * 0.13, 0.62 + i * 0.62, 0x646B80);
		}
	}

	/**
	 * One solid building, in the room and in the picture.
	 *
	 * @param x Where its middle is.
	 * @param y Where its middle is.
	 * @param hx Half its width.
	 * @param hy Half its depth.
	 * @param tall How tall.
	 * @param tint What colour.
	 */
	function solid(x:Float, y:Float, hx:Float, hy:Float, tall:Float, tint:Int):Void {
		var slab:Slab = sim.build(x, y, hx, hy, tall, tint);
		draw(slab);
	}

	/**
	 * A building with a way in and something to see out of.
	 *
	 * **Made of walls rather than cut out of a box.** A door is not a hole in a solid thing here: it
	 * is the gap left between two pieces, because everything that collides is a box and a box with a
	 * hole in it is not a box. So the front is two posts with a lintel over them, the back is a sill
	 * and a header with a gap between, and the roof lies across the top of it all.
	 *
	 * @param x Where its middle is.
	 * @param y Where its middle is.
	 * @param hx Half its width.
	 * @param hy Half its depth.
	 * @param tall How tall.
	 * @param tint What colour.
	 */
	function hall(x:Float, y:Float, hx:Float, hy:Float, tall:Float, tint:Int):Void {
		var wall:Float = 0.35;
		var door:Float = 1.1;
		var head:Float = 2.4;

		var post:Float = (hx - door) * 0.5;

		solid(x - door - post, y - hy, post, wall, tall, tint);
		solid(x + door + post, y - hy, post, wall, tall, tint);
		lift(x, y - hy, door, wall, head, tall - head, tint);

		solid(x, y + hy, hx, wall, 1.05, tint);
		lift(x, y + hy, hx, wall, 2.15, tall - 2.15, tint);

		solid(x - hx, y, wall, hy, tall, tint);
		solid(x + hx, y, wall, hy, tall, tint);
		lift(x, y, hx, hy, tall, 0.3, tint);
	}

	/**
	 * A piece that starts partway up rather than on the floor: a lintel, a header, a roof.
	 *
	 * @param x Where its middle is.
	 * @param y Where its middle is.
	 * @param hx Half its width.
	 * @param hy Half its depth.
	 * @param base How high its underside is.
	 * @param deep How thick it is.
	 * @param tint What colour.
	 */
	function lift(x:Float, y:Float, hx:Float, hy:Float, base:Float, deep:Float, tint:Int):Void {
		if (deep <= 0.01) {
			return;
		}

		var slab:Slab = new Slab(x, y, base + deep * 0.5, hx, hy, deep * 0.5);
		slab.tint = tint;

		sim.blocks.push(slab);
		draw(slab);
	}

	/**
	 * Puts a mesh where a building is.
	 *
	 * @param slab The building.
	 */
	function draw(slab:Slab):Void {
		var mesh:Mesh = new Mesh(block, scene);

		mesh.x = slab.x;
		mesh.y = slab.y;
		mesh.z = slab.z;
		mesh.scaleX = slab.hx * 2;
		mesh.scaleY = slab.hy * 2;
		mesh.scaleZ = slab.hz * 2;
		mesh.material.color.setColor(slab.tint);
	}

	/**
	 * A spot near the one asked for that is not inside a building, and the ground height there.
	 *
	 * **Placing without checking was the bug.** Scenery scattered by chance across a room full of
	 * buildings puts a fair share of it through a wall, and the pieces that are only partly inside
	 * are the worse half: they sit at the wrong height and read as sunk into the floor. This walks
	 * outward from where it was asked until it finds room, and reports the height of whatever it
	 * ends up standing on so nothing is left hovering or buried.
	 *
	 * @param x Where it would like to be.
	 * @param y Where it would like to be.
	 * @param half Half its width.
	 * @return Its place, as x, y, and the height of the ground under it.
	 */
	function clearSpot(x:Float, y:Float, half:Float):Array<Float> {
		var edge:Float = Sim.ROOM - half - 0.5;

		for (i in 0...24) {
			var away:Float = i * 0.9;
			var turn:Float = i * 2.4;

			var px:Float = x + Math.cos(turn) * away;
			var py:Float = y + Math.sin(turn) * away;

			if (px < -edge || px > edge || py < -edge || py > edge) {
				continue;
			}

			var floor:Float = sim.groundAt(px, py);

			if (sim.free(px, py, floor + half + 0.02, half)) {
				return [px, py, floor];
			}
		}

		return [x, y, sim.groundAt(x, y)];
	}

	/** The things worth shooting: targets that break, and crates that do not. */
	function buildThings():Void {
		for (i in 0...DUMMIES) {
			var at:Float = (i / DUMMIES) * Math.PI * 2 + 0.4;
			var far:Float = Sim.ROOM * 0.55;

			var spot:Array<Float> = clearSpot(Math.cos(at) * far, Math.sin(at) * far, 0.7);
			var stand:Body = new Body(spot[0], spot[1], spot[2] + 1.1, 0.7);
			stand.dummy = true;
			stand.health = 5;
			stand.tint = 0xCFC0A4;

			sim.add(stand);
		}

		for (i in 0...TARGETS) {
			var at:Float = (i / TARGETS) * Math.PI * 2;
			var spot:Array<Float> = clearSpot(Math.cos(at) * Sim.ROOM * 0.7, Math.sin(at) * Sim.ROOM * 0.7, 0.55);
			var mark:Body = new Body(spot[0], spot[1], spot[2] + 1.2 + (i % 3) * 0.9, 0.55);

			mark.breakable = true;
			mark.asleep = true;
			mark.tint = [0xFF5A5A, 0xFFC145, 0x5AD1FF, 0x9B6BFF, 0x5AFF9E, 0xFF7ACD][i % 6];

			sim.add(mark);
		}

		for (i in 0...CRATES) {
			var spot:Array<Float> = clearSpot((Math.random() - 0.5) * Sim.ROOM * 1.5,
				(Math.random() - 0.5) * Sim.ROOM * 1.5, 0.5);
			var crate:Body = new Body(spot[0], spot[1], spot[2] + 0.5, 0.5);
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

		recoil *= 1 - Math.min(1, dt * 9);
		bloom *= 1 - Math.min(1, dt * BLOOM_CALM);

		var pace:Float = Math.sqrt(sim.player.vx * sim.player.vx + sim.player.vy * sim.player.vy);

		if (sim.player.onGround && pace > 0.4) {
			bob += pace * dt * 1.7;
		} else {
			/** Eased back to rest rather than frozen, so stopping settles the weapon. */
			bob += (Math.round(bob / Math.PI) * Math.PI - bob) * Math.min(1, dt * 6);
		}

		/** Eased rather than snapped, so raising the sights is a movement rather than a cut. */
		var wants:Float = sighting ? 1 : 0;
		sighted += (wants - sighted) * Math.min(1, dt * 12);

		scene.camera.fovY = FOV_HIP + (FOV_AIM - FOV_HIP) * sighted;

		follow();
		hold();
		streaks(dt);
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

		sim.player.sprinting = Key.isDown(Key.SHIFT);
		sim.player.crouching = Key.isDown(Key.CTRL);

		/**
		 * Held rather than clicked. `cooling` is what turns a held trigger into a rate: without it a
		 * held button would fire once per frame, which is not automatic fire, it is the frame rate.
		 */
		cooling -= dt;

		if ((firing || Key.isDown(Key.F)) && cooling <= 0) {
			cooling = RATE;
			fire();
		}

		gamepad(dt);
	}

	/**
	 * The same again from a pad, when one is connected.
	 *
	 * Left stick walks, right stick looks, the lower shoulder trigger fires and the bottom face
	 * button jumps, which is where a player expects each of them. The sticks are read as how far
	 * they are pushed rather than as pressed or not, so walking and turning are both proportional in
	 * a way the keyboard cannot be.
	 *
	 * @param dt Seconds since the previous frame.
	 */
	function gamepad(dt:Float):Void {
		if (pad == null || !pad.connected) {
			return;
		}

		if (pad.xAxis != 0 || pad.yAxis != 0) {
			/** Down on a stick is forward, which is why the vertical is negated. */
			sim.player.walk(-pad.yAxis, pad.xAxis, dt);
		}

		var lookX:Float = pad.values[pad.config.ranalogX];
		var lookY:Float = pad.values[pad.config.ranalogY];

		if (Math.abs(lookX) > STICK_DEAD || Math.abs(lookY) > STICK_DEAD) {
			sim.player.look(lookX * STICK_TURN * dt, lookY * STICK_TURN * dt);
		}

		if (pad.isPressed(pad.config.A)) {
			sim.player.jump();
		}

		sim.player.sprinting = pad.isDown(pad.config.LCLK);
		sim.player.crouching = pad.isDown(pad.config.B);

		if (pad.isPressed(pad.config.RT) || pad.isPressed(pad.config.LT)) {
			fire();
		}
	}

	/**
	 * Fires: decides the hit, kicks the gun, lights the muzzle and sends a streak after it.
	 *
	 * **The shot is decided instantly and drawn as though it travelled**, which is what nearly every
	 * shooter does. `Sim.shoot` answers immediately, so what is hit never depends on the frame rate,
	 * and the tracer is a picture of that answer rather than the thing being asked. A bullet that
	 * really flew would be a different game and a different set of cases.
	 */
	function fire():Void {
		var p:Player = sim.player;

		/**
		 * **Not quite where the crosshair is, and the amount is the whole design of a gun.**
		 *
		 * A shot that goes exactly where it is pointed makes the crosshair a promise, and a game
		 * whose crosshair never lies has no reason for anyone to stop holding the trigger. So every
		 * shot leaves inside a cone: tight enough that a careful single shot still lands where it was
		 * aimed, wide enough that the tenth round of a burst is somebody's problem.
		 *
		 * Three things set how wide. Aiming closes it, which is the second reason to raise the sights
		 * after the lens. Sustained fire opens it through `bloom`, so the cost of holding down is
		 * paid over the burst rather than charged at the first round. And the offset is spread over
		 * the disc rather than along the radius, by taking the square root: without it the same
		 * angles pack towards the middle and the spread is a dot with a halo instead of a cone.
		 */
		var spread:Float = (SPRAY_HIP + (SPRAY_AIM - SPRAY_HIP) * sighted) * (1 + bloom * BLOOM_WIDTH);

		var turn:Float = Math.random() * Math.PI * 2;
		var away:Float = Math.sqrt(Math.random()) * spread;

		var dx:Float = p.dirX();
		var dy:Float = p.dirY();
		var dz:Float = p.dirZ();

		/**
		 * Tilted in the plane across the aim, built from any two directions square to it. Which two
		 * does not matter here the way it does for the viewmodel, since the offset is turned through
		 * a full circle anyway and a mirrored basis mirrors a circle onto itself.
		 */
		var flat:Float = Math.sqrt(dx * dx + dy * dy);

		if (flat > 0.0001) {
			var sx:Float = -dy / flat;
			var sy:Float = dx / flat;

			var ux:Float = -sy * dz;
			var uy:Float = sx * dz;
			var uz:Float = flat;

			var side:Float = Math.cos(turn) * away;
			var lift:Float = Math.sin(turn) * away;

			dx += sx * side + ux * lift;
			dy += sy * side + uy * lift;
			dz += uz * lift;

			var length:Float = Math.sqrt(dx * dx + dy * dy + dz * dz);

			dx /= length;
			dy /= length;
			dz /= length;
		}

		sim.shootAlong(dx, dy, dz);

		recoil = 1;
		flashing = 0.045;
		bloom = Math.min(1, bloom + BLOOM_GAIN);

		/** The aim climbs, and stays climbed until `Player.settle` gives it back. */
		p.kick(Player.KICK);

		/**
		 * **Drawn to where the shot landed rather than along where it was aimed.**
		 *
		 * A streak leaves the muzzle, which is off to one side of the eye, so sending it along the
		 * look direction draws a line parallel to the aim and permanently beside it: it passes the
		 * target by however far the gun is held from the face, at every distance, and reads as the
		 * gun shooting crooked. Given the point instead it converges on the mark, which is what a
		 * shot from a barrel a hand's width off the sight line actually does.
		 */
		tracers.push(new Tracer(scene, block, muzzleX, muzzleY, muzzleZ, sim.hitX, sim.hitY, sim.hitZ));
		mirror();
	}

	/**
	 * The gun in view, built from boxes rather than loaded from a file.
	 *
	 * **No model, on purpose.** heaps 2.1.0 reads `fbx` and its own `hmd` and nothing else, so the
	 * gltf and obj files most open asset libraries ship cannot be loaded at all, and a model that
	 * could would have to be redistributed with this app under whatever licence it came with. Six
	 * boxes read as a gun at arm's length and cost nothing to ship.
	 *
	 * Everything is placed relative to the muzzle pointing along positive x, which is the direction
	 * `hold` then turns to face wherever the player is looking.
	 */
	function buildGun():Void {
		gun = new Object(scene);
		gun.scale(VIEW);

		piece(0.34, 0.09, 0.11, 0.16, 0, -0.01, 0x3B3F47);
		piece(0.30, 0.05, 0.05, 0.46, 0, 0.03, 0x23262C);
		piece(0.09, 0.07, 0.16, 0.05, 0, -0.13, 0x4A4038);
		piece(0.12, 0.06, 0.05, -0.06, 0, -0.02, 0x2B2E34);
		piece(0.05, 0.03, 0.04, 0.60, 0, 0.05, 0x596070);
		piece(0.07, 0.11, 0.03, 0.20, 0, 0.07, 0x2B2E34);
	}

	/**
	 * One box of the gun.
	 *
	 * @param sx How big, along the barrel.
	 * @param sy How big, across.
	 * @param sz How big, up.
	 * @param at Where along the barrel.
	 * @param across Where across.
	 * @param up Where up.
	 * @param tint What colour.
	 */
	function piece(sx:Float, sy:Float, sz:Float, at:Float, across:Float, up:Float, tint:Int):Void {
		var part:Mesh = new Mesh(block, gun);

		part.scaleX = sx;
		part.scaleY = sy;
		part.scaleZ = sz;
		part.x = at;
		part.y = across;
		part.z = up;
		part.material.color.setColor(tint);
		part.material.shadows = false;
	}

	/**
	 * Carries the gun where the eyes are, pointing where they point.
	 *
	 * Held in the world rather than parented to a camera, because heaps' camera is not an object in
	 * the scene graph and has nothing to parent to. So the offset is worked out in the player's own
	 * basis and added: along their look direction, along their right, and down.
	 */
	function hold():Void {
		var p:Player = sim.player;

		var fx:Float = p.dirFlatX();
		var fy:Float = p.dirFlatY();

		var out:Float = 0.5 - recoil * 0.12;

		/**
		 * On the right, along the same basis walking uses, so the two cannot disagree about which
		 * side that is. Brought in towards the middle while the sights are up, which is the whole
		 * visual idea of aiming: the gun moves under the crosshair instead of sitting beside it.
		 */
		var rx:Float = p.rightX();
		var ry:Float = p.rightY();

		var side:Float = 0.32 * (1 - sighted) + 0.02 * sighted;
		var drop:Float = -0.26 + 0.14 * sighted + Math.sin(bob * 2) * 0.018 * (1 - sighted);

		side += Math.sin(bob) * 0.022 * (1 - sighted);

		/**
		 * **Placed in the camera's own basis, so it never leaves the screen.**
		 *
		 * It used to be placed partly in the world: the sideways step was horizontal and the height
		 * came from the pitch, which means its distance from the eye grew as the view tipped and the
		 * whole thing swung across the picture and out of frame. A held object is not somewhere in
		 * the room, it is somewhere on the screen, so the offsets belong along forward, right and up
		 * as the camera has them.
		 *
		 * `up` is forward crossed with right, in that order, and the order is not a detail. `right`
		 * here is the right of the picture, which under `HAND` is the opposite of the right hand
		 * rule's, so the three of them make a left handed set: crossing right with forward points at
		 * the floor. Taken the other way round it points at the ceiling, and a negative `drop` then
		 * lowers the gun instead of raising it.
		 */
		var f3x:Float = p.dirX();
		var f3y:Float = p.dirY();
		var f3z:Float = p.dirZ();

		var ux:Float = -ry * f3z;
		var uy:Float = rx * f3z;
		var uz:Float = ry * f3x - rx * f3y;

		/**
		 * **Drawn back when there is something in front of it.**
		 *
		 * A held weapon is placed on the screen, so nothing about where it sits knows the room is
		 * there: stand against a wall and the barrel is inside it. What every first person game does
		 * instead is ask along the barrel how far there is to go, and pull the whole thing in when
		 * the answer is shorter than the gun.
		 *
		 * Measured from the eye rather than from the gun, because the eye is the one point already
		 * guaranteed to be inside the room.
		 */
		/**
		 * **Small, and close enough that nothing can ever be between it and the eye.**
		 *
		 * Three attempts went into keeping the barrel out of the scenery by measuring: cast a ray,
		 * pull the gun back, clamp it above the floor. Each was correct about the geometry it was
		 * given and wrong about which point that geometry belonged to, and each left a case that
		 * still clipped.
		 *
		 * There is nothing to measure. The player cannot stand within `GIRTH` of a wall and their
		 * eyes are at least a metre above the ground even crouched, so a sphere of about half a metre
		 * around the eye is empty at all times, guaranteed by the collision that is already there.
		 * A weapon drawn entirely inside that sphere cannot intersect anything, whatever it is
		 * pointed at, and needs no test to prove it.
		 *
		 * Which is also why viewmodels in real games are tiny and held under the lens rather than
		 * being weapon sized and held at arm's length: near and small looks identical to far and
		 * large, and only one of them can be walked into a wall.
		 */
		var reach:Float = out * VIEW;

		gun.x = p.x + f3x * reach + rx * side * VIEW + ux * drop * VIEW;
		gun.y = p.y + f3y * reach + ry * side * VIEW + uy * drop * VIEW;
		gun.z = p.z + f3z * reach + uz * drop * VIEW;

		/**
		 * Pitched to match the view, and thrown further up by the kick.
		 *
		 * Rotation about y takes the barrel from forward towards the floor, which is why the view's
		 * own pitch arrives negated. The kick is negated for the same reason and had not been: a
		 * positive term there drove the muzzle down into the shot rather than up out of it, so firing
		 * looked like the gun being pressed towards the ground.
		 */
		gun.setRotation(0, -p.pitch - recoil * 0.35, p.yaw);

		var alongZ:Float = Math.sin(p.pitch);
		var alongFlat:Float = Math.cos(p.pitch);

		muzzleX = gun.x + fx * alongFlat * MUZZLE * VIEW;
		muzzleY = gun.y + fy * alongFlat * MUZZLE * VIEW;
		muzzleZ = gun.z + alongZ * MUZZLE * VIEW;


		/**
		 * The body turns with the player and never tips. Pitch belongs to the head: a torso that
		 * rolled with the view would swing through the floor every time somebody looked down.
		 */
		body.x = p.x;
		body.y = p.y;
		body.z = p.z;
		body.setRotation(0, 0, p.yaw);
	}

	/**
	 * The player's own body, in boxes, hung below the eyes.
	 *
	 * Everything is placed relative to the eyes rather than to the floor, because that is what the
	 * camera is attached to and what the whole thing has to hang from. Nothing here is ever seen
	 * except by looking down, which is exactly why it is worth having: a first person game with
	 * nothing below the camera reads as a floating gun.
	 */
	function buildBody():Void {
		body = new Object(scene);

		limb(0.34, 0.24, 0.62, 0, 0, -0.52, 0x3E4657);
		limb(0.2, 0.18, 0.34, 0.06, 0.28, -0.4, 0x2F3543);
		limb(0.2, 0.18, 0.34, 0.06, -0.28, -0.4, 0x2F3543);
		limb(0.18, 0.2, 0.5, 0, 0.14, -1.05, 0x262B36);
		limb(0.18, 0.2, 0.5, 0, -0.14, -1.05, 0x262B36);
		limb(0.28, 0.22, 0.14, 0.04, 0.16, -1.34, 0x1D2129);
		limb(0.28, 0.22, 0.14, 0.04, -0.16, -1.34, 0x1D2129);
	}

	/**
	 * One box of the body.
	 *
	 * @param sx How big, along the way the player faces.
	 * @param sy How big, across.
	 * @param sz How big, up.
	 * @param at Where along the way they face.
	 * @param across Where across.
	 * @param up Where up, measured down from the eyes.
	 * @param tint What colour.
	 */
	function limb(sx:Float, sy:Float, sz:Float, at:Float, across:Float, up:Float, tint:Int):Void {
		var part:Mesh = new Mesh(block, body);

		part.scaleX = sx;
		part.scaleY = sy;
		part.scaleZ = sz;
		part.x = at;
		part.y = across;
		part.z = up;
		part.material.color.setColor(tint);

		/**
		 * **Drawn for its shadow and for nothing else.**
		 *
		 * The colour mask is off on every channel, so this renders exactly as it did and writes none
		 * of the result: it is in the shadow pass, it casts, and the camera never sees it. That is
		 * what a first person body is for, since the only view of it a player gets is the one on the
		 * floor beside them.
		 *
		 * `visible = false` would not do, because it takes the object out of every pass including
		 * the one that makes the shadow, and moving it out of view is impossible when the view is
		 * attached to it.
		 *
		 * **The depth has to go too, and forgetting it is what cut holes in the room.** A colour mask
		 * stops the colour and nothing else: the shoulders and the chest were still writing depth a
		 * few centimetres in front of the lens, so everything behind them failed the depth test and
		 * was never drawn. What that looks like is not an invisible body, it is a body shaped hole
		 * punched through the middle of the picture with the sky showing through it, which is exactly
		 * the shape it was accused of clipping into.
		 *
		 * It receives nothing and is lit by nothing, because a surface nobody sees has nothing to
		 * receive and no reason to be shaded.
		 */
		part.material.mainPass.setColorMask(false, false, false, false);
		part.material.mainPass.depthWrite = false;
		part.material.mainPass.enableLights = false;
		part.material.receiveShadows = false;
	}

	/**
	 * The flash at the muzzle: something bright, and a light to go with it.
	 *
	 * The light is the half that matters. A bright quad shows where the shot left from and lights
	 * nothing, so a room lit only by gunfire stays dark; a point light for a fraction of a second is
	 * what puts the walls in the picture and tells the player where they are firing from.
	 */
	function buildFlash():Void {
		flash = new Mesh(block, gun);

		flash.x = 0.66;
		flash.scaleX = 0.14;
		flash.scaleY = 0.14;
		flash.scaleZ = 0.14;
		flash.material.color.setColor(0xFFE9A8);
		flash.material.mainPass.enableLights = false;
		flash.material.castShadows = false;
		flash.material.receiveShadows = false;
		flash.visible = false;

		flare = new PointLight(scene);
		flare.color.setColor(0xFFD48A);

		/**
		 * **Small, and that matters twice over.**
		 *
		 * Its reach is short so it lights what the player is standing next to rather than the far
		 * wall. And it is one light among few: forward rendering gives each object a fixed number of
		 * lights and takes the nearest, so a room already carrying its budget has to drop one to fit
		 * this in, and every surface changes shade at the moment of firing. That is what made a
		 * muzzle flash look like the whole room flickering. Three lamps and a sun leave room for it.
		 */
		flare.params.set(1, 0, 9 / (FLASH_REACH * FLASH_REACH));
		flare.visible = false;
	}

	/**
	 * Advances the flash and every tracer in flight.
	 *
	 * @param dt Seconds since the previous frame.
	 */
	function streaks(dt:Float):Void {
		flashing -= dt;

		var lit:Bool = flashing > 0;
		flash.visible = lit;
		flare.visible = lit;

		if (lit) {
			/**
			 * At the muzzle rather than in front of the eyes. Lighting the room from the middle of
			 * the view reads as the flash coming out of the player's face, which is exactly what it
			 * looked like while strafing, when the gun is furthest from that line.
			 */
			flare.setPosition(muzzleX, muzzleY, muzzleZ);
		}

		var i:Int = tracers.length;

		while (i > 0) {
			i--;

			if (!tracers[i].step(dt)) {
				tracers[i].drop();
				tracers.splice(i, 1);
			}
		}
	}

	/**
	 * The crosshair, drawn flat over everything.
	 *
	 * On `layer`, which is the project's own 2D object, so it is drawn after the world and never
	 * moves with it. A gap in the middle rather than a solid cross, because the one pixel a shot
	 * actually goes through is the one a solid cross covers up.
	 */
	function buildCross():Void {
		cross = new h2d.Graphics(layer);

		var midX:Float = screenWidth * 0.5;
		var midY:Float = screenHeight * 0.5;

		var gap:Float = 5;
		var arm:Float = 12;

		cross.lineStyle(2, 0xFFFFFF, 0.85);

		cross.moveTo(midX - gap - arm, midY);
		cross.lineTo(midX - gap, midY);
		cross.moveTo(midX + gap, midY);
		cross.lineTo(midX + gap + arm, midY);
		cross.moveTo(midX, midY - gap - arm);
		cross.lineTo(midX, midY - gap);
		cross.moveTo(midX, midY + gap);
		cross.lineTo(midX, midY + gap + arm);

		cross.lineStyle();
		cross.beginFill(0xFFFFFF, 0.9);
		cross.drawRect(midX - 1, midY - 1, 2, 2);
		cross.endFill();
	}

	/** Puts the camera behind the player's eyes, looking where they are looking. */
	function follow():Void {
		var p:Player = sim.player;

		scene.camera.pos.set(p.x, p.y, p.z);
		scene.camera.target.set(p.x + p.dirX(), p.y + p.dirY(), p.z + p.dirZ());
	}

	/**
	 * Points the camera before the first frame, so a run does not open facing nowhere.
	 *
	 * No time passes here, so nothing that advances is called: this places what already exists.
	 */
	function aim():Void {
		follow();
		hold();
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

			/**
			 * **Only what is in front, which is most of what a room is not.** heaps will happily
			 * submit every object in the scene whether or not the camera can see it, and in a room
			 * this size that is most of them: a lens of seventy degrees sees well under half of what
			 * surrounds the player.
			 *
			 * A cone rather than the real frustum, and a generous one, because this decides whether
			 * something is drawn at all: a shape that vanishes at the edge of the screen is far worse
			 * than a few drawn just outside it. Anything close enough to be underfoot is kept
			 * regardless, since the cone is a poor test at short range.
			 */
			var dx:Float = body.x - sim.player.x;
			var dy:Float = body.y - sim.player.y;
			var away:Float = Math.sqrt(dx * dx + dy * dy);

			if (away > 3) {
				var facing:Float = (dx * sim.player.dirFlatX() + dy * sim.player.dirFlatY()) / away;

				if (facing < IN_VIEW) {
					mesh.visible = false;
					continue;
				}
			}

			mesh.visible = true;

			/** A dummy darkens as it takes hits, which is the only sign it gives that it noticed. */
			if (body.dummy) {
				var left:Float = Math.max(0, body.health) / body.stock;
				mesh.material.color.set(0.35 + 0.5 * left, 0.3 + 0.45 * left, 0.25 + 0.4 * left);
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
	 * How far it moved rather than where it is, which is what `captureMouse(true)` asked for. Reading
	 * a captured pointer's position would answer the middle of the window every frame, since holding
	 * it there is what stops it leaving.
	 *
	 * @param dx How far across, in window pixels.
	 * @param dy How far down, in window pixels.
	 */
	override public function onMouseLook(dx:Float, dy:Float):Void {
		if (sim == null) {
			return;
		}

		var steady:Float = 1 - (1 - AIM_STEADY) * sighted;
		sim.player.look(dx * SENSITIVITY * steady, dy * SENSITIVITY * steady);
	}

	/**
	 * The pointer went down, which fires on the next frame rather than here, so a shot and the step
	 * that follows it are always in that order.
	 *
	 * @param x Where, in the project's own canvas.
	 * @param y Where, in the project's own canvas.
	 */
	override public function onMouseDown(x:Float, y:Float):Void {}

	/**
	 * Left holds the trigger, right raises the sights.
	 *
	 * Both edges matter, which is why this is here rather than in `onMouseDown`: a button that is
	 * only ever reported going down can start automatic fire and never stop it.
	 *
	 * @param button Which one: 0 is left, 1 is right.
	 * @param down True when it went down.
	 * @param x Where, in the project's own canvas.
	 * @param y Where, in the project's own canvas.
	 */
	override public function onMouseButton(button:Int, down:Bool, x:Float, y:Float):Void {
		if (button == 0) {
			firing = down;
		} else if (button == 1) {
			sighting = down;
		}
	}
}
