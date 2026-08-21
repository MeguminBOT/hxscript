package hxscript.runtime;

/**
 * The table holding one interpreter's top-level names, and the one place a write to one is seen.
 *
 * A `Map` in every way that matters, since `set`, `get`, `exists`, `remove`, `clear` and iteration
 * all read the same, with one thing added: a write tells whoever is holding that name somewhere
 * faster.
 *
 * **Compiled code cannot afford to ask.** A host-bound name read through the interpreter costs a
 * call and two map lookups, about ninety nanoseconds, where the same name read out of a real typed
 * static costs two. Keeping a copy in a static is only sound if every write reaches it, and a host
 * writes this table directly: `module.variables.set('damage', 99)` is documented and ordinary. So the
 * table itself is what notices, rather than each of the several paths that reach it.
 *
 * The alternative was a `rebind` call for hosts to remember, which fails the moment somebody forgets
 * and leaves compiled code reading a value the interpreter has already moved past. That divergence
 * is the thing this whole area exists to avoid.
 */
@:allow(hxscript.runtime.Interp)
class Bindings {
	/** The names and their values. */
	var held:Map<String, Dynamic>;

	/**
	 * The interpreter these belong to, or null for a table nothing compiled reads.
	 *
	 * Only set once a compiled module has bound against it, so a world that never compiles pays
	 * nothing for any of this beyond a null check per write.
	 */
	var watcher:Null<Interp> = null;

	/**
	 * A table to fall back to for a name this one does not hold.
	 *
	 * **What a scripted instance stands on instead of a copy.** Every instance of a scripted class
	 * used to be handed its own copy of the class's whole table, so a host binding fifty values into
	 * its scripts made every object it spawned fifty inserts more expensive: 5.7us to construct at
	 * eight bound values and 12.9us at fifty-eight, growing without limit as the script API grew.
	 * The more useful the API, the slower the game.
	 *
	 * Reads fall through, writes never do. An instance assigning to a name the class also holds gets
	 * its own entry from that moment, which is exactly what copying gave it, so nothing about what a
	 * script observes changes.
	 */
	public var fallback:Null<Bindings> = null;

	/**
	 * How many times this table has changed.
	 *
	 * For a caller that has worked something out from what the table said and wants to know whether
	 * it is still true. `Interp` resolves a declared type against `imports` on every typed write, and
	 * remembering the answer is only sound while the table it was read from has not moved.
	 */
	public var version(default, null):Int = 0;

	/**
	 * One level deep, which is every chain there is: an instance falls back to its class, and a class
	 * carries its own table rather than falling back to its module.
	 *
	 * @return A number that changes whenever this table or the one it falls back to does.
	 */
	public inline function stamp():Int {
		return fallback == null ? version : version + fallback.version;
	}

	/**
	 * @param from Existing names to start from, or null for an empty table.
	 */
	public function new(?from:Map<String, Dynamic>) {
		held = from == null ? new Map() : from;
	}

	/**
	 * Stores a name, and tells anything holding it faster.
	 *
	 * **Only a write tells.** Dropping a name is not a change of what it holds, it is the name ceasing
	 * to be there, and a copy has no way to say that: a slot holds an `Int` and there is no `Int` that
	 * means "gone". Reporting it as a type change would also make `clear` fatal, and `setDefaults`
	 * calls `clear` on every interpreter reset. So a copy keeps the last value it was given until
	 * something writes the name again, and a host that removes a name compiled code reads gets a read
	 * that answers what it last held rather than the `Unknown identifier` an interpreted read gives.
	 * Removing such a name is not something a host has reason to do between a compile and a run.
	 *
	 * @param name The name.
	 * @param value Its value.
	 */
	public inline function set(name:String, value:Dynamic):Void {
		/**
		 * Told before the table is written, so a write it refuses leaves nothing half-applied: the
		 * copy and the table would otherwise disagree for as long as the throw was caught.
		 */
		if (watcher != null)
			Globals.wrote(watcher, name, value);

		version++;
		held.set(name, value);
	}

	/**
	 * @param name The name.
	 * @return Its value, or null when the table does not hold it.
	 */
	public function get(name:String):Dynamic {
		var mine:Dynamic = held.get(name);

		if (mine == null && fallback != null && !held.exists(name))
			return fallback.get(name);

		return mine;
	}

	/**
	 * @param name The name.
	 * @return Whether the table holds it.
	 */
	public function exists(name:String):Bool {
		return held.exists(name) || (fallback != null && fallback.exists(name));
	}

	/**
	 * @param name The name to drop.
	 * @return Whether it was there.
	 */
	public function remove(name:String):Bool {
		version++;
		return held.remove(name);
	}

	/** Drops every name. */
	public function clear():Void {
		version++;
		held.clear();
	}

	/** @return The names, this table's own and whatever it falls back to. */
	public function keys():Iterator<String> {
		return flat().keys();
	}

	/** @return The values, so `for (v in variables)` reads as it does over a map. */
	public function iterator():Iterator<Dynamic> {
		return flat().iterator();
	}

	/** @return Name and value together, so `for (k => v in variables)` reads as it does over a map. */
	public function keyValueIterator():KeyValueIterator<String, Dynamic> {
		return flat().keyValueIterator();
	}

	/** @return A plain copy, for a caller that wants the names without the table. */
	public function copy():Map<String, Dynamic> {
		return flat();
	}

	/**
	 * @return Everything this table answers for, as one map, this table's own entries winning.
	 *
	 * Only for walking. A read or a test goes through `get` and `exists`, which follow the fallback
	 * without building anything; this is what the handful of callers that want every name at once
	 * get, and none of them is on a path that runs per frame.
	 */
	function flat():Map<String, Dynamic> {
		if (fallback == null)
			return held.copy();

		var all:Map<String, Dynamic> = fallback.copy();

		for (k => v in held)
			all.set(k, v);

		return all;
	}

	/** @return The table rendered the way a map renders. */
	public function toString():String {
		return held.toString();
	}
}
