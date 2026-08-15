/**
 * The shared benchmark corpus, identical for every library under test.
 *
 * Every case ends in an expression whose value is known, so a library that parses and "runs" a case
 * without doing the work is caught rather than being recorded as infinitely fast.
 *
 * The loop count is a parameter, and every expected value is derived from it, so the same corpus can
 * be run at several scales. That is worth doing: a single scale cannot tell a real per-operation
 * difference apart from a fixed setup cost or a warm-up artefact, and one that only appears at one
 * size is not a property of the interpreter.
 *
 * Counts and accumulators stay inside 32-bit Int at every supported scale, so expected values are
 * exact on every target rather than depending on overflow.
 */
class BenchCases {
	/** Element count of the array `forArray` walks; the loop count decides how many passes it makes. */
	static inline var ARRAY_LEN:Int = 1000;

	/** How many extra variables `callCap20` leaves in scope around its function. */
	static inline var CAPTURED:Int = 20;

	/**
	 * `CAPTURED` variable declarations, to sit in scope around a function so the call has something
	 * to capture.
	 *
	 * Plain `var` declarations only, so this stays inside the subset every library runs.
	 */
	static function fill(k:Int):String {
		var out:StringBuf = new StringBuf();
		for (v in 0...k) {
			out.add('var v$v = $v; ');
		}
		return out.toString();
	}

