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

package hxscript.hl;

#if hxscript_hl
import hxscript.types.AbstractTools;
import hxscript.types.AbstractValue;

/**
 * What compiled code calls for the things it cannot say in instructions.
 *
 * A module HashLink loads gets its own type table, so a `String` or an `Array` built inside one
 * would not be the host's and could not be handed back. Everything that is not a number, a boolean
 * or a class of the batch is therefore a host value held in a `Dynamic`, and most of what a script
 * does to one is an instruction already: `ODynGet` reads a field, `OCallClosure` calls a method.
 *
 * This is the remainder. Each entry is bound into a global the same way a host static is, so
 * reaching one costs a global read and a call rather than anything the emitter has to arrange.
 *
 * The semantics are the interpreter's, deliberately: an operator has to mean the same thing
 * whichever of the two ran it, and the interpreter is where that meaning is already decided. Its
 * own helpers are instance methods on a hot class, so they are mirrored here rather than shared,
 * which keeps a widening of the compiler from moving the interpreter's code around.
 */
@:keep
class Runtime {
	/**
	 * Adds, which is also how strings are joined.
	 *
	 * @param a The left operand.
	 * @param b The right operand.
	 * @return `Int` when both are `Int` and the sum fits, `String` when either is a string,
	 *         otherwise `Float`.
	 */
	public static function add(a:Dynamic, b:Dynamic):Dynamic {
		if (a is Int && b is Int) {
			var wide:Float = (a : Float) + (b : Float);
			var narrow:Int = (a : Int) + (b : Int);
			return (narrow == wide) ? narrow : wide;
		}
		if (a is String || b is String)
			return Std.string(a) + Std.string(b);
		if (a is AbstractValue || b is AbstractValue)
			return arith('+', a, b);
		return (a : Float) + (b : Float);
	}

	/** @return The difference, keeping `Int` when both operands are `Int` and it fits. */
	public static function sub(a:Dynamic, b:Dynamic):Dynamic {
		if (a is Int && b is Int) {
			var wide:Float = (a : Float) - (b : Float);
			var narrow:Int = (a : Int) - (b : Int);
			return (narrow == wide) ? narrow : wide;
		}
		if (a is AbstractValue || b is AbstractValue)
			return arith('-', a, b);
		return (a : Float) - (b : Float);
	}

	/** @return The product, keeping `Int` when both operands are `Int`. */
	public static function mul(a:Dynamic, b:Dynamic):Dynamic {
		if (a is Int && b is Int)
			return (a : Int) * (b : Int);
		if (a is AbstractValue || b is AbstractValue)
			return arith('*', a, b);
		return (a : Float) * (b : Float);
	}

	/** @return The quotient, which Haxe makes a `Float` even for two `Int`s. */
	public static function div(a:Dynamic, b:Dynamic):Dynamic {
		if (a is AbstractValue || b is AbstractValue)
			return arith('/', a, b);
		return (a : Float) / (b : Float);
	}

	/** @return The remainder, keeping `Int` when both operands are `Int`. */
	public static function mod(a:Dynamic, b:Dynamic):Dynamic {
		if (a is Int && b is Int)
			return (a : Int) % (b : Int);
		if (a is AbstractValue || b is AbstractValue)
			return arith('%', a, b);
		return (a : Float) % (b : Float);
	}

	/** @return Whether two values are equal, by the rule the interpreter uses. */
	public static function eq(a:Dynamic, b:Dynamic):Bool {
		if (a is AbstractValue || b is AbstractValue)
			return cmp('==', a, b);
		return a == b;
	}

	/** @return Whether the left orders before the right. */
	public static function lt(a:Dynamic, b:Dynamic):Bool {
		if (a is AbstractValue || b is AbstractValue)
			return cmp('<', a, b);
		return a < b;
	}

