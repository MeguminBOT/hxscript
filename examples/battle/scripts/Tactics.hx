/**
 * Shared numbers the creature scripts read, kept in one place so a balance change is one edit.
 *
 * A plain class with no host superclass, which is the shape a shared helper takes anyway. It was once the
 * only script here the runtime compiler could accept; the creature scripts extend `Entity`, and extending a
 * host class used to be refused. It no longer is, so all of these compile. See the report the program prints
 * at startup, and `Mods.compile`.
 */
class Tactics {
	/** Below this fraction of full health, a creature should be looking for a way out. */
	public static var desperate:Float = 0.35;

	/**
	 * Whether a creature is hurt enough to change what it does.
	 *
	 * @param health What it has left.
	 * @param maxHealth What it started with.
	 * @return Whether it is below the desperate line.
	 */
	public static function cornered(health:Int, maxHealth:Int):Bool {
		if (maxHealth <= 0)
			return false;

		return health / maxHealth < desperate;
	}

	/**
	 * How hard to hit, given how the fight is going.
	 *
	 * A cornered creature swings harder, which is what makes the last few rounds of a fight move.
	 *
	 * @param base The creature's ordinary attack.
	 * @param health What it has left.
	 * @param maxHealth What it started with.
	 * @return The damage to deal.
	 */
	public static function swing(base:Int, health:Int, maxHealth:Int):Int {
		var total:Int = base;
		if (cornered(health, maxHealth))
			total += Std.int(base / 2);

		return total;
	}
}
