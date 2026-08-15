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
			'walkStopsAtWall', 'strafeIsSideways', 'airKeepsMomentum', 'airCannotOutrunWalking', 'jumpLands',
			'boxesPartCompany', 'boxesStack', 'playerShovesBox', 'shotsCounted', 'dummyTakesHits', 'dummyReturns', 'standsOnRoof', 'stoppedByWall', 'stepsOverALip', 'sprintIsFaster', 'crouchLowersAndSlows', 'entryBuilds',
			'brokenTargetsReturn', 'downedDummyReturns', 'recoilClimbs', 'pullingDownEatsTheRecovery', 'missesLandOnTheWall', 'landingIsOnTheShot', 'sprayCanMiss'
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
			sim.step(1 / 60);
		}

		var inside:Bool = sim.player.y <= Sim.ROOM && sim.player.y > 0;
		return 'inside ' + inside;
	}

	/**
	 * Strafing goes across what the player faces, and the two directions are opposites.
	 *
	 * Which of them is the right of the picture is decided by `Player.HAND` and cannot be asked here,
	 * because a screen is the only thing that answers it. What can be asked is the part that is
	 * arithmetic: that sideways is square to forwards, and that A and D disagree. A strafe that had
	 * drifted into the forward direction would show up here; one that is merely mirrored would not,
	 * and that one is written down where the constant is.
	 */
	public static function strafeIsSideways():Dynamic {
		var right:Sim = new Sim();
		var left:Sim = new Sim();

		for (i in 0...30) {
			right.player.walk(0, 1, 1 / 60);
			right.step(1 / 60);

			left.player.walk(0, -1, 1 / 60);
			left.step(1 / 60);
		}

		var dxr:Float = right.player.x;
		var dyr:Float = right.player.y - (-6);

		/** Facing along positive y at the start, so a pure strafe changes x and leaves y alone. */
		var square:Bool = Math.abs(dyr) < 0.0001 && Math.abs(dxr) > 1;
		var opposed:Bool = (right.player.x > 0) != (left.player.x > 0);

		return 'square ' + square + ' opposed ' + opposed;
	}

	/**
	 * A jump forward keeps going forward while it is steered sideways.
	 *
	 * The case this whole arrangement exists for. Movement used to write straight to the position,
	 * so a jump carried nothing: the forward part of it lasted exactly as long as forward was held,
	 * and a touch of strafe in the air replaced the leap with a sideways shuffle. Speed is kept now
	 * and the position follows from it.
	 */
	public static function airKeepsMomentum():Dynamic {
		var sim:Sim = new Sim();

		/** Facing along positive y, running up to speed on the ground first. */
		sim.player.yaw = Math.PI * 0.5;

		for (i in 0...30) {
			sim.player.walk(1, 0, 1 / 60);
			sim.step(1 / 60);
		}

		var launch:Float = sim.player.vy;
		sim.player.jump();

		/** Nothing but strafe from here, which used to be enough to cancel the jump. */
		for (i in 0...25) {
			sim.player.walk(0, 1, 1 / 60);
			sim.step(1 / 60);
		}

		var kept:Bool = sim.player.vy > launch * 0.75;
		var steered:Bool = Math.abs(sim.player.x) > 0.1;

		return 'kept ' + kept + ' steered ' + steered;
	}

	/** Holding forward in mid air adds nothing, because the run was already faster than the air cap. */
	public static function airCannotOutrunWalking():Dynamic {
		var sim:Sim = new Sim();
		sim.player.yaw = Math.PI * 0.5;

		for (i in 0...30) {
			sim.player.walk(1, 0, 1 / 60);
			sim.step(1 / 60);
		}

		sim.player.jump();

		for (i in 0...40) {
			sim.player.walk(1, 0, 1 / 60);
			sim.step(1 / 60);
		}

		/**
		 * Along the way they were already going, rather than in total. Steering sideways in the air
		 * does add speed across, which is intended and is what placing a landing means; what must not
		 * happen is a jump that runs faster forwards than the run that started it.
		 */
		return 'no faster ' + (sim.player.vy <= Player.WALK + 0.001);
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

	/** Two boxes started inside each other do not stay there. */
	public static function boxesPartCompany():Dynamic {
		var sim:Sim = new Sim();

		var a:Body = new Body(0, 0, 0.5, 0.5);
		var b:Body = new Body(0.2, 0, 0.5, 0.5);

		sim.add(a);
		sim.add(b);

		for (i in 0...120) {
			sim.step(1 / 60);
		}

		var apart:Float = Math.abs(b.x - a.x);
		return 'apart ' + (apart >= 0.98);
	}

	/**
	 * One box dropped on another ends up on top of it rather than beside it.
	 *
	 * The reason the overlap is resolved along the axis it is least on. Pushing apart along whichever
	 * axis came first would shoot the upper box sideways out from under itself, which is the usual
	 * way a stack turns into a scatter.
	 */
	public static function boxesStack():Dynamic {
		var sim:Sim = new Sim();

		var under:Body = new Body(0, 0, 0.5, 0.5);
		var over:Body = new Body(0, 0, 2.4, 0.5);

		sim.add(under);
		sim.add(over);

		var steps:Int = 0;
		while (!sim.settled() && steps < 1200) {
			sim.step(1 / 60);
			steps++;
		}

		var above:Bool = over.z > under.z + 0.6;
		var near:Bool = Math.abs(over.x - under.x) < 0.6 && Math.abs(over.y - under.y) < 0.6;

		return 'above ' + above + ' aligned ' + near;
	}

	/** Walking into a box moves it, and it keeps going after the player stops. */
	public static function playerShovesBox():Dynamic {
		var sim:Sim = new Sim();

		var crate:Body = new Body(0, -3.6, 0.5, 0.5);
		sim.add(crate);

		/** Standing just short of it, facing along positive y, walking into it. */
		sim.player.yaw = Math.PI * 0.5;
		var before:Float = crate.y;

		for (i in 0...90) {
			sim.player.walk(1, 0, 1 / 60);
			sim.step(1 / 60);
		}

		return 'moved ' + (crate.y > before + 0.2);
	}

	/**
	 * A roof too high to step onto is reached by jumping, and stood on when it is.
	 *
	 * Waist height on purpose. Anything within the step allowance is walked over without noticing,
	 * so it would prove nothing about landing; anything much higher cannot be jumped at all. Stopped
	 * while the player is still over the building, since walking on gets them to the far side and
	 * back down, which is correct and is not what this asks.
	 */
	public static function standsOnRoof():Dynamic {
		var sim:Sim = new Sim();
		sim.build(0, 4, 2.5, 2.5, 1, 0x445566);

		sim.player.yaw = Math.PI * 0.5;

		for (i in 0...150) {
			sim.player.walk(1, 0, 1 / 60);

			/** Jumped as it is reached, which is the only way onto something this tall. */
			if (sim.player.y > 0.6 && sim.player.onGround) {
				sim.player.jump();
			}

			sim.step(1 / 60);

			if (sim.player.y > 4) {
				break;
			}
		}

		var up:Bool = sim.player.z > Player.EYE + 0.9;
		return 'raised ' + up + ' grounded ' + sim.player.onGround;
	}

	/** A tall building is walked into rather than through. */
	public static function stoppedByWall():Dynamic {
		var sim:Sim = new Sim();
		sim.build(0, 6, 3, 1, 6, 0x445566);

		sim.player.yaw = Math.PI * 0.5;

		for (i in 0...300) {
			sim.player.walk(1, 0, 1 / 60);
			sim.step(1 / 60);
		}

		var short:Bool = sim.player.y < 5;
		var down:Bool = sim.player.z < Player.EYE + 0.1;

		return 'stopped ' + short + ' onFloor ' + down;
	}

	/**
	 * A kerb is walked over rather than into.
	 *
	 * Without a step allowance every join in the ground is a wall, and a player stops dead at
	 * something they should not have noticed.
	 */
	public static function stepsOverALip():Dynamic {
		var sim:Sim = new Sim();
		sim.build(0, 4, 3, 3, 0.3, 0x445566);

		sim.player.yaw = Math.PI * 0.5;

		/** Stopped while still on it, since walking on takes the player off the far side. */
		for (i in 0...200) {
			sim.player.walk(1, 0, 1 / 60);
			sim.step(1 / 60);

			if (sim.player.y > 3) {
				break;
			}
		}

		var climbed:Bool = sim.player.y > 1;
		return 'past ' + climbed + ' atop ' + (Math.abs(sim.player.z - (Player.EYE + 0.3)) < 0.02);
	}

	/** Sprinting covers more ground in the same time than walking does. */
	public static function sprintIsFaster():Dynamic {
		var walked:Float = travel(false, false);
		var run:Float = travel(true, false);

		return 'faster ' + (run > walked * 1.4);
	}

	/** Crouching lowers the eyes and slows the legs, and lets go again. */
	public static function crouchLowersAndSlows():Dynamic {
		var crept:Float = travel(false, true);
		var walked:Float = travel(false, false);

		var sim:Sim = new Sim();
		sim.player.crouching = true;

		for (i in 0...60) {
			sim.step(1 / 60);
		}

		var down:Bool = sim.player.z < Player.EYE - 0.5;

		sim.player.crouching = false;

		for (i in 0...60) {
			sim.step(1 / 60);
		}

		return 'lower ' + down + ' slower ' + (crept < walked * 0.7) + ' up ' + (sim.player.z > Player.EYE - 0.05);
	}

	/**
	 * @param sprinting Whether to hold sprint.
	 * @param crouching Whether to hold crouch.
	 * @return How far the player gets in a second of walking forwards.
	 */
	static function travel(sprinting:Bool, crouching:Bool):Float {
		var sim:Sim = new Sim();
		sim.player.yaw = Math.PI * 0.5;
		sim.player.sprinting = sprinting;
		sim.player.crouching = crouching;

		/** Settled into the stance first, so the measurement is of the posture and not of reaching it. */
		for (i in 0...30) {
			sim.step(1 / 60);
		}

		var from:Float = sim.player.y;

		for (i in 0...60) {
			sim.player.walk(1, 0, 1 / 60);
			sim.step(1 / 60);
		}

		return sim.player.y - from;
	}

	/** A dummy takes a hit and stays standing, which is the third answer to being shot. */
	public static function dummyTakesHits():Dynamic {
		var sim:Sim = new Sim();

		var stand:Body = new Body(0, 4, 1.7, 0.7);
		stand.dummy = true;
		stand.health = 5;
		sim.add(stand);

		sim.shoot();
		sim.shoot();

		return 'health ' + stand.health + ' whole ' + stand.alive + ' pieces ' + (sim.bodies.length - 1);
	}

	/** Knocked back by a hit, and back where it stands a moment later. */
	public static function dummyReturns():Dynamic {
		var sim:Sim = new Sim();

		var stand:Body = new Body(0, 4, 1.7, 0.7);
		stand.dummy = true;
		sim.add(stand);

		sim.shoot();
		var rocked:Bool = stand.y > 4.05;

		for (i in 0...90) {
			sim.step(1 / 60);
		}

		return 'rocked ' + rocked + ' back ' + (Math.abs(stand.y - 4) < 0.02);
	}

	/**
	 * The class this project actually runs can be built at all.
	 *
	 * **The gap every other case here leaves.** A conformance pass compiles every script and then
	 * runs only the classes declaring `cases`, so `Sim` was covered thoroughly and `Shooter` was not
	 * covered at all: it shipped twice in a state where it could not start, and both times this
	 * reported that everything agreed.
	 *
	 * Constructing it is enough to catch that class of failure, because building a scripted class is
	 * what checks it against the base it extends. An `override` naming a method the host does not
	 * have fails here, which is exactly what happened when `onMouseButton` was added to
	 * `host.Project` and the binary was not rebuilt.
	 *
	 * `start` is deliberately not called: it needs a scene, and a run without a window has none. What
	 * this covers is that the class is buildable, not that it draws.
	 */
	public static function entryBuilds():Dynamic {
		var made:Shooter = new Shooter();
		return 'built ' + (made != null) + ' titled ' + made.title;
	}

	/** The tally the interface shows, which is a fact about the room rather than about the drawing. */
	public static function shotsCounted():Dynamic {
		var sim:Sim = room();

		sim.shoot();

		sim.player.yaw = -Math.PI * 0.5;
		sim.shoot();

		return sim.shots + ' shots ' + sim.hits + ' hits';
	}

	/**
	 * A broken target comes back after its minute, and takes its own wreckage with it.
	 *
	 * Asleep when it is added, because that is how the room builds its targets: they hang in the air
	 * to be shot at rather than lying on the floor. Which is the whole reason the resting state is
	 * recorded and restored, and this is the case that would fail if it were not.
	 */
	public static function brokenTargetsReturn():Dynamic {
		var sim:Sim = new Sim();

		var mark:Body = new Body(0, 2, 1.7, 0.6);
		mark.breakable = true;
		mark.asleep = true;
		sim.add(mark);

		sim.shoot();

		var broke:Bool = !mark.alive;
		var made:Int = sim.bodies.length - 1;

		for (i in 0...3720) {
			sim.step(1 / 60);
		}

		var loose:Int = 0;

		for (body in sim.bodies) {
			if (body.alive && body.debris) {
				loose++;
			}
		}

		var home:Bool = Math.abs(mark.x) < 0.001 && Math.abs(mark.y - 2) < 0.001 && Math.abs(mark.z - 1.7) < 0.001;

		return 'broke ' + broke + ' pieces ' + made + ' back ' + mark.alive + ' home ' + home + ' loose ' + loose;
	}

	/** A dummy with nothing left goes down, and is standing again a minute later with all of it back. */
	public static function downedDummyReturns():Dynamic {
		var sim:Sim = new Sim();

		var stand:Body = new Body(0, 4, 1.7, 0.7);
		stand.dummy = true;
		sim.add(stand);

		for (i in 0...5) {
			sim.shoot();
		}

		var down:Bool = !stand.alive;

		for (i in 0...3720) {
			sim.step(1 / 60);
		}

		return 'down ' + down + ' back ' + stand.alive + ' health ' + stand.health + ' where '
			+ Math.round(stand.y * 100);
	}

	/** Firing throws the aim up, and it comes back down on its own. */
	public static function recoilClimbs():Dynamic {
		var sim:Sim = new Sim();
		var p:Player = sim.player;

		p.kick(Player.KICK);
		p.kick(Player.KICK);

		var up:Bool = p.pitch > 0.04;

		for (i in 0...120) {
			sim.step(1 / 60);
		}

		return 'up ' + up + ' rested ' + (Math.abs(p.pitch) < 0.0005);
	}

	/**
	 * Pulling down against the kick is not paid for twice.
	 *
	 * The failure this rules out is a view that dips below where the player put it: they correct the
	 * climb by hand, the automatic recovery still believes it owes the same amount, and takes it
	 * again a fraction of a second later.
	 */
	public static function pullingDownEatsTheRecovery():Dynamic {
		var sim:Sim = new Sim();
		var p:Player = sim.player;

		p.kick(0.1);
		p.look(0, 0.1);

		var level:Bool = Math.abs(p.pitch) < 0.0001;

		for (i in 0...120) {
			sim.step(1 / 60);
		}

		return 'level ' + level + ' stayed ' + (Math.abs(p.pitch) < 0.0001) + ' owed ' + (p.owed < 0.0001);
	}

	/** A shot that hits nothing still lands somewhere, because the room has walls. */
	public static function missesLandOnTheWall():Dynamic {
		var sim:Sim = new Sim();
		var found:Body = sim.pick(0, 0, 4, 0, 1, 0);

		return 'hit ' + (found != null) + ' range ' + Math.round(sim.range * 100) + ' at '
			+ Math.round(sim.hitY * 100) + ' high ' + Math.round(sim.hitZ * 100);
	}

	/** Where a shot lands is on the line it was fired along, which is what the streak is drawn to. */
	public static function landingIsOnTheShot():Dynamic {
		var sim:Sim = room();
		var p:Player = sim.player;

		sim.shootAlong(p.dirX(), p.dirY(), p.dirZ());

		var offX:Float = sim.hitX - (p.x + p.dirX() * sim.range);
		var offY:Float = sim.hitY - (p.y + p.dirY() * sim.range);

		return 'on ' + (Math.abs(offX) < 0.0001 && Math.abs(offY) < 0.0001) + ' short ' + (sim.range < 9);
	}

	/**
	 * A shot pushed off the aim misses what a straight one hits, which is what a cone is for.
	 *
	 * Ten degrees, far wider than the gun ever opens, because the point is that the direction is
	 * honoured rather than that the spread is a particular size. The size lives with the trigger.
	 */
	public static function sprayCanMiss():Dynamic {
		var sim:Sim = room();
		var p:Player = sim.player;

		var straight:Bool = sim.pick(p.x, p.y, p.z, p.dirX(), p.dirY(), p.dirZ()) != null;

		var lean:Float = 0.175;
		var hit:Body = sim.shootAlong(Math.sin(lean), Math.cos(lean), 0);

		return 'straight ' + straight + ' leaning ' + (hit != null) + ' shots ' + sim.shots;
	}
}
