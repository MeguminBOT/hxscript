package studio;

import host.Sandbox;
import hxscript.Module;
import hxscript.error.Diagnostic;
import hxscript.error.Sink;
import hxscript.types.ScriptedClass;

/**
 * Runs a project's cases interpreted and again compiled, and says where the two disagree.
 *
 * The shared corpus in `test/lib` asks the language 266 questions against a bare host. This asks a
 * real one: every case here is an ordinary script reaching heaps, which is the half a project spends
 * its time in and the half the corpus cannot reach at all. Extending `h2d.Object` goes through a
 * generated bridge; reading `x` off one is a host property with a setter; `hxd.Math.iabs` is
 * `inline`, so whether it exists at runtime is a question about the build rather than the language.
 *
 * **A case is a no-argument static, and a module names its own.** `cases():Array<String>` is what the
 * runner reads, so the list lives beside the code it describes and adding one is editing a script
 * rather than this file. Names rather than closures on purpose: a closure crossing the boundary is
 * itself one of the things under test, and a runner should not depend on what it is measuring.
 *
 * Three outcomes, and they mean different things. **agree** is the one worth having. **DIFFERS** is a
 * script getting a different answer for a reason its author did not choose, which is the only real
 * failure. **interpreted** in the compiled pass means the module was refused and fell back, which is
 * safe and costs speed; it is reported rather than counted as agreement, because a fallback compares
 * the interpreter with itself and would otherwise read as a pass.
 */
class Conform {
	static var same:Int = 0;
	static var differs:Int = 0;
	static var fellBack:Int = 0;
	static var bothThrew:Int = 0;
	static var at:Int = 0;

	/**
	 * Loads a project twice and compares.
	 *
	 * @param name The project folder's name.
	 */
	public static function run(name:String):Void {
		Sink.listen(function(d:Diagnostic):Void say('  ' + d.toString().split('\n').join('\n  ')));

		/** The examples too, since every case this runs lives in one of them. */
		var project:ProjectInfo = Projects.find(name);

		if (project == null) {
			say('no project or example named "$name"');
			Sys.exit(2);
		}

		say('-- host interop, interpreted against compiled --');
		say('project   ${project.name}, ${project.scripts.length} script(s)');

		Sandbox.load(project, false);
		var interpreted:Map<String, String> = answers(null);

		Sandbox.load(project, false);
		var compiled:Map<String, String> = null;

		#if hxscript_hl
		if (!hxscript.compile.Compiler.available) {
			say('no compiler in this build: ' + (hxscript.compile.Compiler.unavailable() ?? 'no reason given'));
			Sys.exit(1);
		}

		var report = hxscript.compile.Compiler.compile(Sandbox.world);
		say('compiled  ${report.compiled.length} function(s), ${report.skipped.length} skipped, '
			+ '${report.failed.length} failed, ${report.bytes} bytes');

		for (skip in report.skipped)
			say('  skipped ' + skip.toString());

		compiled = answers(report.compiled);
		#else
		say('this build carries no HashLink backend');
		Sys.exit(1);
		#end

		say('');

		for (label in ordered) {
			var was:String = interpreted.get(label);
			var now:String = compiled.get(label);
			var via:String = reached.get(label);

			var verdict:String = if (via == 'interp') {
				fellBack++;
				'interpreted';
			} else if (was == now) {
				if (StringTools.startsWith(was, 'threw')) {
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

			say(pad(label, 30) + pad(verdict, 13) + pad(was, 34) + now);
		}

		say('');
		say('== ' + same + ' agree, ' + differs + ' differ, ' + fellBack + ' fell back, ' + bothThrew + ' unsupported on both ==');
		Sys.exit(differs == 0 ? 0 : 1);
	}

	/** Case labels in the order they were first run, so both passes report in one order. */
	static var ordered:Array<String> = [];

	/** What each case's owner turned out to be, by label. */
	static var reached:Map<String, String> = new Map();

	/**
	 * Runs every case the loaded world declares.
	 *
	 * @param compiledFields What the compiler said it compiled, or null for the interpreted pass.
	 * @return Each case's answer, by label.
	 */
	static function answers(compiledFields:Null<Array<String>>):Map<String, String> {
		var out:Map<String, String> = new Map();

		for (module in Sandbox.world.modules) {
			for (type in module.types) {
				if (!(type is ScriptedClass))
					continue;

				var cls:ScriptedClass = cast type;
				var list:Null<Array<String>> = names(cls);

				if (list == null)
					continue;

				for (method in list) {
					var label:String = cls.name + '.' + method;

					if (compiledFields == null && ordered.indexOf(label) < 0)
						ordered.push(label);

					if (compiledFields != null)
						reached.set(label, compiledFields.indexOf(cls.path + '.' + method) >= 0 ? 'method' : 'interp');

					out.set(label, call(cls, method));
				}
			}
		}

		return out;
	}

	/**
	 * @param cls A class the project declares.
	 * @return The case names it offers, or null when it offers none.
	 */
	static function names(cls:ScriptedClass):Null<Array<String>> {
		var lister:Dynamic = cls.reflectGetField('cases');

		if (lister == null)
			return null;

		try {
			var list:Dynamic = Reflect.callMethod(null, lister, []);
			return (list is Array) ? (list : Array<Dynamic>).map(function(v:Dynamic):String return Std.string(v)) : null;
		} catch (e:Dynamic) {
			return null;
		}
	}

	/**
	 * @param cls The case's owner.
	 * @param method Its name.
	 * @return What it answered, or what went wrong, on one line.
	 */
	static function call(cls:ScriptedClass, method:String):String {
		try {
			var fn:Dynamic = cls.reflectGetField(method);

			if (fn == null)
				return 'threw no such case';

			return flatten(Std.string(Reflect.callMethod(null, fn, [])));
		} catch (e:Dynamic) {
			return 'threw ' + flatten(Std.string(e));
		}
	}

	/** @return A value on one line and short enough that a row stays a row. */
	static function flatten(v:String):String {
		var flat:String = StringTools.replace(v, '\r', ' ');
		flat = StringTools.replace(flat, '\n', ' ');
		flat = StringTools.replace(flat, '\t', ' ');
		return flat.length > 32 ? flat.substr(0, 29) + '...' : flat;
	}

	static function pad(v:String, width:Int):String {
		var out:String = v;
		while (out.length < width)
			out += ' ';
		return out + ' ';
	}

	static function say(what:String):Void {
		Sys.println(what);
		Sys.stdout().flush();
	}
}
