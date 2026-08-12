import hxscript.Environment;
import hxscript.Module;
import hxscript.compile.Compiler;
import hxscript.compile.Report;
import hxscript.types.ScriptedClass;

/**
 * Runs the frontier list on HashLink and reports what happened, without judging it.
 *
 * **This never fails.** It is an instrument rather than a gate: a case that is refused, or that
 * throws on both sides, or that answers differently compiled, is the reading being taken. Wiring it
 * to an exit code would turn every new question into a broken build and stop anybody asking one.
 *
 * One line per case, tab separated, so the same list run on another backend can be put beside this
 * one and the two compared by column rather than by eye:
 *
 *     label <TAB> interpreted <TAB> compiled <TAB> verdict
 *
 * `--rows` prints only those lines, for feeding somewhere else. Without it each line is padded into
 * something readable.
 */
class FrontierProbe {
	static var same:Int = 0;
	static var differs:Int = 0;
	static var refused:Int = 0;
	static var bothThrew:Int = 0;

	/** Whether to print bare tab-separated rows rather than a padded report. */
	static var rows:Bool = false;

	/**
	 * The case being offered, counted whether or not it is run.
	 *
	 * A frontier case can take the process down rather than throw: a bad constant reaches the jit as
	 * an assert, and no `catch` runs after that. So each row carries its number and a run can be
	 * resumed past whatever killed the last one, which is the only way a list like this finishes.
	 */
	static var at:Int = 0;

	/** The first case to actually run, for resuming after a case took the process with it. */
	static var from:Int = 0;

	public static function main():Void {
		var args:Array<String> = Sys.args();

		for (i in 0...args.length) {
			if (args[i] == '--rows')
				rows = true;
			else if (args[i] == '--from' && i + 1 < args.length)
				from = Std.parseInt(args[i + 1]);
		}

		if (!rows) {
			Sys.println('-- the frontier, interpreted and compiled on HashLink --');
			Sys.println('   (nothing here is expected to pass; the answers are the point)');
			Sys.println('');
		}

		Frontier.run(check);

		if (rows) {
			/**
			 * Said only on the way out, so a driver can tell a run that finished from one that was
			 * killed part way. Without it, no output means either "the first case aborted" or "there
			 * were no cases left", and those need opposite responses.
			 */
			Sys.println('#done\t' + at);
			return;
		}

		Sys.println('');
		Sys.println('== ' + same + ' agree, ' + differs + ' differ, ' + refused + ' refused, ' + bothThrew + ' unsupported on both ==');
	}

	/**
	 * Runs one case both ways and records the pair.
	 *
	 * @param label How to name it.
	 * @param body The method body.
	 * @param extra Extra members of the class.
	 * @param before Declarations preceding it.
	 */
	static function check(label:String, body:String, ?extra:String, ?before:String):Void {
		var here:Int = at++;
		if (here < from)
			return;

		var source:String = 'package p;\n' + (before == null ? '' : before) + '\nclass T {\n' + (extra == null ? '' : extra) + '\n'
			+ '\tpublic static function run():Dynamic {\n\t\t' + body + '\n\t}\n}\n';

		var interpreted:String = run(source, false);
		var compiled:String = run(source, true);

		var verdict:String = if (StringTools.startsWith(compiled, 'REFUSED')) {
			refused++;
			'refused';
		} else if (interpreted == compiled) {
			if (StringTools.startsWith(interpreted, 'threw')) {
				bothThrew++;
				'unsupported';
			} else {
				same++;
				'agree';
			}
		} else {
			differs++;
			'DIFFERS';
		}

		say(here, label, interpreted, compiled, verdict);
	}

	/**
	 * @param source The module.
	 * @param compile Whether to offer it to the backend first.
	 * @return What it answered, or what went wrong, in one line.
	 */
	static function run(source:String, compile:Bool):String {
		try {
			var env:Environment = new Environment();
			var module:Module = new Module('', 'T', ['p'], 'frontier');
			module.parse(source);
			env.addModule(module);
			module.init(env);
			module.start(env);
			module.startTypes(env);

			if (compile) {
				var report:Report = Compiler.compile(env, [module]);

				if (report.compiled.length == 0) {
					var why:String = report.skipped.length > 0 ? report.skipped[0].reason : (report.failed.length > 0 ? report.failed[0].reason : 'no reason given');
					return 'REFUSED ' + one(why);
				}
			}

			var cls:ScriptedClass = cast env.resolve('p.T');
			var fn:Dynamic = cls.reflectGetField('run');

			if (fn == null)
				return 'no run()';

			return one(Std.string(Reflect.callMethod(null, fn, [])));
		} catch (e:Dynamic) {
			return 'threw ' + one(Std.string(e));
		}
	}

	/** @return A value flattened onto one line and shortened, so a row stays a row. */
	static function one(v:String):String {
		var flat:String = StringTools.replace(StringTools.replace(v, '\r', ' '), '\n', ' ');
		flat = StringTools.replace(flat, '\t', ' ');
		return flat.length > 58 ? flat.substr(0, 55) + '...' : flat;
	}

	static function say(index:Int, label:String, interpreted:String, compiled:String, verdict:String):Void {
		if (rows) {
			Sys.println(index + '\t' + label + '\t' + interpreted + '\t' + compiled + '\t' + verdict);
			Sys.stdout().flush();
			return;
		}

		Sys.println(pad(label, 42) + pad(verdict, 13) + pad(interpreted, 40) + compiled);
		Sys.stdout().flush();
	}

	static function pad(v:String, width:Int):String {
		var out:String = v;
		while (out.length < width)
			out += ' ';
		return out + ' ';
	}
}