	/** @return Whether the left orders before the right or equals it. */
	public static function lte(a:Dynamic, b:Dynamic):Bool {
		if (a is AbstractValue || b is AbstractValue)
			return cmp('<=', a, b);
		return a <= b;
	}

	/** @return Whether the left orders after the right. */
	public static function gt(a:Dynamic, b:Dynamic):Bool {
		if (a is AbstractValue || b is AbstractValue)
			return cmp('>', a, b);
		return a > b;
	}

	/** @return Whether the left orders after the right or equals it. */
	public static function gte(a:Dynamic, b:Dynamic):Bool {
		if (a is AbstractValue || b is AbstractValue)
			return cmp('>=', a, b);
		return a >= b;
	}

	/** @return The value negated, keeping `Int` when it is one. */
	public static function neg(a:Dynamic):Dynamic {
		if (a is Int)
			return -(a : Int);
		if (a is AbstractValue)
			return arith('-', 0, a);
		return -(a : Float);
	}

	/**
	 * @return Whether a value counts as true, which is being `true` and nothing else.
	 *
	 * A condition on a dynamic cannot be cast to a boolean, because a dynamic holding anything but a
	 * boolean would throw rather than answer, and the interpreter answers.
	 */
	public static function truthy(v:Dynamic):Bool {
		return v == true;
	}

	/** @return A value as an `Int`, which is what the bitwise operators take. */
	public static function toInt(v:Dynamic):Int {
		if (v is Int)
			return (v : Int);
		if (v is AbstractValue)
			return toInt(AbstractTools.underlying(v));
		return v == null ? 0 : Std.int((v : Float));
	}

	/** @return A range as a value, which is what `a...b` is outside a `for`. */
	public static function range(low:Dynamic, high:Dynamic):Dynamic {
		return new IntIterator(toInt(low), toInt(high));
	}

	/** @return A new empty array, which is what a literal and a comprehension both start from. */
	public static function array():Dynamic {
		return new Array<Dynamic>();
	}

	/** Appends to an array. */
	public static function push(a:Dynamic, v:Dynamic):Void {
		(a : Array<Dynamic>).push(v);
	}

	/**
	 * Puts a pair in a map, making the map when there is not one yet.
	 *
	 * Which kind of map a literal wants is decided by its first key, and in a comprehension there is
	 * no first key until the loop has run once. Passing the container back rather than making it up
	 * front is what lets both spellings share one path.
	 *
	 * @param into The map so far, or null before there is one.
	 * @param key The key.
	 * @param value The value.
	 * @return The map, which is the one passed in unless this call had to make it.
	 */
	public static function put(into:Dynamic, key:Dynamic, value:Dynamic):Dynamic {
		if (into == null) {
			if (key is String)
				into = new haxe.ds.StringMap<Dynamic>();
			else if (key is Int)
				into = new haxe.ds.IntMap<Dynamic>();
			else if (Reflect.isEnumValue(key))
				into = new haxe.ds.EnumValueMap<Dynamic, Dynamic>();
			else
				into = new haxe.ds.ObjectMap<Dynamic, Dynamic>();
		}

		(into : haxe.Constraints.IMap<Dynamic, Dynamic>).set(key, value);
		return into;
	}

	/** @return A new empty anonymous structure. */
	public static function object():Dynamic {
		return {};
	}

	/** Puts a named field on a value, which is how an object literal is filled. */
	public static function setField(o:Dynamic, name:String, v:Dynamic):Void {
		Reflect.setField(o, name, v);
	}

	/** @return What sits at an index or a key, which is the same spelling over an array and a map. */
	public static function index(o:Dynamic, i:Dynamic):Dynamic {
		if (o is haxe.Constraints.IMap)
			return (o : haxe.Constraints.IMap<Dynamic, Dynamic>).get(i);
		if (o is AbstractValue)
			return index(AbstractTools.underlying(o), i);
		return o[i];
	}

