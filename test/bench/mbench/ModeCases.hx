/**
 * The benchmark corpus for the three execution modes, identical in all of them.
 *
 * Shaped as modules rather than as loose expressions, which the comparison suite in `xbench` uses.
 * That is forced: the compiler takes class declarations, so a bare `var i = 0; ... i;` has nowhere to
 * go. Every case is therefore one class with a static `run`, and the case body is that method.
 *
 * Every case returns a value the harness knows, so a mode that runs a case without doing the work is
 * caught rather than recorded as infinitely fast. This matters more here than it does across
 * libraries: a compiler that quietly folds a loop away would otherwise post an unbeatable number.
 *
 * The loop count is a parameter and every expected value is derived from it, so the corpus runs at
 * any scale. Counts and accumulators stay inside 32-bit Int at every supported scale, so the answers
 * are exact rather than depending on overflow.
 */
class ModeCases {
	/** Element count of the array `forArray` walks; the loop count decides how many passes it makes. */
	static inline var ARRAY_LEN:Int = 1000;

	/** How many extra variables `callCap20` leaves in scope around its call. */
	static inline var CAPTURED:Int = 20;

	/** `CAPTURED` typed declarations, to sit in scope around a call so it has something to capture. */
	static function fill(k:Int):String {
		var out:StringBuf = new StringBuf();
		for (v in 0...k) {
			out.add('var v$v:Int = $v; ');
		}
		return out.toString();
	}

	/**
	 * Wraps a case body in the module the compiler expects.
	 *
	 * `extra` is anything the case needs beside `run`: helper methods, a second class. It sits inside
	 * the same class unless it starts a new one, which `classNew` and friends do.
	 */
	static function wrap(body:String, extra:String):String {
		return 'package p;\nclass T {\n\tpublic static function run():Dynamic {\n\t\t$body\n\t}\n$extra}\n';
	}

