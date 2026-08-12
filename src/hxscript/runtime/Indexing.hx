package hxscript.runtime;

import hxscript.types.AbstractTools;
import hxscript.types.AbstractValue;

/**
 * What `a[i]` means when nothing knew what `a` was.
 *
 * `a[i]` is three different operations in Haxe and which one it is depends on the value: a map is
 * keyed, an array is indexed, and an abstract may declare either through `@:arrayAccess`. The
 * interpreter decides that per evaluation, so a compiled body has to decide it the same way or the
 * two disagree about the same line.
 *
 * Shared rather than written per backend, so every backend answers `a[i]` the same way.
 */
@:keep
class Indexing {
	/**
	 * Reads at an index or a key.
	 *
	 * @param o What is being read from.
	 * @param i The index or key.
	 * @return What was there.
	 */
	public static function get(o:Dynamic, i:Dynamic):Dynamic {
		if (o is haxe.Constraints.IMap)
			return (o : haxe.Constraints.IMap<Dynamic, Dynamic>).get(i);

		if (o is AbstractValue)
			return get(AbstractTools.underlying(o), i);

		if (o is Array)
			return (o : Array<Dynamic>)[toIndex(i)];

		return o[i];
	}

	/**
	 * Stores at an index or a key.
	 *
	 * @param o What is being written to.
	 * @param i The index or key.
	 * @param v What to store.
	 * @return The value stored, because an assignment is an expression.
	 */
	public static function set(o:Dynamic, i:Dynamic, v:Dynamic):Dynamic {
		if (o is haxe.Constraints.IMap) {
			(o : haxe.Constraints.IMap<Dynamic, Dynamic>).set(i, v);
			return v;
		}

		if (o is AbstractValue)
			return set(AbstractTools.underlying(o), i, v);

		if (o is Array) {
			(o : Array<Dynamic>)[toIndex(i)] = v;
			return v;
		}

		o[i] = v;
		return v;
	}

	/** @return An index as an `Int`, opening an abstract to what it wraps first. */
	static function toIndex(i:Dynamic):Int {
		if (i is Int)
			return (i : Int);

		if (i is AbstractValue)
			return toIndex(AbstractTools.underlying(i));

		return i == null ? 0 : Std.int((i : Float));
	}
}