	/**
	 * Stores at an index or a key.
	 *
	 * @return The value stored, because an assignment is an expression.
	 */
	public static function setIndex(o:Dynamic, i:Dynamic, v:Dynamic):Dynamic {
		if (o is haxe.Constraints.IMap) {
			(o : haxe.Constraints.IMap<Dynamic, Dynamic>).set(i, v);
			return v;
		}

		if (o is AbstractValue)
			return setIndex(AbstractTools.underlying(o), i, v);

		o[i] = v;
		return v;
	}

	/**
	 * @return An iterator over a value, by the rule the interpreter uses: an array or a range
	 *         directly, and anything else through its own `iterator` when it has one.
	 */
	public static function iterator(v:Dynamic):Dynamic {
		if (v is Array)
			return (v : Array<Dynamic>).iterator();

		if (v is IntIterator)
			return v;

		var own:Dynamic = Reflect.field(v, 'iterator');
		return own != null ? Reflect.callMethod(v, own, []) : v;
	}

	/** @return A key-value iterator over a value, over maps and arrays alike. */
	public static function pairs(v:Dynamic):Dynamic {
		if (v is haxe.Constraints.IMap)
			return (v : haxe.Constraints.IMap<Dynamic, Dynamic>).keyValueIterator();

		if (v is Array)
			return (v : Array<Dynamic>).keyValueIterator();

		var own:Dynamic = Reflect.field(v, 'keyValueIterator');
		return own != null ? Reflect.callMethod(v, own, []) : v;
	}

	/** @return Whether an iterator has anything left. */
	public static function step(it:Dynamic):Bool {
		return Reflect.callMethod(it, Reflect.field(it, 'hasNext'), []) == true;
	}

	/** @return An iterator's next value. */
	public static function take(it:Dynamic):Dynamic {
		return Reflect.callMethod(it, Reflect.field(it, 'next'), []);
	}

	/**
	 * Runs an arithmetic operator with an abstract on one side or both.
	 *
	 * The abstract's own `@:op` method wins when it declares one. A commutative operator asks the
	 * other operand too, because `1 + metres` is the same method as `metres + 1`. Failing both, the
	 * operands are opened to what they wrap and the operator runs on those.
	 *
	 * @param op The operator symbol.
	 * @param a The left operand.
	 * @param b The right operand.
	 * @return The result.
	 */
	static function arith(op:String, a:Dynamic, b:Dynamic):Dynamic {
		var m:String = AbstractTools.opMethod(a, op);
		if (m != null)
			return Reflect.callMethod(a, Reflect.field(a, m), [b]);

		if (op == '+' || op == '*') {
			m = AbstractTools.opMethod(b, op);
			if (m != null)
				return Reflect.callMethod(b, Reflect.field(b, m), [a]);
		}

		var l:Dynamic = AbstractTools.underlying(a);
		var r:Dynamic = AbstractTools.underlying(b);

		return switch (op) {
			case '+': add(l, r);
			case '-': sub(l, r);
			case '*': mul(l, r);
			case '/': div(l, r);
			default: mod(l, r);
		}
	}

	/**
	 * Orders or compares with an abstract on one side or both.
	 *
	 * Comparing the wrappers themselves would order them by identity, so an abstract declaring the
	 * operator runs its own method and one that does not is opened to what it wraps first.
	 *
	 * @param op The operator symbol.
	 * @param a The left operand.
	 * @param b The right operand.
	 * @return The comparison's result.
	 */
	static function cmp(op:String, a:Dynamic, b:Dynamic):Bool {
		var m:String = AbstractTools.opMethod(a, op);
		if (m != null)
			return Reflect.callMethod(a, Reflect.field(a, m), [b]) == true;

		var l:Dynamic = AbstractTools.underlying(a);
		var r:Dynamic = AbstractTools.underlying(b);

		return switch (op) {
			case '<': l < r;
			case '<=': l <= r;
			case '>': l > r;
			case '>=': l >= r;
			case '!=': l != r;
			default: l == r;
		}
	}
}
#end
