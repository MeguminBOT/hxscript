import hxscript.Script;

/**
 * Interpreter micro-benchmark. Each case isolates one hot path so an optimization can be
 * attributed: `call` exercises the call-stack frame push/pop, `blocks` the per-block scope
 * bookkeeping, `field` the field-access chain, `arith`/`locals` the operator dispatch and
 * variable lookup.
 */
class Bench {
	static var reps:Int = 3;

	/**
	 * Multiplies every case's loop count, passed as the first command line argument.
	 *
	 * At the default counts the quickest cases finish in tens of milliseconds, which is the same
	 * order as the machine's own run-to-run drift, so a change worth a couple of percent cannot be
	 * separated from noise. Raising this until each case runs for something closer to a second is
	 * what makes small effects measurable. Defaults to 1 so the usual numbers are unchanged.
	 */
	static var scale:Int = 1;

	static var loopBound:EReg = ~/i < ([0-9]+)/g;

	/** Rewrites `i < N` bounds in a case's source by `scale`. */
	static function scaled(src:String):String {
		if (scale <= 1) {
			return src;
		}

		return loopBound.map(src, function(r:EReg):String {
			return "i < " + (Std.parseInt(r.matched(1)) * scale);
		});
	}

	static function bench(name:String, rawSrc:String):Void {
		var src:String = scaled(rawSrc);

		// warm up (parse + first run), then take the best of `reps` to cut scheduler noise
		var best:Float = 1e9;
		for (i in 0...reps) {
			var s = new Script(src, name);
			var t0 = haxe.Timer.stamp();
			s.start();
			var dt = haxe.Timer.stamp() - t0;
			if (dt < best)
				best = dt;
		}
		trace(pad(name, 14) + Std.int(best * 1000) + " ms");
	}

	static function pad(s:String, n:Int):String {
		while (s.length < n)
			s += " ";
		return s;
	}