	/**
	 * The corpus scaled to `n` loop iterations.
	 *
	 * @param n Iterations per case. Must be a multiple of `ARRAY_LEN` so `forArray` divides evenly.
	 */
	public static function all(n:Int):Array<Case> {
		var N:String = Std.string(n);
		var last:String = Std.string(n - 1); // value of the loop counter on the final iteration

		// `switch (i % 3)` maps 0 -> 1, 1 -> 2, anything else -> 3, evaluated at the last counter value
		var switchX:String = Std.string(((n - 1) % 3 == 0) ? 1 : (((n - 1) % 3 == 1) ? 2 : 3));

		return [
			// --- core: plain expression-level hscript, expected to work in every library ---
			{
				n: "noCall",
				t: "core",
				i: N,
				x: "0",
				s: 'var i = 0; var s = 0; while (i < $N) { s = s; i += 1; } s;'
			},
			{
				n: "loopPlain",
				t: "core",
				i: N,
				x: N,
				s: 'var i = 0; var s = 0; while (i < $N) { i += 1; s += 1; } s;'
			},
			// counts the odd values of i in 1...n
			{
				n: "loopCont",
				t: "core",
				i: N,
				x: Std.string((n + 1) >> 1),
				s: 'var i = 0; var s = 0; while (i < $N) { i += 1; if (i % 2 == 0) continue; s += 1; } s;'
			},
			{
				n: "postIncr",
				t: "core",
				i: N,
				x: N,
				s: 'var i = 0; var n = 0; while (n < $N) { i++; n += 1; } i;'
			},
			{
				n: "arith",
				t: "core",
				i: N,
				x: Std.string(2 * n - 3),
				s: 'var x = 0; var i = 0; while (i < $N) { x = i * 2 - 1; i += 1; } x;'
			},
			{
				n: "locals",
				t: "core",
				i: N,
				x: "5",
				s: 'var a = 1; var b = 2; var c = 3; var i = 0; while (i < $N) { a = b + c; i += 1; } a;'
			},
			{
				n: "blocks",
				t: "core",
				i: N,
				x: last,
				s: 'var i = 0; var s = 0; while (i < $N) { { var t = i; s = t; } i += 1; } s;'
			},
			{
				n: "field",
				t: "core",
				i: N,
				x: "1",
				s: 'var o = {a: 1, b: 2}; var i = 0; var s = 0; while (i < $N) { s = o.a; i += 1; } s;'
			},
			{
				n: "fieldSet",
				t: "core",
				i: N,
				x: last,
				s: 'var o = {a: 1}; var i = 0; while (i < $N) { o.a = i; i += 1; } o.a;'
			},
			{
				n: "method",
				t: "core",
				i: N,
				x: "0",
				s: 'var a = [1]; var i = 0; var s = 0; while (i < $N) { s = a.indexOf(1); i += 1; } s;'
			},
			{
				n: "index",
				t: "core",
				i: N,
				x: "2",
				s: 'var a = [1, 2, 3]; var i = 0; var s = 0; while (i < $N) { s = a[1]; i += 1; } s;'
			},
			{
				n: "indexSet",
				t: "core",
				i: N,
				x: last,
				s: 'var a = [1, 2, 3]; var i = 0; while (i < $N) { a[0] = i; i += 1; } a[0];'
			},
			{
				n: "not",
				t: "core",
				i: N,
				x: "1",
				s: 'var b = false; var i = 0; var s = 0; while (i < $N) { if (!b) s = 1; i += 1; } s;'
			},
			{
				n: "neg",
				t: "core",
				i: N,
				x: "-5",
				s: 'var x = 5; var i = 0; var s = 0; while (i < $N) { s = -x; i += 1; } s;'
			},
			{
				n: "call0",
				t: "core",
				i: N,
				x: "1",
				s: 'function f() return 1; var i = 0; var s = 0; while (i < $N) { s = f(); i += 1; } s;'
			},
			{
				n: "call1",
				t: "core",
				i: N,
				x: "7",
				s: 'function f(a) return a; var i = 0; var s = 0; while (i < $N) { s = f(7); i += 1; } s;'
			},
			{
				n: "call3",
				t: "core",
				i: N,
				x: "6",
				s: 'function f(a, b, c) return a + b + c; var i = 0; var s = 0; while (i < $N) { s = f(1, 2, 3); i += 1; } s;'
			},
			// Exactly `call1` with CAPTURED more variables in the enclosing scope. Read as a PAIR: the
			// two differ in nothing but how much scope surrounds the function, so the gap between them
			// is what a call costs per captured variable and nothing else.
			//
			// Worth measuring across libraries because it is a design difference, not a constant: an
			// interpreter that builds its call frame by copying the captured scope pays for every
			// variable in it on every call, and one that does not pay nothing.
			{
				n: "callCap20",
				t: "core",
				i: N,
				x: "7",
				s: fill(CAPTURED) + 'function f(a) return a; var i = 0; var s = 0; while (i < $N) { s = f(7); i += 1; } s;'
			},
			{
				n: "forRange",
				t: "core",
				i: N,
				x: last,
				s: 'var s = 0; for (i in 0...$N) s = i; s;'
			},
			// `n / ARRAY_LEN` passes over an ARRAY_LEN-element array, so the element visits total `n`
			{
				n: "forArray",
				t: "core",
				i: N,
				x: Std.string(ARRAY_LEN - 1),
				s: 'var a = []; var n = 0; while (n < $ARRAY_LEN) { a.push(n); n += 1; } var s = 0; var r = 0; while (r < ${Std.int(n / ARRAY_LEN)}) { for (v in a) s = v; r += 1; } s;'
			},
			{
				n: "arrayDecl",
				t: "core",
				i: N,
				x: "3",
				s: 'var i = 0; var n = 0; while (i < $N) { var a = [1, 2, 3]; n = a.length; i += 1; } n;'
			},
			{
				n: "strConcat",
				t: "core",
				i: N,
				x: 'x$last',
				s: 'var s = \'\'; var i = 0; while (i < $N) { s = \'x\' + i; i += 1; } s;'
			},
			{
				n: "ternary",
				t: "core",
				i: N,
				x: Std.string(((n - 1) % 2 == 0) ? 1 : 2),
				s: 'var i = 0; var s = 0; while (i < $N) { s = (i % 2 == 0) ? 1 : 2; i += 1; } s;'
			},

			// --- ext: features a library may not implement ---
			{
				n: "switch",
				t: "ext",
				i: N,
				x: switchX,
				s: 'var s = 0; var i = 0; while (i < $N) { switch (i % 3) { case 0: s = 1; case 1: s = 2; default: s = 3; } i += 1; } s;'
			},
			{
				n: "tryCatch",
				t: "ext",
				i: N,
				x: "1",
				s: 'var s = 0; var i = 0; while (i < $N) { try { throw \'e\'; } catch (e:Dynamic) { s = 1; } i += 1; } s;'
			},
			// `$$` is a literal `$` here, so the script source really contains 'v$n' for the library to
			// interpolate (or not, which is the point of the case).
			{
				n: "strInterp",
				t: "ext",
				i: N,
				x: "v5",
				s: 'var n = 5; var s = \'\'; var i = 0; while (i < $N) { s = \'v$$n\'; i += 1; } s;'
			},
			{
				n: "mapLiteral",
				t: "ext",
				i: N,
				x: "2",
				s: 'var i = 0; var s = 0; while (i < $N) { var m = [\'a\' => 1, \'b\' => 2]; s = m[\'b\']; i += 1; } s;'
			},
			{
				n: "arrayCompr",
				t: "ext",
				i: N,
				x: "5",
				s: 'var i = 0; var n = 0; while (i < $N) { var a = [for (k in 0...5) k * 2]; n = a.length; i += 1; } n;'
			},
			{
				n: "varTyped",
				t: "ext",
				i: N,
				x: last,
				s: 'var i = 0; var x:Int = 0; while (i < $N) { x = i; i += 1; } x;'
			},
			{
				n: "fnTyped",
				t: "ext",
				i: N,
				x: "7",
				s: 'function f(a:Int):Int return a; var i = 0; var s = 0; while (i < $N) { s = f(7); i += 1; } s;'
			},

			// --- ext: script-declared classes, which only some libraries have at all ---
			{
				n: "classNew",
				t: "ext",
				i: N,
				x: "0",
				s: 'class B { public function new() {} }\nvar i = 0; while (i < $N) { new B(); i += 1; } 0;'
			},
			{
				n: "classCall",
				t: "ext",
				i: N,
				x: "7",
				s: 'class C { public var x = 0; public function new() {} public function m(v) return v; }\n' +
				'var c = new C(); var i = 0; var s = 0; while (i < $N) { s = c.m(7); i += 1; } s;'
			},
			{
				n: "classField",
				t: "ext",
				i: N,
				x: "3",
				s: 'class D { public var x = 3; public function new() {} }\n' + 'var d = new D(); var i = 0; var s = 0; while (i < $N) { s = d.x; i += 1; } s;'
			}
		];
	}

	/** A source of realistic size, used to compare parse throughput rather than execution. */
	public static function parseSource():String {
		var b = new StringBuf();
		for (i in 0...80) {
			b.add("function fn" + i + "(a, b) {\n");
			b.add("\tvar t = a * 2 + b;\n\tif (t > 10) { t -= 1; } else { t += 1; }\n");
			b.add("\tvar acc = 0;\n\tfor (k in 0...3) acc += k * t;\n\treturn acc;\n}\n");
		}
		return b.toString();
	}
}

/** One benchmark case: name, tier, expected value as a string, and source. */
typedef Case = {
	var n:String;
	var t:String;

	/** How many loop iterations the case runs, so a published chart can state its scale. */
	var i:String;

	var x:String;
	var s:String;
}
