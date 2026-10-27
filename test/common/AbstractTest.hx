import hxscript.Script;
import TestCase.ok;

/**
 * Native abstracts seen from a script: construction, field and static access, method calls, and
 * `@:op` operator dispatch. Every operator case is asserted against the value native Haxe produces
 * for the same expression, since matching Haxe is the whole point.
 */
class AbstractTest {
	/**
	 * Runs a script expression and returns its value as a string, so a thrown error is reported
	 * rather than aborting the run.
	 *
	 * @param body The expression to evaluate.
	 * @return The result of `Std.string` on the value, or `threw: <error>`.
	 */
	static function eval(body:String):String {
		var s = new Script("res = 'no result'; try { res = Std.string(" + body + "); } catch (e:Dynamic) { res = 'threw: ' + e; }", "abs");
		s.onProgramError = function(e:haxe.Exception) {};
		s.start();
		return s.variables.get("res");
	}

	/**
	 * Asserts that a script expression evaluates to an expected string.
	 *
	 * @param name What is being checked.
	 * @param body The script expression.
	 * @param want The expected result.
	 */
	static function is(name:String, body:String, want:String):Void {
		var got:String = eval(body);
		if (got != want)
			trace("       got " + got + ", wanted " + want);
		ok(name, got == want);
	}

	/**
	 * Asserts that a script expression produces what native Haxe produced for the same expression.
	 *
	 * @param name What is being checked.
	 * @param body The script expression.
	 * @param native The value native Haxe computed.
	 */
	static function same(name:String, body:String, native:Dynamic):Void {
		var got:String = eval(body);
		var want:String = Std.string(native);
		if (got != want)
			trace("       got " + got + ", native Haxe gives " + want);
		ok(name, got == want);
	}

