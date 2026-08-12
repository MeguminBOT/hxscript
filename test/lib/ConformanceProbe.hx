import hxscript.Environment;
import hxscript.Module;
import hxscript.compile.Compiler;
import hxscript.compile.Report;
import hxscript.types.ScriptedClass;

/**
 * Answers the whole conformance list in one mode, and says nothing about whether that was right.
 *
 * One program for every mode, which is the point of it. It is built six ways, changing only the
 * target and the defines, so a difference between two columns cannot be a difference between two
 * runners. Comparing is `Table`'s job, and it is deliberately somewhere else: a runner that decided
 * what counted as agreement would have to be built into every column, and then a column could
 * disagree about what disagreement means.
 *
 * Each row is one case, tab separated:
 *
 *     index  label  status  via  value
 *
 * `status` is `ok` when it ran, `threw` when it did not, `refused` when the compiler would not take
 * the module, and `parse` when the source would not parse at all. `via` says what actually ran:
 * `interp` for the tree-walking interpreter, `method` for a compiled function bound onto the scripted
 * class, `class` for a compiled class standing in for it.
 *
 * **`via` exists because a refused module falls back to the interpreter silently.** That has cost
 * real time before: a harness that resolves the entry the ordinary way and calls it will compare the
 * interpreter with itself and report a compiled column that is entirely green. A row that says
 * `interp` in a compiled column is not a passing row, whatever value it carries.
 *
 * A refusal deliberately produces no value. Running the case anyway would measure the interpreter
 * and file it under the compiler, which is the same mistake wearing a reason.
 */
class ConformanceProbe {
	/** Whether to print tab-separated rows rather than a readable listing. */
	static var rows:Bool = false;

	/** Whether to skip compiling, which is what makes this the interpreted column. */
	static var interpretOnly:Bool = false;

	/** The case being offered, counted whether or not it is run. */
	static var at:Int = 0;

	/** The index to start at, so the driver can resume past a case that ended the process. */
	static var from:Int = 0;

	/** Run only the case with this label, when one was named. */
	static var only:Null<String> = null;

	public static function main():Void {
		var args:Array<String> = Sys.args();

		/**
		 * The same options again, for a column that cannot be given arguments.
		 *
		 * The eval column is run by the compiler itself, which rejects an option it does not know and
		 * hands its own through to `Sys.args`, so there is no way to pass `--from` on that command
		 * line. Every other column takes them normally; this is what makes one driver able to drive
		 * all six.
		 */
		var passed:Null<String> = Sys.getEnv('HXS_CONFORMANCE');
		if (passed != null)
			args = args.concat(passed.split(' '));

		for (i in 0...args.length) {
			switch (args[i]) {
				case '--rows':
					rows = true;
				case '--interp':
					interpretOnly = true;
				case '--nojit':
					#if (hxscript_cppia || hxscript_hl)
					Compiler.jit = false;
					#end
				case '--from' if (i + 1 < args.length):
					from = Std.parseInt(args[i + 1]);
				case '--only' if (i + 1 < args.length):
					only = args[i + 1];
				case _:
			}
		}

		/**
		 * A build with no compiler in it is the interpreted column, and saying so is not the same as
		 * refusing every case. `Compiler.compile` on such a build answers with an empty report, which
		 * is indistinguishable from a refusal unless this is asked first.
		 */
		if (!Compiler.available)
			interpretOnly = true;

		if (!rows) {
			Sys.println('-- the conformance list, ' + (interpretOnly ? 'interpreted' : 'compiled where it can be') + ' --');
			Sys.println('');
		}

		Conformance.run(one);

		if (rows) {
			Sys.println('#done\t' + at);
			Sys.stdout().flush();
		}
	}

	/**
	 * Runs one case and reports what happened to it.
	 *
	 * @param label How to name it.
	 * @param body The method body.
	 * @param want What it should produce, unused here: this reports, it does not judge.
	 * @param extra Extra members of the class the body sits in.
	 * @param before Declarations preceding that class.
	 */
	static function one(label:String, body:String, want:Null<String>, ?extra:String, ?before:String):Void {
		var here:Int = at++;

		if (here < from || (only != null && label != only))
			return;

		var source:String = Conformance.source(here, body, extra, before);
		var env:Environment = new Environment();
		var module:Null<Module> = load(env, here, source);

		if (module == null) {
			say(here, label, 'parse', 'interp', 'would not parse');
			return;
		}

		if (!interpretOnly) {
			var report:Report = Compiler.compile(env, [module]);
			var why:Null<String> = refusal(report);

			if (why != null) {
				say(here, label, 'refused', 'interp', why);
				return;
			}

			var found:Entry = entry(env, report, here);
			run(here, label, found.fn, found.via);
			return;
		}

		run(here, label, scripted(env, here), 'interp');
	}

