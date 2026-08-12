import hxscript.Environment;
import hxscript.Module;
import hxscript.compile.Compiler;
import hxscript.compile.Report;
import hxscript.types.ScriptedClass;

/** Something with identity, for the case that passes an object through a dynamic call. */
private class Holder {
	public var value:Int;

	public function new(value:Int) {
		this.value = value;
	}

	/** Bound to an instance, so the closure carries a value rather than only an address. */
	public function plus(n:Int):Int {
		return value + n;
	}
}

/**
 * Whether an HL/C host's own dynamic calls still work once a script has been compiled.
 *
 * The reason to doubt it. `hlc_main.c` installs `hlc_static_call` and `hlc_get_wrapper`, which are
 * how a program generated as C makes a call whose signature is not known until runtime. The first
 * time anything is jitted, `jit.c` overwrites both, process-wide and permanently:
 *
 *     if( !call_jit_c2hl ) {
 *         hl_setup.get_wrapper = get_wrapper;
 *         hl_setup.static_call = callback_c2hl;
 *         hl_setup.static_call_ref = true;
 *
 * So compiling a script does not only add something, it replaces machinery the host was already
 * using, and from that point every dynamic call in the program goes through the jit's trampoline
 * instead of the wrapper table the C generator wrote. `HlcProbe` shows one signature surviving that.
 * One signature is not an answer.
 *
 * Every case is run twice, before and after the first compile, and both runs are checked against
 * what the answer should be. Two failures are therefore distinguishable: a case that was always
 * wrong is this probe's bug, and a case that was right and stopped being right is the hijack.
 *
 * Each case is caught separately, because the failure being looked for is as likely to be a crash
 * as a wrong answer, and one crashed case should not take the other fourteen with it.
 */
class CallbackProbe {
	static var SOURCE:String = 'package p;
class T {
	public static function total(n:Int):Int {
		var sum:Int = 0;
		var i:Int = 0;
		while (i < n) {
			sum += i * 3;
			i++;
		}
		return sum;
	}

	public static function viaHost(x:Float):String {
		return Std.string(Math.round(x * 1.5));
	}
}
';

	static var touched:Int = 0;
	static var failures:Int = 0;

	static function nothing():Void {
		touched++;
	}

	static function twice(n:Int):Int {
		return n * 2;
	}

	static function half(f:Float):Float {
		return f / 2;
	}

	static function flip(b:Bool):Bool {
		return !b;
	}

	static function shout(s:String):String {
		return s.toUpperCase();
	}

	static function mix(n:Int, s:String, f:Float):String {
		return s + n + ':' + f;
	}

	static function bump(h:Holder):Holder {
		return new Holder(h.value + 1);
	}

	static function maybe(?n:Int):Int {
		return n == null ? -1 : n * 10;
	}

	/**
	 * Every case, as label and answer.
	 *
	 * @return One entry per case, in a fixed order so the two runs line up by index.
	 */
	static function every():Array<String> {
		var answers:Array<String> = [];

		answers.push(one('void', function():String {
			var was:Int = touched;
			Reflect.callMethod(null, nothing, []);
			return Std.string(touched - was);
		}));

		answers.push(one('Int', function():String {
			return Std.string(Reflect.callMethod(null, twice, [21]));
		}));

		answers.push(one('Float', function():String {
			return Std.string(Reflect.callMethod(null, half, [7.0]));
		}));

		answers.push(one('Bool', function():String {
			return Std.string(Reflect.callMethod(null, flip, [true]));
		}));

		answers.push(one('String', function():String {
			return Std.string(Reflect.callMethod(null, shout, ['mods']));
		}));

		answers.push(one('three arguments', function():String {
			return Std.string(Reflect.callMethod(null, mix, [4, 'n', 0.5]));
		}));

		answers.push(one('an object in and out', function():String {
			var out:Dynamic = Reflect.callMethod(null, bump, [new Holder(41)]);
			return Std.string((out : Holder).value);
		}));

		answers.push(one('an optional left out', function():String {
			return Std.string(Reflect.callMethod(null, maybe, []));
		}));

		answers.push(one('an optional given', function():String {
			return Std.string(Reflect.callMethod(null, maybe, [3]));
		}));

		answers.push(one('a bound instance method', function():String {
			var h:Holder = new Holder(100);
			return Std.string(Reflect.callMethod(null, h.plus, [5]));
		}));

		answers.push(one('a closure over a local', function():String {
			var kept:Int = 9;
			var fn:Int->Int = function(n:Int):Int return n + kept;
			return Std.string(Reflect.callMethod(null, fn, [1]));
		}));

		answers.push(one('var-args', function():String {
			var fn:Dynamic = Reflect.makeVarArgs(function(args:Array<Dynamic>):Dynamic return args.length);
			return Std.string(Reflect.callMethod(null, fn, [1, 2, 3]));
		}));

		answers.push(one('cast to another signature', function():String {
			var dyn:Dynamic = twice;
			var wide:Dynamic->Dynamic = dyn;
			return Std.string(wide(21));
		}));

		answers.push(one('a null through a dynamic argument', function():String {
			var fn:Dynamic->String = function(v:Dynamic):String return v == null ? 'nothing' : 'something';
			return Std.string(Reflect.callMethod(null, fn, [null]));
		}));

		answers.push(one('a field looked up by name', function():String {
			var fn:Dynamic = Reflect.field(new Holder(7), 'plus');
			return Std.string(Reflect.callMethod(new Holder(7), fn, [1]));
		}));

		return answers;
	}

