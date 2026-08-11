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
