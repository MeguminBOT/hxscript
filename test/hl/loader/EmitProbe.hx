import hxscript.Environment;
import hxscript.Module;
import hxscript.compile.Unsupported;
import hxscript.hl.Binding.BindingKind;
import hxscript.hl.Emitter;
import hxscript.hl.Loader;
import hxscript.hl.Loader.Loaded;
import hxscript.types.ScriptedClass;

/**
 * A host class a script reaches out to, standing in for whatever an embedder exposes.
 *
 * Deliberately one of our own rather than something from the standard library: on HashLink `Math`
 * is not reachable by reflection at all, and `Std.int` is inline and so has no runtime field, so
 * neither says anything about whether reaching the host works.
 */
@:keep
class HostBits {
	public static var answer:Int = 42;

	public static function twice(n:Int):Int {
		return n * 2;
	}

	public static function between(low:Int, high:Int):Int {
		return low + high;
	}

	public static function scale(v:Float):Float {
		return v * 1.5;
	}
}

/**
 * Runs the same source interpreted and compiled and compares the answers.
 *
 * Agreeing is the whole claim. A construct the emitter refuses is reported and counted separately,
 * because that leaves the module interpreted and correct, which is a cost rather than a fault.
 */
class EmitProbe {
	static var passed:Int = 0;
	static var failed:Int = 0;
	static var refused:Int = 0;

	static function source(ret:String, body:String, extra:String):String {
		return 'package p;\nclass T {\n\tpublic static function run():' + ret + ' {\n\t\t' + body + '\n\t}\n' + extra + '\n}\n';
	}

	static function interpreted(src:String):String {
		try {
			var env:Environment = new Environment();
			var module:Module = new Module('', 'T', ['p'], 'emit');
			module.parse(src);
			env.addModule(module);
			module.init(env);
			module.start(env);
			module.startTypes(env);

			var cls:ScriptedClass = cast env.resolve('p.T');
			return Std.string(Reflect.callMethod(null, cls.reflectGetField('run'), []));
		} catch (e:Dynamic) {
			return 'threw ' + Std.string(e);
		}
	}

	/**
	 * Compiles a case and runs it.
	 *
	 * **A world is built even though this reaches for the emitter directly.** A class of the batch is
	 * no longer a type the module holds, so `new T()` asks the world for the class the same way a
	 * script naming a host type does, and without one there is nothing for that binding to resolve
	 * to. Everything else here still goes around the backend on purpose, which is what makes this a
	 * probe of the emitter rather than a second corpus run.
	 */
	static function compiled(src:String):String {
		var emitter:Emitter = new Emitter();
		emitter.pack = 'p';

		var env:Environment = new Environment();
		var unit:Module = new Module('', 'T', ['p'], 'emit');

		try {
			unit.parse(src);
			env.addModule(unit);
			unit.init(env);
			unit.start(env);
			unit.startTypes(env);
		} catch (e:Dynamic) {
			return 'threw while loading ' + Std.string(e);
		}

		var decls = unit.decls;

		try {
			emitter.declare(decls, 'T');
			emitter.emit(decls, 'T');
		} catch (e:Unsupported) {
			return 'REFUSED ' + e.reason;
		}

		var entry:Null<Int> = emitter.expose('T.run');
		if (entry == null)
			return 'REFUSED no entry point';

		var module = emitter.finish();
		module.entry = entry;

		var raw:haxe.io.Bytes = module.pack();
		var loaded:Loaded = Loader.load(raw);
		if (loaded == null) {
			return 'REJECTED ' + (Loader.error() ?? 'no reason given');
		}

		for (binding in emitter.bindings) {
			Loader.set(loaded, binding.index, switch (binding.kind) {
				case BHost:
					var holder:Dynamic = Type.resolveClass(binding.owner);
					holder == null ? null : Reflect.field(holder, binding.field);
				case BSupport:
					hxscript.hl.Emitter.support(binding.field);
				case BConst:
					binding.value;
				case BOwner:
					env.resolve(binding.owner);
				case BModule:
					unit.moduleFields;
			});
		}

		var fn:Dynamic = Loader.bind(loaded, entry);
		if (fn == null)
			return 'no closure';

		try {
			return Std.string(Reflect.callMethod(null, fn, []));
		} catch (e:Dynamic) {
			return 'threw ' + Std.string(e);
		}
	}

	static function check(label:String, ret:String, body:String, extra:String = ''):Void {
		var src:String = source(ret, body, extra);
		var want:String = interpreted(src);
		var got:String = compiled(src);

		if (StringTools.startsWith(got, 'REFUSED')) {
			refused++;
			say(label, got);
			return;
		}

		if (got == want) {
			passed++;
			say(label, got);
		} else {
			failed++;
			say(label, got + '   INTERPRETED ' + want);
		}
	}