	static function main():Void {
		var arg:String = Sys.args()[0];
		if (arg != null) {
			var n:Null<Int> = Std.parseInt(arg);
			if (n != null && n > 0) {
				scale = n;
			}
		}

		trace("-- interpreter micro-benchmark (best of " + reps + ", scale x" + scale + ") --");

		bench("arith", "var x = 0; var i = 0; while (i < 300000) { x += i * 2 - 1; i++; } x;");
		bench("locals", "var a = 1; var b = 2; var c = 3; var i = 0; while (i < 300000) { a = b + c; i++; } a;");
		bench("blocks", "var i = 0; var s = 0; while (i < 200000) { { var t = i; s = t; } i++; } s;");
		bench("call", "function f(a) return a + 1; var i = 0; var s = 0; while (i < 100000) { s = f(s); i++; } s;");
		bench("field", "var o = {a: 1, b: 2}; var i = 0; var s = 0; while (i < 200000) { s += o.a; i++; } s;");
		bench("method", "var arr = [1]; var i = 0; while (i < 100000) { arr.indexOf(1); i++; } i;");
		// Array element read and write, and the unary operators, all of which have to tell an
		// ordinary value apart from a wrapped abstract before they can act on it.
		bench("index", "var a = [1, 2, 3]; var i = 0; var s = 0; while (i < 200000) { s += a[1]; i++; } s;");
		bench("indexSet", "var a = [1, 2, 3]; var i = 0; while (i < 200000) { a[0] = i; i++; } a[0];");
		bench("not", "var b = false; var i = 0; var s = 0; while (i < 200000) { if (!b) s++; i++; } s;");
		bench("neg", "var x = 5; var i = 0; var s = 0; while (i < 200000) { s = -x; i++; } s;");

		// Attribution: 0 / 1 / 3 parameters at the same call count. The spread between them is the
		// per-parameter cost (declared.push + locals.set + tryCast); call0 is the fixed per-call
		// overhead (makeVarArgs, frame push, locals duplicate, restore, frame pop).
		bench("call0", "function f() return 1; var i = 0; var s = 0; while (i < 100000) { s = f(); i++; } s;");
		bench("call1", "function f(a) return a; var i = 0; var s = 0; while (i < 100000) { s = f(s); i++; } s;");
		bench("call3", "function f(a, b, c) return a; var i = 0; var s = 0; while (i < 100000) { s = f(s, 1, 2); i++; } s;");
		// A block with the same body but no call at all, as the floor.
		// Does `return` (implemented by throwing Stop.SReturn) dominate a call?
		bench("callRet", "function f() return 1; var i = 0; var s = 0; while (i < 100000) { s = f(); i++; } s;");
		bench("callNoRet", "function f() { 1; } var i = 0; var s = 0; while (i < 100000) { s = f(); i++; } s;");
		// break / continue still unwind by throwing Stop; continue can fire every iteration.
		bench("loopPlain", "var i = 0; var s = 0; while (i < 100000) { i++; s += i; } s;");
		bench("loopCont", "var i = 0; var s = 0; while (i < 100000) { i++; if (i % 2 == 0) continue; s += i; } s;");
		bench("noCall", "var i = 0; var s = 0; while (i < 100000) { s = s; i++; } s;");

		// Type annotations. Each pair is the same work with and without the annotation, so the spread
		// is what checking a declared type costs on a write, on an argument, and on a return.
		bench("varPlain", "var i = 0; var x = 0; while (i < 200000) { x = i; i++; } x;");
		bench("varTyped", "var i = 0; var x:Int = 0; while (i < 200000) { x = i; i++; } x;");
		bench("varTypedObj", "var i = 0; var x:String = 'a'; while (i < 200000) { x = 'b'; i++; } x;");
		bench("fnPlain", "function f(a) return a; var i = 0; var s = 0; while (i < 100000) { s = f(i); i++; } s;");
		bench("fnTyped", "function f(a:Int):Int return a; var i = 0; var s = 0; while (i < 100000) { s = f(i); i++; } s;");

		// Scripted-class instantiation, which builds an interpreter per instance. `newInstBare` is the
		// floor (no members); `newInstFields` adds members so the per-member construction work shows
		// up separately from the fixed per-instance cost.
		var bare = "class B { public function new() {} }\n";
		var full = "class F { public var x:Int = 0; public var y:Float = 1.5; public var n:String = 'a';"
			+ " public function new() {} public function m1(v) return v; public function m2(v) return v; }\n";
		bench("newInstBare", bare + "var i = 0; while (i < 20000) { new B(); i++; } i;");
		bench("newInstFields", full + "var i = 0; while (i < 20000) { new F(); i++; } i;");
		// An instance method call and an instance field read, through the generated bridge.
		bench("instCall", full + "var p = new F(); var i = 0; while (i < 100000) { p.m1(1); i++; } i;");
		bench("instField", full + "var p = new F(); var i = 0; var s = 0; while (i < 100000) { s += p.x; i++; } s;");

		// Diagnostic: same call count, but the function is declared in a scope holding 20 locals.
		// If per-call cost scales with captured-scope size, the locals-map copy dominates calls.
		var many = "";
		for (n in 0...20)
			many += "var v" + n + " = " + n + "; ";
		bench("call_cap20", many + "function f(a) return a + 1; var i = 0; var s = 0; while (i < 100000) { s = f(s); i++; } s;");

		// The configuration a host actually ships: `private` enforced, and a non-empty blacklist. Both
		// sit on paths that run per field access and per type resolution, so the cost of turning them
		// on is measured rather than assumed. Re-runs the cases above so the pairs line up.
		hxscript.Config.strictAccess = true;
		hxscript.Config.blacklist.set(ByType, ['sys.io.File', 'sys.io.Process', 'Sys']);
		hxscript.Config.blacklist.set(ByPackage(true), ['sys', 'haxe.macro', 'cpp']);

		var cls = "class S { public var x:Int = 0; private var h:Int = 1; public function new() {}" + " public function m(v) return v; }\n";
		bench("fieldGuard", "var o = {a: 1, b: 2}; var i = 0; var s = 0; while (i < 200000) { s += o.a; i++; } s;");
		bench("methodGuard", "var arr = [1]; var i = 0; while (i < 100000) { arr.indexOf(1); i++; } i;");
		bench("instFieldGuard", cls + "var p = new S(); var i = 0; var s = 0; while (i < 100000) { s += p.x; i++; } s;");
		bench("instCallGuard", cls + "var p = new S(); var i = 0; while (i < 100000) { p.m(1); i++; } i;");
		bench("newInstGuard", cls + "var i = 0; while (i < 20000) { new S(); i++; } i;");

		trace("-- done --");
	}
}
