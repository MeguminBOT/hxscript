/**
 * The room's rules, asked without a room.
 *
 * `--conform fps` runs each of these interpreted and again compiled and compares. Nothing here
 * builds a scene or needs a window, because `Sim` was written so it would not have to: every case
 * makes a room, steps it, and reads a number back.
 *
 * **This is the half the earlier examples could not have.** A scene graph that draws nothing is
 * still a correct scene graph, so a conformance pass could only ever say that a 3D project compiled.
 * Physics is arithmetic over time, so it can be asked whether it is right.
 */
class SelfTest {
	public static function cases():Array<String> {
		return [
			'aimHits', 'aimMisses', 'nearestWins', 'breaks', 'debrisSettles', 'crateIsPushed', 'crateKeepsDirection',
			'walkStopsAtWall', 'jumpLands', 'shotsCounted'
		];
	}

	/**
	 * A room with one target straight ahead of where the player starts.
	 *
	 * @return The world, ready to be shot at.
	 */
	static function room():Sim {
		var sim:Sim = new Sim();

		var mark:Body = new Body(0, 2, 1.7, 0.6);
		mark.breakable = true;
		sim.add(mark);

		return sim;
	}

	/** Looking at a target and asking what is in front, which is every shot this game fires. */
	public static function aimHits():Dynamic {
		var sim:Sim = room();
		var hit:Body = sim.pick(sim.player.x, sim.player.y, sim.player.z, sim.player.dirX(), sim.player.dirY(),
			sim.player.dirZ());

		return 'hit ' + (hit != null);
	}

	/** The same shot turned around, which must find nothing rather than the nearest anything. */
	public static function aimMisses():Dynamic {
		var sim:Sim = room();
		sim.player.yaw = -Math.PI * 0.5;

		var hit:Body = sim.pick(sim.player.x, sim.player.y, sim.player.z, sim.player.dirX(), sim.player.dirY(),
			sim.player.dirZ());

		return 'hit ' + (hit != null);
	}

	/** Two in a line: the near one is hit and the far one is not, which is what a ray is for. */
	public static function nearestWins():Dynamic {
		var sim:Sim = new Sim();

		var near:Body = new Body(0, 2, 1.7, 0.5);
		near.tint = 0x111111;
		sim.add(near);

		var far:Body = new Body(0, 6, 1.7, 0.5);
		far.tint = 0x222222;
		sim.add(far);

		var hit:Body = sim.pick(0, -6, 1.7, 0, 1, 0);
		return 'tint ' + (hit == null ? 'none' : StringTools.hex(hit.tint));
	}

	/** A shot target stops being one and leaves pieces behind. */
	public static function breaks():Dynamic {
		var sim:Sim = room();
		var before:Int = sim.standing();

		sim.shoot();

		return 'was ' + before + ' now ' + sim.standing() + ' pieces ' + (sim.bodies.length - 1);
	}

	/**
	 * The pieces fall, stop, and stay on the floor.
	 *
	 * Stepped until nothing is moving rather than for a fixed count, so this measures that the room
	 * settles at all. A body that never sleeps would run this to its limit and report it.
	 */
	public static function debrisSettles():Dynamic {
		var sim:Sim = room();
		sim.shoot();

		var steps:Int = 0;
		while (!sim.settled() && steps < 2000) {
			sim.step(1 / 60);
			steps++;
		}

		var lowest:Float = 999.0;
		var above:Bool = true;

		for (body in sim.bodies) {
			if (!body.alive) {
				continue;
			}

			if (body.z < lowest) {
				lowest = body.z;
			}

			if (body.z < body.half - 0.001) {
				above = false;
			}
		}

		return 'settled ' + sim.settled() + ' onFloor ' + above + ' under ' + (steps < 2000);
	}

	/** A crate takes the shot as a push rather than coming apart. */
	public static function crateIsPushed():Dynamic {
		var sim:Sim = new Sim();

		var crate:Body = new Body(0, 2, 0.5, 0.5);
		sim.add(crate);

		/**
		 * Aimed down at it, because a crate on the floor is below the eyes and a shot fired level
		 * goes over the top of one. This case reported a crate that would not move until it said so.
		 */
		sim.player.pitch = Math.atan2(crate.z - sim.player.z, crate.y - sim.player.y);

		var before:Float = crate.y;
		sim.shoot();

		for (i in 0...20) {
			sim.step(1 / 60);
		}

		return 'whole ' + crate.alive + ' hit ' + (sim.hits == 1) + ' moved ' + (crate.y > before);
	}

	/**
	 * Shot from the other side, it goes the other way.
	 *
	 * The direction rather than the distance, because the distance is a number somebody may want to
	 * tune and the direction is the part that is either right or a bug.
	 */
	public static function crateKeepsDirection():Dynamic {
		var sim:Sim = new Sim();

		var crate:Body = new Body(0, 2, 0.5, 0.5);
		sim.add(crate);

		/** Standing beyond it, looking back towards the middle and down at the floor. */
		sim.player.y = 6;
		sim.player.yaw = -Math.PI * 0.5;
		sim.player.pitch = Math.atan2(crate.z - sim.player.z, sim.player.y - crate.y);

		sim.shoot();

		for (i in 0...20) {
			sim.step(1 / 60);
		}

		return 'hit ' + (sim.hits == 1) + ' pushed back ' + (crate.y < 2);
	}

	/** Walking into a wall stops at it, so the camera cannot end up outside the room. */
	public static function walkStopsAtWall():Dynamic {
		var sim:Sim = new Sim();
		sim.player.yaw = Math.PI * 0.5;

		for (i in 0...600) {
			sim.player.walk(1, 0, 1 / 60);
		}

		var inside:Bool = sim.player.y <= Sim.ROOM && sim.player.y > 0;
		return 'inside ' + inside;
	}

	/** A jump comes back down and lands exactly on the floor rather than near it. */
	public static function jumpLands():Dynamic {
		var sim:Sim = new Sim();
		sim.player.jump();

		var rose:Bool = false;

		for (i in 0...400) {
			sim.step(1 / 60);

			if (sim.player.z > Player.EYE + 0.5) {
				rose = true;
			}
		}

		return 'rose ' + rose + ' landed ' + sim.player.onGround + ' at ' + sim.player.z;
	}

	/** The tally the interface shows, which is a fact about the room rather than about the drawing. */
	public static function shotsCounted():Dynamic {
		var sim:Sim = room();

		sim.shoot();

		sim.player.yaw = -Math.PI * 0.5;
		sim.shoot();

		return sim.shots + ' shots ' + sim.hits + ' hits';
	}
}
