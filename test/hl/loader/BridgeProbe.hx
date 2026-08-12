import hxscript.Environment;
import hxscript.Module;
import hxscript.compile.Compiler;
import hxscript.compile.Report;
import hxscript.types.ScriptedClass;

/**
 * The same script over a **host** base, interpreted and compiled, compared step by step.
 *
 * The corpus builds its instances from `ScriptedObject`, which is what a script with no native base
 * gets. An application's scripts are not that: they extend something the host offers, so what runs
 * is a generated bridge with native fields and native methods beside the scripted ones. Everything
 * about reading a field, writing one, reaching `super` and letting an override win goes through
 * different code there, and none of it was covered.
 *
 * Written after the heaps sandbox compiled a project for the first time and the compiled copy threw
 * where the interpreted one did not. This is that project reduced to a page with no window under it,
 * so the difference can be found without anybody watching a screen.
 *
 * Each step is checked on its own, so a failure names the operation rather than the frame.
 */
class BridgeProbe {
	static var SOURCE:String = 'package p;
class P extends probe.Surface {
	public var elapsed:Float = 0;
	public var seen:Array<Int> = [];
	public var kept:probe.Surface;

	public function new() {
		super();
	}

	override public function tick():Void {
		super.tick();
		elapsed += 1.5;
		seen.push(seen.length);
	}

	override public function label():String {
		return "p:" + elapsed;
	}

	public function readElapsed():Float {
		return elapsed;
	}

	public function readNative():Int {
		return ticks;
	}

	public function readSeen():Int {
		return seen.length;
	}

	public function describe():String {
		return label() + "/" + ticks;
	}

	public function hold():String {
		if (kept == null)
			kept = new probe.Surface();

		kept.tick();
		kept.ticks = kept.ticks + 10;
		return "kept " + kept.ticks;
	}

	public function woven():String {
		return "e=" + elapsed + " n=" + ticks + " s=" + seen.length + " " + (elapsed > 1 ? "on" : "off");
	}
}
';

	static var failures:Int = 0;

	static function world():Environment {
		var env:Environment = new Environment();
		var module:Module = new Module('', 'P', ['p'], 'bridge');
		module.parse(SOURCE);
		env.addModule(module);
		module.init(env);
		module.start(env);
		module.startTypes(env);
		return env;
	}

	/**
	 * Builds one instance and puts it through everything, returning what happened at each step.
	 *
	 * @param env The world.
	 * @return One entry per step, in a fixed order so the two runs line up by index.
	 */
	static function exercise(env:Environment):Array<String> {
		var out:Array<String> = [];

		try {
			var cls:ScriptedClass = cast env.resolve('p.P');
			var made:Dynamic = cls.typeCreateInstance([]);

			out.push('built ' + (made == null ? 'nothing' : 'one'));
			out.push('elapsed at rest ' + Std.string(call(made, 'readElapsed', [])));
			out.push('native at rest ' + Std.string(call(made, 'readNative', [])));

			call(made, 'tick', []);
			out.push('elapsed after one ' + Std.string(call(made, 'readElapsed', [])));
			out.push('native after one ' + Std.string(call(made, 'readNative', [])));
			out.push('array after one ' + Std.string(call(made, 'readSeen', [])));

			call(made, 'tick', []);
			call(made, 'tick', []);
			out.push('elapsed after three ' + Std.string(call(made, 'readElapsed', [])));
			out.push('native after three ' + Std.string(call(made, 'readNative', [])));

			out.push('the override wins ' + Std.string(call(made, 'label', [])));
			out.push('a method calling one ' + Std.string(call(made, 'describe', [])));
			out.push('a host object in a field ' + Std.string(call(made, 'hold', [])));
			out.push('again ' + Std.string(call(made, 'hold', [])));
			out.push('interpolated ' + Std.string(call(made, 'woven', [])));
		} catch (e:Dynamic) {
			out.push('threw ' + Std.string(e));
		}

		return out;
	}

	/**
	 * @param on The instance.
	 * @param name The method.
	 * @param args Its arguments.
	 * @return What it answered, or what it threw.
	 */
	static function call(on:Dynamic, name:String, args:Array<Dynamic>):Dynamic {
		try {
			/**
			 * Through the library's own reflection. A bridge answers for its scripted methods with
			 * custom hooks, and `Reflect.field` only sees the native ones, so asking the ordinary way
			 * finds nothing for everything this probe is about.
			 */
			var fn:Dynamic = hxscript.proxy.ReflectProxy.field(on, name);
			return fn == null ? 'no such method' : Reflect.callMethod(on, fn, args);
		} catch (e:Dynamic) {
			return 'threw ' + Std.string(e);
		}
	}

	public static function main():Void {
		Sys.println('-- a script over a host base, interpreted and compiled --');

		var want:Array<String> = exercise(world());

		var env:Environment = world();
		var report:Report = Compiler.compile(env);

		say('the module compiled', report.compiled.length > 0);

		if (report.skipped.length > 0)
			Sys.println('    refused: ' + report.skipped[0].reason);

		var got:Array<String> = exercise(env);

		for (i in 0...want.length) {
			var here:String = i < got.length ? got[i] : 'nothing';
			if (here == want[i])
				continue;

			failures++;
			Sys.println('    ' + want[i] + '   COMPILED GAVE ' + here);
		}

		say('every step agrees', failures == 0);

		if (failures == 0) {
			for (line in want)
				Sys.println('    ' + line);
		}

		Sys.println(failures == 0 ? '== the bridge holds ==' : '== ' + failures + ' step(s) differ ==');
		Sys.exit(failures == 0 ? 0 : 1);
	}

	static function say(what:String, ok:Bool):Void {
		if (!ok)
			failures++;

		var pad:String = what;
		while (pad.length < 34)
			pad += ' ';

		Sys.println('  ' + pad + (ok ? 'yes' : 'NO'));
	}
}
