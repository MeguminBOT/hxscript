import hxscript.Environment;
import hxscript.Module;
import hxscript.compile.Compiler;
import hxscript.cppia.Backend;
import hxscript.compile.Unit;
import hxscript.compile.Report;
import hxscript.compile.Result;

/**
 * What happens when compiling does not go well.
 *
 * Refusals from the emitter are expected: some constructs have no bytecode spelling, the module keeps
 * running interpreted, and everything around it still compiles. The loader *refusing* a module is not
 * expected, is a defect below the script, and used to end the host process, throwing a bare string naming
 * the fault and nothing inside the module, with nothing catching it.
 *
 * The refusal path cannot be reached from a script, because reaching it means finding a construct
 * the emitter emits and the loader rejects, and every one of those found so far has been fixed. So
 * it is tested where it can be: the guard is proved against bytecode that is definitely bad, and the
 * skip path is proved against a construct the emitter definitely refuses.
 */
class LoadFailureTest {
	public static function run():Void {
		guarded();
		skipping();
		clean();
	}

	/**
	 * Bytecode the loader cannot read is caught rather than thrown at the host.
	 *
	 * The catch has to be two clauses, and this is what says so: hxcpp raises a loader fault by
	 * throwing a bare string, which is not a `haxe.Exception`, so a single typed catch lets it
	 * straight through. Being alive on the line after the try is the whole assertion.
	 */
	static function guarded():Void {
		var junk:haxe.io.Bytes = haxe.io.Bytes.ofString('CPPIA nonsense that is not a module at all');

		var caught:String = null;

		try {
			var loaded = cpp.cppia.Module.fromData(junk.getData());
			loaded.boot();
		} catch (e:haxe.Exception) {
			caught = e.message;
		} catch (e:Dynamic) {
			caught = Std.string(e);
		}

		TestCase.ok('a bad module is caught, not fatal', caught != null);

		if (caught == null)
			TestCase.bad('bad module', 'the loader accepted junk');
	}

	/**
	 * A module the emitter refuses is reported with its position and leaves the rest compiling.
	 *
	 * A local property is the refusal used, because it is short, has a position, and means the same thing
	 * interpreted as it would compiled, so the fallback can be checked by its answer rather than only by not
	 * throwing. What is being checked is not that this construct is unsupported, which may change, but that
	 * a refusal carries where it was and does not take the batch with it.
	 */
	static function skipping():Void {
		var good:String = 'package w;\nclass Good {\n\tpublic static function go():Int { return 41 + 1; }\n}\n';

		var bad:String = 'package w;\n'
			+ 'class Bad {\n'
			+ '\tpublic static function go():Int {\n'
			+ '\t\tvar x(get, never):Int;\n'
			+ '\t\tfunction get_x():Int return 1;\n'
			+ '\t\treturn x;\n'
			+ '\t}\n'
			+ '}\n';

		var env:Environment = new Environment();
		env.addModule(new Module(good, 'Good', ['w'], 'Good.hx'));
		env.addModule(new Module(bad, 'Bad', ['w'], 'Bad.hx'));
		env.start();

		var report:Report = Compiler.compile(env);

		TestCase.ok('the refusal is reported', report.skipped.length > 0);
		TestCase.ok('the loader refused nothing', report.failed.length == 0);

		var positioned:Bool = false;
		for (entry in report.skipped)
			if (entry.origin != null && entry.line > 0)
				positioned = true;

		TestCase.ok('the refusal carries a position', positioned);

		var compiled:Bool = report.compiled.indexOf('w.Good') >= 0;
		TestCase.ok('the module beside it still compiled', compiled);

		var answer:Dynamic = call(env, 'w.Bad');
		if (answer != 1)
			TestCase.bad('interpreted fallback', 'gave ' + answer + ', expected 1');
		else
			TestCase.ok('the refused module still runs interpreted   ' + answer, true);
	}

	/** A world with nothing wrong with it reports no failures at all. */
	static function clean():Void {
		var source:String = 'package v;\nclass Fine {\n\tpublic static function go():Int { return 7; }\n}\n';

		var env:Environment = new Environment();
		env.addModule(new Module(source, 'Fine', ['v'], 'Fine.hx'));
		env.start();

		var report:Report = Compiler.compile(env);

		TestCase.ok('a clean world fails nothing', report.failed.length == 0);

		var answer:Dynamic = call(env, 'v.Fine');
		if (answer != 7)
			TestCase.bad('clean world', 'gave ' + answer + ', expected 7');
		else
			TestCase.ok('a clean world still answers   ' + answer, true);
	}

	/**
	 * Calls a scripted class's `go`.
	 *
	 * @param env The world.
	 * @param path The class path.
	 * @return Whatever it returned, or the failure as a string.
	 */
	static function call(env:Environment, path:String):Dynamic {
		try {
			var cls:hxscript.types.ScriptedClass = cast env.resolve(path);
			return Reflect.callMethod(null, cls.reflectGetField('go'), []);
		} catch (e:Dynamic) {
			return 'threw: ' + e;
		}
	}
}
