/*
 * Copyright (c) 2026 MeguminBOT (hxScript)
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 * DEALINGS IN THE SOFTWARE.
 */

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
 * Shared rather than written per backend, which is the whole point: HashLink reached for a helper of
 * its own and cppia reached for the array instruction, so a string-keyed map read as an array and
 * asked hxcpp to turn "a" into an index.
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
