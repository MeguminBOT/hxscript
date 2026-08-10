import hxscript.Environment;
import hxscript.Module;
import hxscript.compile.Cppia;
import hxscript.compile.Unit;
import hxscript.compile.Result;
import hxscript.types.ScriptedClass;

/**
 * Checks a world of several modules, where only some of them may be compiled.
 *
 * `CppiaTest` compiles every module it is given, so it can never produce the arrangement that breaks
 * things: one class running compiled beside another running interpreted, sharing statics and types.
 * That arrangement is the whole risk, and it is what this exercises.
 *
 * Every case runs twice from the same sources, once with nothing compiled and once with whatever the case
 * asks for, and the two must agree. A world that cannot be compiled soundly is expected to fall back, not to
 * produce a different answer.
 */
class CppiaWorldTest {


	/**
	 * A helper the host hands every script under a bare name, standing in for the values an engine
	 * injects into each interpreter.
	 *
	 * The trailing optional is the point of it: a host static links by exact arity, so a call that
	 * leaves the optional off is the shape that breaks if these are reached the direct way.
	 */
	public static function bonus(n:Int, ?extra:Int):Int {
		return n + (extra == null ? 0 : extra);
	}

	/** A class holding static state, set up by one caller and read by another. */
	static var TABLES:String = 'package w;
class Tables {
	public static var ready:Bool = false;
	public static var scale:Int = 0;
	public static function init():Void {
		ready = true;
		scale = 7;
	}
	public static function set():Bool {
		return ready;
	}
}
';

	/** A class whose instance work depends on another class having been set up. */
	static var WORKER:String = 'package w;
import w.Tables;
class Worker {
	public var seen:Int = 0;
	public var live:Bool = true;
	public function new() {}
	public function run(n:Int):Int {
		if (!Tables.ready)
			return -1;
		seen = n * Tables.scale;
		return seen;
	}
	public function alive():Bool {
		return live;
	}
	public function maybe():Null<Bool> {
		return live;
	}
}
';

	/**
	 * The entry point, standing in for a class a host keeps interpreted.
	 *
	 * Reports the TYPE of every boolean it touches as well as its value, which is the only way the
	 * difference shows: cppia has no boolean and folds `Bool` into its integer type, so a compiled
	 * `alive()` handed back `1`, which prints as truthy, compares unequal to `true`, and fails a
	 * typed-mode `Bool` binding. `Null<Bool>` has no cppia spelling at all and read back as null
	 * whatever was returned.
	 */
	static var ENTRY:String = 'package w;
import w.Tables;
import w.Worker;
class Entry {
	public static var made:Dynamic = null;
	public static function go():Dynamic {
		Tables.init();
		var worker:Worker = new Worker();
		made = worker;

		var parts:Array<String> = [Std.string(worker.run(6) + bonus(1))];
		parts.push(tag(Tables.ready));
		parts.push(tag(Tables.set()));
		parts.push(tag(worker.live));
		parts.push(tag(worker.alive()));
		parts.push(tag(worker.maybe()));
		parts.push(worker.alive() == true ? "eq" : "ne");
		parts.push(tag(bound(worker)));
		return parts.join("/");
	}
	static function bound(worker:Worker):Bool {
		var held:Bool = worker.alive();
		return held;
	}
	static function tag(v:Dynamic):String {
		return Std.string(v) + ":" + Std.string(Type.typeof(v));
	}
}
';

	public static function run():Void {
		cpp.cppia.Host.enableJit(true);

		check('nothing compiled', [], false);
		check('everything compiled', ['w.Tables', 'w.Worker', 'w.Entry'], true);
		check('entry interpreted, rest compiled', ['w.Tables', 'w.Worker'], true);
		check('tables compiled, the rest interpreted', ['w.Tables'], false);
		check('worker compiled without the class it reads', ['w.Worker'], false);

	}

	/**
	 * Runs the world twice and compares.
	 *
	 * Agreeing while nothing was substituted proves nothing, which is how a compiled path can look
	 * correct for the whole time it is not being used, so what ran is checked as well as the answer.
	 *
	 * @param label How to name the case.
	 * @param compile Paths the host is asked to compile; the rest stay interpreted.
	 * @param expectSubstituted Whether the compiled classes should have been the ones that ran.
	 */
	static function check(label:String, compile:Array<String>, expectSubstituted:Bool = false):Void {
		var want:String = build([]);
		substituted = false;
		var got:String = build(compile);

		if (want != got) {
			TestCase.bad(label, 'interpreted ' + want + ', compiled ' + got);
			return;
		}

		if (expectSubstituted != substituted) {
			TestCase.bad(label, 'expected substitution=' + expectSubstituted + ', got ' + substituted);
			return;
		}

		TestCase.ok(label + '   ' + got + (substituted ? '   (ran compiled)' : '   (ran interpreted)'), true);
	}

	/** Whether the last run actually built a compiled class rather than a scripted one. */
	static var substituted:Bool = false;

	/**
	 * Builds the world, compiles the named classes into it, and runs its entry point.
	 *
	 * @param compile Scripted paths to compile.
	 * @return The result, or the failure that stopped it.
	 */
	static function build(compile:Array<String>):String {
		try {
			var env:Environment = new Environment();
			var sources:Array<{name:String, pack:Array<String>, code:String}> = [
				{name: 'Tables', pack: ['w'], code: TABLES},
				{name: 'Worker', pack: ['w'], code: WORKER},
				{name: 'Entry', pack: ['w'], code: ENTRY}
			];

			var modules:Array<Module> = [];
			for (source in sources) {
				var module:Module = new Module(source.code, source.name, source.pack, source.name);
				env.addModule(module);
				modules.push(module);
			}

			env.variables.set('bonus', bonus);

			for (module in modules)
				module.init(env);
			for (module in modules)
				module.start(env);
			for (module in modules)
				module.startTypes(env);

			if (compile.length > 0)
				compileInto(env, sources, compile);

			var cls:ScriptedClass = cast env.resolve('w.Entry');
			var result:String = Std.string(Reflect.callMethod(null, cls.reflectGetField('go'), []));

			var made:Dynamic = cls.reflectGetField('made');
			substituted = made != null && !(made is hxscript.types.IScriptedInstance);

			return result;
		} catch (e:Dynamic) {
			return 'threw: ' + e;
		}
	}

	/**
	 * Compiles the named classes and registers them with the world.
	 *
	 * @param env The world.
	 * @param sources Every module in it.
	 * @param wanted The scripted paths to compile.
	 */
	static function compileInto(env:Environment, sources:Array<{name:String, pack:Array<String>, code:String}>, wanted:Array<String>):Void {
		var inputs:Array<Unit> = [];
		var outside:Array<String> = [];

		for (source in sources) {
			var path:String = source.pack.join('.') + '.' + source.name;
			var decls = new hxscript.syntax.Parser().parseModule(source.code, source.name, 0, source.pack);

			if (wanted.indexOf(path) >= 0)
				inputs.push({name: source.name, decls: decls});
			else
				outside.push(path);
		}

		var result:Result = Cppia.compile(inputs, null, outside, ['bonus=CppiaWorldTest::bonus']);
		if (result.bytes == null)
			return;

		var loaded = cpp.cppia.Module.fromData(result.bytes.getData());
		loaded.boot();

		#if hxscript_cppia
		for (path in wanted) {
			var cls:Class<Dynamic> = loaded.resolveClass(path);
			if (cls != null)
				env.compiled.set(path, cls);
		}

		env.substituting = env.compiled.keys().hasNext();
		#end
	}

	static function main():Void {
		run();
		TestCase.exit();
	}
}
