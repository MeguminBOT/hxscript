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

		held.set(name, value);
	}

	/**
	 * @param name The name.
	 * @return Its value, or null when the table does not hold it.
	 */
	public inline function get(name:String):Dynamic {
		return held.get(name);
	}

	/**
	 * @param name The name.
	 * @return Whether the table holds it.
	 */
	public inline function exists(name:String):Bool {
		return held.exists(name);
	}

	/**
	 * @param name The name to drop.
	 * @return Whether it was there.
	 */
	public function remove(name:String):Bool {
		return held.remove(name);
	}

	/** Drops every name. */
	public function clear():Void {
		held.clear();
	}

	/** @return The names, for a caller walking the table. */
	public inline function keys():Iterator<String> {
		return held.keys();
	}

	/** @return The values, so `for (v in variables)` reads as it does over a map. */
	public inline function iterator():Iterator<Dynamic> {
		return held.iterator();
	}

	/** @return Name and value together, so `for (k => v in variables)` reads as it does over a map. */
	public inline function keyValueIterator():KeyValueIterator<String, Dynamic> {
		return held.keyValueIterator();
	}

	/** @return A plain copy, for a caller that wants the names without the table. */
	public function copy():Map<String, Dynamic> {
		return held.copy();
	}

	/** @return The table rendered the way a map renders. */
	public function toString():String {
		return held.toString();
	}
}
