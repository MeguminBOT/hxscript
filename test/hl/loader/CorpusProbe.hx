import hxscript.Environment;
import hxscript.Module;
import hxscript.compile.Compiler;
import hxscript.compile.Report;
import hxscript.types.ScriptedClass;

/**
 * Runs the shared corpus through the HashLink backend and says how much of it compiles.
 *
 * The same list the cppia backend answers, so the two numbers mean the same thing. Every case is
 * run twice from one source: interpreted in one world, compiled in another, and the answers have to
 * agree. Three outcomes are counted apart, because they are three different situations. A refusal
 * leaves the module interpreted and correct, and costs only speed. A disagreement is a wrong answer
 * and is the only one that fails the run. A case the interpreter itself does not get right says
 * nothing about the compiler and is reported on its own.
 *
 * Goes through `Compiler.compile` rather than reaching for the emitter, because binding what a
 * script names in the host needs the world, and most of the corpus names something.
 */
class CorpusProbe {
	static var passed:Int = 0;
	static var failed:Int = 0;
	static var refused:Int = 0;
	static var unrun:Int = 0;

	/** Run only the case with this label, when one was named on the command line. */
	static var only:String = null;

	/** Whether to print why each refusal was refused. */
	static var verbose:Bool = false;

	public static function main():Void {
		for (arg in Sys.args()) {
			if (arg == '-v')
				verbose = true;
			else
				only = arg;
		}

		Sys.println('-- the shared corpus, interpreted and compiled --');
		Corpus.run(check);

		var total:Int = passed + failed + refused + unrun;
		Sys.println('== ' + passed + ' compiled and agree, ' + failed + ' disagree, ' + refused + ' refused, ' + unrun + ' the interpreter misses, of '
			+ total + ' ==');
		Sys.exit(failed == 0 ? 0 : 1);
	}

	/**
	 * Builds one case's source, runs it both ways and compares.
	 *
	 * @param label How to name it.
	 * @param body The method body.
	 * @param want What it should produce.
	 * @param extra Extra members of the class the body sits in.
	 * @param before Declarations preceding that class.
	 */
	static function check(label:String, body:String, want:String, ?extra:String, ?before:String):Void {
		if (only != null && label != only)
			return;

		var source:String = 'package p;\n' + (before == null ? '' : before) + '\nclass T {\n' + (extra == null ? '' : extra) + '\n'
			+ '\tpublic static function run():Dynamic {\n\t\t' + body + '\n\t}\n}\n';

		var world:Environment = new Environment();
		var interpreted:String = call(world, load(world, source));

		if (interpreted != want) {
			unrun++;
			say(label, 'the interpreter gave ' + interpreted + ', wanting ' + want);
			return;
		}

		var other:Environment = new Environment();
		var module:Module = load(other, source);
		if (module == null) {
			unrun++;
			say(label, 'would not parse');
			return;
		}

		var report:Report = Compiler.compile(other, [module]);

		if (report.compiled.length == 0) {
			refused++;
			if (verbose) {
				var why:String = 'no reason given';
				if (report.skipped.length > 0)
					why = report.skipped[0].reason + ' (line ' + report.skipped[0].line + ')';
				else if (report.failed.length > 0)
					why = report.failed[0].reason;
				say(label, 'REFUSED ' + why);
			}
			return;
		}

		var got:String = call(other, module);
		if (got == want) {
			passed++;
			if (verbose)
				say(label, got);
		} else {
			failed++;
			say(label, 'compiled gave ' + got + ', interpreted gave ' + interpreted);
		}
	}

	/**
	 * Puts a source into a world.
	 *
	 * @param env The world.
	 * @param source The script.
	 * @return The module, or null when it would not parse.
	 */
	static function load(env:Environment, source:String):Module {
		try {
			var module:Module = new Module('', 'T', ['p'], 'corpus');
			module.parse(source);
			env.addModule(module);
			module.init(env);
			module.start(env);
			module.startTypes(env);
			return module;
		} catch (e:Dynamic) {
			return null;
		}
	}

	/**
	 * Calls a module's entry point, whichever of the two forms is bound to it.
	 *
	 * @param env The world it belongs to.
	 * @param module The module.
	 * @return What it produced, rendered, or what went wrong.
	 */
	static function call(env:Environment, module:Module):String {
		if (module == null)
			return 'would not parse';

		try {
			var cls:ScriptedClass = cast env.resolve('p.T');
			return Std.string(Reflect.callMethod(null, cls.reflectGetField('run'), []));
		} catch (e:Dynamic) {
			return 'threw ' + Std.string(e);
		}
	}

	static function say(label:String, what:String):Void {
		var pad:String = label;
		while (pad.length < 44)
			pad += ' ';
		Sys.println('  ' + pad + what);
		Sys.stdout().flush();
	}
}