	/**
	 * Runs one case.
	 *
	 * @param label What it is.
	 * @param body What it answers.
	 * @return The answer, or what went wrong, which compares unequal to the right answer either way.
	 */
	static function one(label:String, body:Void->String):String {
		try {
			return body();
		} catch (e:Dynamic) {
			return 'threw ' + Std.string(e);
		}
	}

	static var WANT:Array<String> = ['1', '42', '3.5', 'false', 'MODS', 'n4:0.5', '42', '-1', '30', '105', '10', '3', '42', 'nothing', '8'];

	static var LABELS:Array<String> = [
		'void', 'Int', 'Float', 'Bool', 'String', 'three arguments', 'an object in and out', 'an optional left out',
		'an optional given', 'a bound instance method', 'a closure over a local', 'var-args',
		'cast to another signature', 'a null through a dynamic argument', 'a field looked up by name'
	];

	public static function main():Void {
		Sys.println('-- an HL/C host\'s own dynamic calls, across the first compile --');

		var before:Array<String> = every();
		report('before any script is compiled', before);

		var env:Environment = new Environment();
		var module:Module = new Module('', 'T', ['p'], 'hlc');
		module.parse(SOURCE);
		env.addModule(module);
		module.init(env);
		module.start(env);
		module.startTypes(env);

		var built:Report = Compiler.compile(env, [module]);
		say('a module was compiled and jitted', built.compiled.length > 0);

		if (built.skipped.length > 0)
			Sys.println('    refused: ' + built.skipped[0].reason);

		var cls:ScriptedClass = cast env.resolve('p.T');
		say('the compiled function answers', Std.string(Reflect.callMethod(null, cls.reflectGetField('total'), [1000])) == '1498500');
		say('compiled code can still reach the host', Std.string(Reflect.callMethod(null, cls.reflectGetField('viaHost'), [4.0])) == '6');

		var after:Array<String> = every();
		report('after the jit took over hl_setup', after);

		var moved:Int = 0;
		for (i in 0...before.length) {
			if (before[i] != after[i]) {
				moved++;
				Sys.println('    ' + LABELS[i] + ' changed: ' + before[i] + ' -> ' + after[i]);
			}
		}

		say('nothing changed across the compile', moved == 0);

		Sys.println(failures == 0 ? '== the host is unharmed ==' : '== ' + failures + ' failed ==');
		Sys.exit(failures == 0 ? 0 : 1);
	}

	/**
	 * Checks one run of every case and prints the ones that are wrong.
	 *
	 * @param when Which run this is.
	 * @param got What it answered.
	 */
	static function report(when:String, got:Array<String>):Void {
		var wrong:Int = 0;

		for (i in 0...WANT.length) {
			if (got[i] == WANT[i])
				continue;

			wrong++;
			Sys.println('    ' + LABELS[i] + ': wanted ' + WANT[i] + ', got ' + got[i]);
		}

		say(when + ', all ' + WANT.length + ' right', wrong == 0);
	}

	static function say(what:String, ok:Bool):Void {
		if (!ok)
			failures++;

		var pad:String = what;
		while (pad.length < 50)
			pad += ' ';

		Sys.println('  ' + pad + (ok ? 'yes' : 'NO'));
	}
}