	/**
	 * Checks that both sides refuse a construct, without demanding they say the same thing.
	 *
	 * Some failures cannot read alike. A name the host does not offer is unknown to the interpreter
	 * before anything runs, and is a null the compiled module reaches for at the point of use, so
	 * the two describe the same absence from different distances. What matters is that neither
	 * pretends it worked.
	 *
	 * @param label How to name the case.
	 * @param ret The declared return type.
	 * @param body The script body.
	 * @param extra Anything the class needs beside it.
	 */
	static function throws(label:String, ret:String, body:String, extra:String = ''):Void {
		var src:String = source(ret, body, extra);
		var want:String = interpreted(src);
		var got:String = compiled(src);

		if (StringTools.startsWith(want, 'threw') && StringTools.startsWith(got, 'threw')) {
			passed++;
			say(label, 'both refuse it');
		} else {
			failed++;
			say(label, 'compiled ' + got + ', interpreted ' + want);
		}
	}

	static function say(label:String, what:String):Void {
		var pad:String = label;
		while (pad.length < 34)
			pad += ' ';
		Sys.println('  ' + pad + what);
		Sys.stdout().flush();
	}

	public static function main():Void {
		// Both sides have to be able to reach the host, or a case that exercises reaching it is only
		// measuring the interpreter failing.
		hxscript.Config.globalImports.set('HostBits', hxscript.syntax.Expr.ImportMode.INormal);

		Sys.println('-- the same source, interpreted and compiled --');

		check('a constant', 'Int', 'return 42;');
		check('addition', 'Int', 'return 300 + 45;');
		check('the operators', 'Int', 'return 7 * 3 - 8 / 2 + 11 % 4;');
		check('bit operations', 'Int', 'return (255 & 12) | (1 << 4) ^ 3;');
		check('shifts', 'Int', 'var n:Int = -32; return (n >> 2) + (n >>> 28);');
		check('unary negate', 'Int', 'var n:Int = 5; return -n;');
		check('a local', 'Int', 'var n:Int = 6; return n * 7;');
		check('locals interacting', 'Int', 'var a:Int = 3; var b:Int = 4; return a * a + b * b;');
		check('assignment', 'Int', 'var n:Int = 1; n = n + 41; return n;');
		check('compound assignment', 'Int', 'var n:Int = 2; n += 40; n *= 1; return n;');
		check('increment', 'Int', 'var n:Int = 41; n++; return n;');

		check('floats', 'Float', 'var f:Float = 1.5; return f * 2.25;');
		check('int widening to float', 'Float', 'var f:Float = 2; var g:Float = f + 1; return g;');

		check('a comparison as a value', 'Bool', 'var n:Int = 5; return n > 3;');
		check('a comparison that is false', 'Bool', 'var n:Int = 1; return n > 3;');
		check('equality', 'Bool', 'var n:Int = 4; return n == 4;');
		check('negation', 'Bool', 'var n:Int = 4; return !(n == 4);');
		check('and', 'Bool', 'var n:Int = 4; return n > 1 && n < 9;');
		check('or', 'Bool', 'var n:Int = 4; return n < 1 || n < 9;');

		check('if taken', 'Int', 'var n:Int = 5; if (n > 3) return 1; return 0;');
		check('if not taken', 'Int', 'var n:Int = 1; if (n > 3) return 1; return 0;');
		check('if else', 'Int', 'var n:Int = 1; if (n > 3) { return 1; } else { return 2; }');
		check('nested ifs', 'Int', 'var n:Int = 5; if (n > 1) { if (n > 4) return 10; return 20; } return 30;');

		check('while', 'Int', 'var i:Int = 0; var t:Int = 0; while (i < 10) { t += i; i++; } return t;');
		check('while that never runs', 'Int', 'var i:Int = 10; var t:Int = 0; while (i < 10) { t += i; i++; } return t;');
		check('for over a range', 'Int', 'var t:Int = 0; for (i in 0...10) t += i; return t;');
		check('for with a break', 'Int', 'var t:Int = 0; for (i in 0...10) { if (i == 5) break; t += i; } return t;');
		check('for with a continue', 'Int', 'var t:Int = 0; for (i in 0...10) { if (i % 2 == 0) continue; t += i; } return t;');
		check('nested loops', 'Int', 'var t:Int = 0; for (i in 0...4) for (j in 0...4) t += i * j; return t;');

		check('a call', 'Int', 'return twice(21);', '\tpublic static function twice(n:Int):Int { return n * 2; }');
		check('a call with two arguments', 'Int', 'return sum(20, 22);', '\tpublic static function sum(a:Int, b:Int):Int { return a + b; }');
		check('a call in an expression', 'Int', 'return twice(10) + twice(11);', '\tpublic static function twice(n:Int):Int { return n * 2; }');
		check('a call before its declaration', 'Int', 'return later(21);', '\tpublic static function later(n:Int):Int { return n + 21; }');
		check('recursion', 'Int', 'return fib(20);', '\tpublic static function fib(n:Int):Int { if (n < 2) return n; return fib(n - 1) + fib(n - 2); }');
		check('mutual calls', 'Int', 'return even(10);', '\tpublic static function even(n:Int):Int { if (n == 0) return 1; return odd(n - 1); }\n'
			+ '\tpublic static function odd(n:Int):Int { if (n == 0) return 0; return even(n - 1); }');

		var holder:String = '}\nclass Holder {\n'
			+ '\tpublic var a:Int;\n'
			+ '\tpublic var b:Int;\n'
			+ '\tpublic function new() { a = 0; b = 1; }\n'
			+ '\tpublic function bump():Int { a = a + b; return a; }\n'
			+ '\tpublic function total(extra:Int):Int { return a + b + extra; }\n';

		check('an instance', 'Int', 'var h:Holder = new Holder(); return h.a;', holder);
		check('a field written and read', 'Int', 'var h:Holder = new Holder(); h.a = 41; return h.a + h.b;', holder);
		check('fields interacting', 'Int', 'var h:Holder = new Holder(); h.a = h.b + 40; h.b = h.a - h.b; return h.a + h.b;', holder);
		check('a field in a loop', 'Int',
			'var h:Holder = new Holder(); for (i in 0...10) h.a = h.a + h.b; return h.a;', holder);
		check('an instance method', 'Int', 'var h:Holder = new Holder(); h.bump(); h.bump(); return h.a;', holder);
		check('an instance method with an argument', 'Int', 'var h:Holder = new Holder(); return h.total(40);', holder);
		check('a method reaching its own fields', 'Int',
			'var h:Holder = new Holder(); h.a = 20; return h.bump() + h.b;', holder);
		check('two instances stay apart', 'Int',
			'var x:Holder = new Holder(); var y:Holder = new Holder(); x.a = 40; y.a = 2; return x.a + y.a;', holder);
		check('a constructor with arguments', 'Int', 'var p:Point = new Point(40, 2); return p.x + p.y;',
			'}\nclass Point {\n\tpublic var x:Int;\n\tpublic var y:Int;\n'
			+ '\tpublic function new(x:Int, y:Int) { this.x = x; this.y = y; }\n');
		check('a float field', 'Float', 'var v:Vec = new Vec(); v.n = 1.5; return v.n * 2.25;',
			'}\nclass Vec {\n\tpublic var n:Float;\n\tpublic function new() { n = 0.0; }\n');

		check('a host static call', 'Int', 'return HostBits.twice(21);');
		check('a host call with two arguments', 'Int', 'return HostBits.between(40, 2);');
		check('a host static read', 'Int', 'return HostBits.answer;');
		check('a host call on a local', 'Int', 'var n:Int = 21; return HostBits.twice(n);');
		check('a host call in a loop', 'Int', 'var t:Int = 0; for (i in 0...10) t += HostBits.twice(i); return t;');
		check('a host call feeding another', 'Int', 'return HostBits.twice(HostBits.twice(10));');
		check('a host result compared', 'Bool', 'return HostBits.twice(21) == 42;');
		check('a host call returning a float', 'Float', 'return HostBits.scale(3.0);');
		throws('a host name nothing answers to', 'Int', 'return Nowhere.gone(1);');

		check('a string', 'String', 'return "no";');
		check('a string joined to a number', 'String', 'var n:Int = 2; return "n" + n;');
		check('a string compared', 'Bool', 'var s:String = "a"; return s == "a";');
		check('a string field', 'Int', 'var s:String = "abc"; return s.length;');
		check('a string method', 'String', 'var s:String = "ab"; return s.toUpperCase();');
		check('an array', 'Int', 'var a = [1, 2]; return a[0];');
		check('an array written to', 'Int', 'var a = [1, 2]; a[0] = 40; return a[0] + a[1];');
		check('an array looped over', 'Int', 'var t:Int = 0; for (v in [1, 2, 3]) t += v; return t;');
		check('a map', 'Int', 'var m = ["a" => 40, "b" => 2]; return m.get("a") + m.get("b");');
		check('a structure', 'Int', 'var o = {a: 40, b: 2}; return o.a + o.b;');
		check('a comprehension', 'Int', 'var a = [for (i in 0...4) i * 2]; return a[3];');

		Sys.println('== ' + passed + ' passed, ' + failed + ' failed ==, ' + refused + ' refused');
		Sys.exit(failed == 0 ? 0 : 1);
	}
}