	/**
	 * Calls a case's entry point and records what came back.
	 *
	 * @param index The case's index.
	 * @param label Its label.
	 * @param fn The entry, or null when nothing answered to it.
	 * @param via What kind of entry it is.
	 */
	static function run(index:Int, label:String, fn:Null<Dynamic>, via:String):Void {
		if (fn == null) {
			say(index, label, 'threw', via, 'no run()');
			return;
		}

		try {
			say(index, label, 'ok', via, Std.string(Reflect.callMethod(null, fn, [])));
		} catch (e:Dynamic) {
			say(index, label, 'threw', via, Std.string(e));
		}
	}

	/**
	 * Puts a source into a world and gets it ready to run.
	 *
	 * @param env The world.
	 * @param index The case's index, which decides its package.
	 * @param source The script.
	 * @return The module, or null when it would not parse.
	 */
	static function load(env:Environment, index:Int, source:String):Null<Module> {
		try {
			var module:Module = new Module('', 'T', [Conformance.pack(index)], 'conformance');
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
	 * @param report What the compiler said.
	 * @return Why nothing was compiled, or null when something was.
	 */
	static function refusal(report:Report):Null<String> {
		if (report.compiled.length > 0)
			return null;

		if (report.skipped.length > 0)
			return report.skipped[0].reason;

		if (report.failed.length > 0)
			return report.failed[0].reason;

		return 'nothing compiled, and nothing said why';
	}

	/**
	 * Finds the entry that will actually run, preferring a compiled one and saying which it found.
	 *
	 * The two backends bind what they compiled in different places, so both are asked. A compiled
	 * class stands in for the scripted one whole, and its static is an ordinary field of it; a
	 * compiled method is put back on the scripted class, replacing the interpreted closure that was
	 * there. Neither is reachable the other's way.
	 *
	 * @param env The world.
	 * @param report What the compiler said.
	 * @param index The case's index.
	 * @return The entry and what kind it is.
	 */
	static function entry(env:Environment, report:Report, index:Int):Entry {
		var path:String = Conformance.path(index);

		#if hxscript_cppia
		var native:Null<Class<Dynamic>> = env.compiled.get(path);

		if (native != null) {
			var substituted:Dynamic = Reflect.field(native, 'run');
			if (substituted != null)
				return {fn: substituted, via: 'class'};
		}
		#end

		var fn:Null<Dynamic> = scripted(env, index);

		if (fn != null && report.compiled.indexOf(path + '.run') >= 0)
			return {fn: fn, via: 'method'};

		return {fn: fn, via: 'interp'};
	}

	/**
	 * @param env The world.
	 * @param index The case's index.
	 * @return The entry as the scripted class holds it, compiled or not.
	 */
	static function scripted(env:Environment, index:Int):Null<Dynamic> {
		var owner:Dynamic = env.resolve(Conformance.path(index));

		if (!(owner is ScriptedClass))
			return null;

		return (cast owner : ScriptedClass).reflectGetField('run');
	}

	/**
	 * Writes one row.
	 *
	 * Flushed per row on purpose: a compiled module may print on its own account, and an unflushed
	 * row interleaved with that loses a field and then reads as a finding rather than an accident.
	 * The driver also reads the last row it got to work out which case ended the process, so a row
	 * still sitting in a buffer when that happens blames the wrong case.
	 */
	static function say(index:Int, label:String, status:String, via:String, value:String):Void {
		var flat:String = flatten(value);

		if (rows) {
			Sys.println(index + '\t' + label + '\t' + status + '\t' + via + '\t' + flat);
			Sys.stdout().flush();
			return;
		}

		Sys.println(pad(Std.string(index), 5) + pad(label, 44) + pad(status, 9) + pad(via, 8) + flat);
		Sys.stdout().flush();
	}

	/** @return A value on one line and short enough that a row stays a row. */
	static function flatten(v:String):String {
		var flat:String = StringTools.replace(v, '\r', ' ');
		flat = StringTools.replace(flat, '\n', ' ');
		flat = StringTools.replace(flat, '\t', ' ');
		return flat.length > 70 ? flat.substr(0, 67) + '...' : flat;
	}

	static function pad(v:String, width:Int):String {
		var out:String = v;
		while (out.length < width)
			out += ' ';
		return out + ' ';
	}
}

/** An entry point and what kind of one it turned out to be. */
typedef Entry = {
	/** The callable, or null when nothing answered to it. */
	var fn:Null<Dynamic>;

	/** `interp`, `method` or `class`. */
	var via:String;
}