	/**
	 * The corpus scaled to `n` loop iterations.
	 *
	 * @param n Iterations per case. Must be a multiple of `ARRAY_LEN` so `forArray` divides evenly.
	 */
	public static function all(n:Int):Array<Case> {
		var N:String = Std.string(n);
		var last:String = Std.string(n - 1);
		var passes:String = Std.string(Std.int(n / ARRAY_LEN));

		// `switch (i % 3)` maps 0 -> 1, 1 -> 2, anything else -> 3, at the last counter value
		var switchX:String = Std.string(((n - 1) % 3 == 0) ? 1 : (((n - 1) % 3 == 1) ? 2 : 3));

		var out:Array<Case> = [];

		function add(name:String, tier:String, expect:String, body:String, ?extra:String):Void {
			out.push({n: name, t: tier, i: N, x: expect, s: wrap(body, extra == null ? '' : extra)});
		}

		// --- one ordinary operation per iteration ---

		add('noCall', 'op', '0', 'var i:Int = 0; var s:Int = 0; while (i < $N) { s = s; i += 1; } return s;');

		add('loopPlain', 'op', N, 'var i:Int = 0; while (i < $N) { i += 1; } return i;');

		add('postIncr', 'op', N, 'var i:Int = 0; while (i < $N) { i++; } return i;');

		add('arith', 'op', last, 'var i:Int = 0; var s:Int = 0; while (i < $N) { s = i * 2 - i; i += 1; } return s;');

		add('locals', 'op', last, 'var i:Int = 0; var s:Int = 0; while (i < $N) { var a:Int = i; var b:Int = a; s = b; i += 1; } return s;');

		add('blocks', 'op', last, 'var i:Int = 0; var s:Int = 0; while (i < $N) { { var a:Int = i; { s = a; } } i += 1; } return s;');

		add('not', 'op', 'true', 'var i:Int = 0; var b:Bool = false; while (i < $N) { b = !b; i += 1; } return !b;');

		add('neg', 'op', '-' + last, 'var i:Int = 0; var s:Int = 0; while (i < $N) { s = -i; i += 1; } return s;');

		add('index', 'op', last, 'var a:Array<Int> = [0, 1, 2]; var i:Int = 0; var s:Int = 0; while (i < $N) { a[1] = i; s = a[1]; i += 1; } return s;');

		add('indexSet', 'op', last,
			'var a:Array<Int> = [0, 0, 0]; var i:Int = 0; while (i < $N) { a[2] = i; i += 1; } return a[2];');

		add('field', 'op', last, 'var h:Holder = new Holder(); var i:Int = 0; var s:Int = 0; while (i < $N) { h.v = i; s = h.v; i += 1; } return s;',
			'}\nclass Holder {\n\tpublic var v:Int = 0;\n\tpublic function new() {}\n\tpublic function get():Int { return v; }\n');

		add('fieldSet', 'op', last, 'var h:Holder = new Holder(); var i:Int = 0; while (i < $N) { h.v = i; i += 1; } return h.v;',
			'}\nclass Holder {\n\tpublic var v:Int = 0;\n\tpublic function new() {}\n\tpublic function get():Int { return v; }\n');

		add('method', 'op', last, 'var h:Holder = new Holder(); var i:Int = 0; var s:Int = 0; while (i < $N) { h.v = i; s = h.get(); i += 1; } return s;',
			'}\nclass Holder {\n\tpublic var v:Int = 0;\n\tpublic function new() {}\n\tpublic function get():Int { return v; }\n');

		// Evaluated at the last counter value, which is odd whenever the scale is even.
		var ternaryX:String = ((n - 1) % 2 == 0) ? '1' : '2';
		add('ternary', 'op', ternaryX, 'var i:Int = 0; var s:Int = 0; while (i < $N) { s = (i % 2 == 0) ? 1 : 2; i += 1; } return s;');

		add('switch', 'op', switchX,
			'var i:Int = 0; var s:Int = 0; while (i < $N) { switch (i % 3) { case 0: s = 1; case 1: s = 2; default: s = 3; } i += 1; } return s;');

		add('strConcat', 'op', 'x' + last, 'var i:Int = 0; var s:String = ""; while (i < $N) { s = "x" + i; i += 1; } return s;');

		// Double quoted on this side so the host leaves the marker alone; the string inside the script
		// is single quoted, which is what makes the script interpolate it.
		add('strInterp', 'op', 'v' + last, "var i:Int = 0; var s:String = \"\"; while (i < " + N + ") { s = 'v$i'; i += 1; } return s;");

		add('arrayDecl', 'op', last, 'var i:Int = 0; var s:Int = 0; while (i < $N) { var a:Array<Int> = [i, 1, 2]; s = a[0]; i += 1; } return s;');

		// `s` is nullable because `Map.get` is: assigning that to a plain `Int` is an error under
		// typed mode, and the case is meant to measure a map literal rather than a type rule.
		add('mapLiteral', 'op', last,
			'var i:Int = 0; var s:Null<Int> = 0; while (i < $N) { var m:Map<String, Int> = ["a" => i]; s = m.get("a"); i += 1; } return s;');

		add('forRange', 'op', last, 'var s:Int = 0; for (k in 0...$N) { s = k; } return s;');

		add('forArray', 'op', Std.string(ARRAY_LEN - 1),
			'var a:Array<Int> = []; for (k in 0...$ARRAY_LEN) a.push(k); var s:Int = 0; for (p in 0...$passes) { for (v in a) { s = v; } } return s;');

		// --- one call per iteration ---

		add('call0', 'call', '7', 'var i:Int = 0; var s:Int = 0; while (i < $N) { s = f0(); i += 1; } return s;',
			'\tstatic function f0():Int { return 7; }\n');

		add('call1', 'call', '7', 'var i:Int = 0; var s:Int = 0; while (i < $N) { s = f1(7); i += 1; } return s;',
			'\tstatic function f1(a:Int):Int { return a; }\n');

		add('call3', 'call', '6', 'var i:Int = 0; var s:Int = 0; while (i < $N) { s = f3(1, 2, 3); i += 1; } return s;',
			'\tstatic function f3(a:Int, b:Int, c:Int):Int { return a + b + c; }\n');

		add('callCap20', 'call', '7', fill(CAPTURED) + 'var i:Int = 0; var s:Int = 0; while (i < $N) { s = f1(7); i += 1; } return s;',
			'\tstatic function f1(a:Int):Int { return a; }\n');

		add('classCall', 'call', last, 'var h:Holder = new Holder(); var i:Int = 0; var s:Int = 0; while (i < $N) { s = h.set(i); i += 1; } return s;',
			'}\nclass Holder {\n\tpublic var v:Int = 0;\n\tpublic function new() {}\n\tpublic function set(x:Int):Int { v = x; return v; }\n');

		// --- neither: dominated by how a mode unwinds, or by doing far more than one thing ---

		add('loopCont', 'unwind', N, 'var i:Int = 0; var s:Int = 0; while (i < $N) { i += 1; if (i > 0) continue; s = 1; } return i;');

		add('tryCatch', 'unwind', last,
			'var i:Int = 0; var s:Int = 0; while (i < $N) { try { throw i; } catch (e:Dynamic) { s = e; } i += 1; } return s;');

		add('classNew', 'compound', last, 'var i:Int = 0; var s:Int = 0; while (i < $N) { var h:Holder = new Holder(i); s = h.v; i += 1; } return s;',
			'}\nclass Holder {\n\tpublic var v:Int = 0;\n\tpublic function new(x:Int) { v = x; }\n');

		add('arrayCompr', 'compound', Std.string(ARRAY_LEN - 1),
			'var s:Int = 0; for (p in 0...$passes) { var a:Array<Int> = [for (k in 0...$ARRAY_LEN) k]; s = a[a.length - 1]; } return s;');

		return out;
	}

	/** One realistic source, for measuring what each mode charges to get ready. */
	public static function prepareSource():String {
		var out:StringBuf = new StringBuf();
		out.add('package p;\nclass T {\n\tpublic static function run():Dynamic { return f0(1); }\n');
		for (k in 0...80) {
			out.add('\tstatic function f$k(a:Int):Int {\n');
			out.add('\t\tvar t:Int = a;\n');
			out.add('\t\tif (t > $k) { t = t - $k; } else { t = t + $k; }\n');
			out.add('\t\tvar u:Int = t * 2 + 1;\n');
			out.add('\t\treturn u % 97;\n');
			out.add('\t}\n');
		}
		out.add('}\n');
		return out.toString();
	}
}

typedef Case = {
	var n:String;
	var t:String;

	/** How many loop iterations the case runs, so a published chart can state its scale. */
	var i:String;

	var x:String;
	var s:String;
}
