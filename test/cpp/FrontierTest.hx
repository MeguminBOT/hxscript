import hxscript.Environment;
import hxscript.Module;
import hxscript.compile.Compiler;
import hxscript.compile.Report;
import hxscript.types.ScriptedClass;

/**
 * Runs the frontier list on cppia and reports what happened, without judging it.
 *
 * The counterpart of `test/hl/loader/FrontierProbe.hx`, printing the same rows so the two can be put
 * side by side and read by column. See that file for what the readings mean and why nothing here
 * asserts.
 *
 * **Its own program rather than part of `AllCpp`.** The suite is a gate and this is an instrument: a
 * case that is refused or answers differently is the reading, so wiring it to an exit code would
 * turn every new question into a broken build.
 */
class FrontierTest {
	static var same:Int = 0;
	static var differs:Int = 0;
	static var refused:Int = 0;
	static var bothThrew:Int = 0;

	static var rows:Bool = false;
	static var at:Int = 0;
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
			Sys.println('-- the frontier, interpreted and compiled on cppia --');
			Sys.println('   (nothing here is expected to pass; the answers are the point)');
			Sys.println('');
		}

		Frontier.run(check);

		if (rows) {
			Sys.println('#done\t' + at);
			return;
		}

		Sys.println('');
		Sys.println('== ' + same + ' agree, ' + differs + ' differ, ' + refused + ' refused, ' + bothThrew + ' unsupported on both ==');
	}

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
			/**
			 * Flushed per row, because a compiled module may print on its own account and an
			 * unflushed row can end up interleaved with it, which loses a field and reads as a
			 * finding rather than as the accident it is.
			 */
			Sys.println(index + '\t' + label + '\t' + interpreted + '\t' + compiled + '\t' + verdict);
			Sys.stdout().flush();
			return;
		}

		Sys.println(pad(label, 42) + pad(verdict, 13) + pad(interpreted, 40) + compiled);
	}

	static function pad(v:String, width:Int):String {
		var out:String = v;
		while (out.length < width)
			out += ' ';
		return out + ' ';
	}
}