	public static function run():Void {
		trace("-- abstracts --");

		var a:OpVec = 1;
		var b:OpVec = 2;

		ok("cast constructs", eval("{ var v:OpVec = cast 7; v.raw; }") == "7");
		ok("cast() constructs", eval("cast(7, OpVec).raw") == "7");
		ok("cast() without a type constructs", eval("{ var v:OpVec = cast(7); v.raw; }") == "7");
		ok("property reads", eval("{ var v:OpVec = cast 7; v.raw; }") == "7");
		ok("static reads", eval("OpVec.ZERO.raw") == "0");
		ok("method call", eval("{ var x:OpVec = cast 1; var y:OpVec = cast 2; x.add(y).raw; }") == "21");

		// @:op dispatch. Each fixture operator returns something plain Int arithmetic would not, so
		// these fail loudly if the interpreter falls back to the boxed value instead of dispatching.
		same("a + b dispatches", "{ var x:OpVec = cast 1; var y:OpVec = cast 2; (x + y).raw; }", (a + b).raw);
		same("a - b dispatches", "{ var x:OpVec = cast 5; var y:OpVec = cast 2; (x - y).raw; }", ((5 : OpVec) - (2 : OpVec)).raw);
		same("a * b dispatches", "{ var x:OpVec = cast 3; var y:OpVec = cast 4; (x * y).raw; }", ((3 : OpVec) * (4 : OpVec)).raw);
		same("a == b dispatches", "{ var x:OpVec = cast 5; var y:OpVec = cast 6; x == y; }", (5 : OpVec) == (6 : OpVec));
		same("a > b dispatches", "{ var x:OpVec = cast 1; var y:OpVec = cast 9; x > y; }", (1 : OpVec) > (9 : OpVec));

		// `!=` has no fixture operator; Haxe derives it from `==`, and so does the interpreter.
		same("a != b negates ==", "{ var x:OpVec = cast 5; var y:OpVec = cast 9; x != y; }", (5 : OpVec) != (9 : OpVec));

		// No `@:op(A < B)`. Haxe rejects this at compile time even with an implicit cast to the
		// underlying type available, so there is no native result to match; the interpreter is
		// deliberately permissive and falls back to the boxed values.
		ok("a < b falls back", eval("{ var x:OpVec = cast 1; var y:OpVec = cast 9; x < y; }") == "true");

		ok("a += b dispatches", eval("{ var x:OpVec = cast 1; var y:OpVec = cast 2; x += y; x.raw; }") == "21");

		// An abstract with no operators at all must compare and combine on what it boxes. Comparing
		// the wrappers would compare identity and report two equal values as different.
		same("bare == compares values", "{ var x:OpBare = cast 5; var y:OpBare = cast 5; x == y; }", (5 : OpBare) == (5 : OpBare));
		same("bare != compares values", "{ var x:OpBare = cast 5; var y:OpBare = cast 6; x != y; }", (5 : OpBare) != (6 : OpBare));
		// Arithmetic and ordering on an operator-free abstract are likewise rejected by Haxe, and
		// likewise fall back here.
		ok("bare + falls back", eval("{ var x:OpBare = cast 2; var y:OpBare = cast 3; x + y; }") == "5");
		ok("bare < falls back", eval("{ var x:OpBare = cast 2; var y:OpBare = cast 3; x < y; }") == "true");

		// Mixing an abstract with a plain value: the operator method takes the abstract's own type,
		// so the boxed value is what the fallback combines.
		ok("abstract + Int falls back", eval("{ var x:OpBare = cast 2; x + 3; }") == "5");

		// An abstract on the *right*. Haxe needs `@:commutative` to accept these at all, but getting
		// them wrong here is not a compile error, it is a silently wrong number: before the operands
		// were both checked, hxcpp coerced the wrapper through `(b : Float)` and `1 * vec` gave 0.
		ok("Int + abstract dispatches", eval("{ var y:OpVec = cast 2; (1 + y).raw; }") == "12");
		ok("Int * abstract dispatches", eval("{ var y:OpVec = cast 2; (1 * y).raw; }") == "3");
		ok("Int - abstract falls back", eval("{ var y:OpVec = cast 2; 1 - y; }") == "-1");
		ok("Int < abstract falls back", eval("{ var y:OpVec = cast 2; 1 < y; }") == "true");
		ok("Int == abstract compares values", eval("{ var y:OpVec = cast 1; 1 == y; }") == "true");

		// Unary operators and array access. Haxe accepts `-a` and `!a` here because the fixture
		// declares them; `a[i]` goes through `@:arrayAccess`.
		same("-a dispatches", "{ var x:OpVec = cast 5; (-x).raw; }", (-(5 : OpVec)).raw);
		same("!a dispatches", "{ var x:OpVec = cast 5; !x; }", !(5 : OpVec));
		same("a[i] dispatches", "{ var x:OpVec = cast 5; x[3]; }", (5 : OpVec)[3]);

		// The operator-free abstract has none of these, so each falls back to the boxed value.
		ok("-a falls back", eval("{ var x:OpBare = cast 5; -x; }") == "-5");
		ok("!a falls back", eval("{ var x:OpBare = cast 5; !x; }") == "true");
		ok("a[i] falls back", eval("{ var x:OpBare = cast 5; x[3]; }") == "null");

		// A fixture shaped like flixel's FlxColor, which is what a host actually opts in. Inline
		// statics are the interesting part: they have no runtime form, so only the generated wrapper
		// can expose them.
		trace("-- abstract shaped like FlxColor --");
		var keep:OpColor = OpColor.RED;
		is("inline static constant", "OpColor.RED.toHexString()", OpColor.RED.toHexString());
		is("channel property", "OpColor.RED.red", Std.string(OpColor.RED.red));
		is("read-only property", "OpColor.RED.alpha", Std.string(OpColor.RED.alpha));
		is("operator on constants", "(OpColor.RED + OpColor.BLUE).toHexString()", (OpColor.RED + OpColor.BLUE).toHexString());
		is("from Int", "{ var c:OpColor = 16711680; c.red; }", Std.string(((16711680 : OpColor)).red));
		ok("property write", eval("{ var c:OpColor = OpColor.BLUE; c.red = 255; c.red; }") == "255");

		// A box the script never asked for should not leak into output. Without this, every
		// `trace(someColor)` in a script prints the wrapper's class name instead of the value.
		is("prints as its value", "OpColor.RED", Std.string(OpColor.RED));
		is("concatenates as its value", "'c=' + OpColor.RED", "c=" + Std.string(OpColor.RED));
		is("a declared toString still wins", "{ var v:OpVec = cast 5; Std.string(v); }", "V5");

		// `@:forward` on a compiled abstract: fields of the boxed value, reachable through it.
		trace("-- @:forward on a compiled abstract --");
		var keepName:OpName = 'ada';
		is("forwarded property", "{ var n:OpName = 'ada'; n.length; }", Std.string(('ada' : OpName).length));
		is("forwarded method", "{ var n:OpName = 'ada'; n.toUpperCase(); }", ('ada' : OpName).toUpperCase());
		is("own method still wins", "{ var n:OpName = 'ada'; n.shout(); }", ('ada' : OpName).shout());
		ok("unlisted field does not forward", eval("{ var n:OpName = 'ada'; n.charAt(0); }").indexOf("threw") == 0);

	}

	static function main():Void {
		run();
		TestCase.exit();
	}
}
