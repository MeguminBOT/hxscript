import ModeCases.Case;
import hxscript.Environment;
import hxscript.Module;
import hxscript.cppia.Backend;
import hxscript.compile.Result;
import hxscript.syntax.Parser;
import hxscript.types.ScriptedClass;

/**
 * The timing harness for the three execution modes.
 *
 * Same rules as the cross-library suite in `xbench`, and deliberately so, because the two documents
 * are read together: `prepare` is untimed and `exec` is timed, every rep re-prepares, the reported
 * figure is the median of five, and every case is checked against a known value.
 *
 * What `prepare` means differs by mode, and that difference is the whole point of the exercise
 * rather than something to hide. Interpreting prepares by parsing and building an environment;
 * compiling prepares by parsing, emitting bytecode and booting a module, which is far more work. It
 * stays untimed here because it is paid once and the loop is paid every frame, but it is measured
 * separately at the end, since a compiler that never earns back its own cost is not a speedup.
 *
 * JIT is a process-wide switch, so it cannot share a process with the mode it is being compared
 * against. One case per process was already required for the cross-library suite; here it is what
 * makes the third mode possible at all.
 *
 * Output is one machine-readable line per case:
 *   R|<mode>|<case>|<tier>|<iterations>|<status>|<median ms>|<value>
 */
class MBench {
	static inline var REPS:Int = 5;

	/**
	 * The MEDIAN of the reps, not the fastest.
	 *
	 * Best-of-N answers "how fast can this go when nothing interferes", which flatters whichever run
	 * got the quietest slice of the machine. The median answers "what does this usually cost", which
	 * is the question a host budgeting a frame is asking.
	 */
	static function median(xs:Array<Float>):Float {
		xs.sort(function(a:Float, b:Float):Int return (a < b) ? -1 : ((a > b) ? 1 : 0));
		return xs[Std.int(xs.length / 2)];
	}

	public static function main():Void {
		var args:Array<String> = Sys.args();
		var mode:String = args.length > 0 ? args[0] : 'interp';
		var only:String = args.length > 1 ? args[1] : null;
		var iters:Int = args.length > 2 ? Std.parseInt(args[2]) : 100000;

		if (mode == 'jit') {
			cpp.cppia.Host.enableJit(true);
		}

		if (only == '__list') {
			for (c in ModeCases.all(iters)) {
				Sys.println(c.n);
			}
			return;
		}

		if (only == '__prepare') {
			prepareBench(mode);
			return;
		}

		if (only == '__save') {
			// Writes compiled bytes to disk, to find out whether a later process can load them.
			var src:String = 'package p;\nclass T {\n\tpublic static function run():Dynamic { return 40 + 2; }\n}\n';
			var decls = new Parser().parseModule(src, 'cache', 0, ['p']);
			var r:Result = Backend.compile([{name: 'p.T', decls: decls}]);
			sys.io.File.saveBytes('bin_mbench/cached.cppia', r.bytes);
			Sys.println('saved ' + r.bytes.length + ' bytes');
			return;
		}

		if (only == '__load') {
			// No parser, no emitter: only the loader, on bytes produced by an earlier process.
			var bytes = sys.io.File.getBytes('bin_mbench/cached.cppia');
			var m = cpp.cppia.Module.fromData(bytes.getData());
			m.boot();
			var cls = m.resolveClass('p.T');
			Sys.println('loaded -> ' + Reflect.callMethod(null, Reflect.field(cls, 'run'), []));
			return;
		}
		if (only == '__compr') {
			comprBench(mode);
			return;
		}

		for (c in ModeCases.all(iters)) {
			if (only != null && c.n != only) {
				continue;
			}
			runCase(mode, c);
		}
	}

	/**
	 * Every comprehension shape the emitter has to lower, run in whichever mode was asked for.
	 *
	 * Not a timing. It exists because a comprehension compiled to the wrong thing once already, and
	 * the answers here are meant to be read against the interpreted column rather than against what
	 * anyone believes they should be.
	 */
	static function comprBench(mode:String):Void {
		var cases:Array<Array<String>> = [
			['plain', '[for (k in 0...5) k]'],
			['filter', '[for (k in 0...6) if (k % 2 == 0) k]'],
			['ifelse', '[for (k in 0...4) if (k > 1) k else -k]'],
			['nested', '[for (a in 0...3) for (b in 0...2) a * 10 + b]'],
			['block', '[for (k in 0...3) { var d:Int = k * 2; d + 1; }]'],
			['overArray', '[for (v in [7, 8, 9]) v * 2]'],
			['nestedFilter', '[for (a in 0...3) for (b in 0...3) if (a == b) a]'],
			['keyValue', '[for (k => v in ["a" => 1]) v]'],
			['empty', '[for (k in 0...0) k]'],
			['emptyTyped', '[for (k in 0...0) k]'],
			['emptyLiteral', '[]'],
			['oneElem', '[9]'],
			['typedRead', '[for (k in 0...5) k]'],
			['typedNested', '[for (k in 0...5) k]'],
			['nullValue', '[for (k in 0...2) null]'],
			['mapCompr', '[for (k in 0...3) k => k * 2]']
		];

		for (c in cases) {
			var typed:Bool = c[0] == 'emptyTyped' || c[0] == 'typedRead' || c[0] == 'typedNested';
			var decl:String = '\t\tvar a:' + (typed ? 'Array<Int>' : 'Dynamic') + ' = ' + c[1] + ';' + '\n';

			var tail:String;
			if (c[0] == 'typedRead') {
				tail = '\t\treturn Std.string(a[a.length - 1]);\n';
			} else if (c[0] == 'typedNested') {
				// The shape the corpus uses: a typed comprehension built inside a loop and read back.
				decl = '';
				tail = '\t\tvar q:Int = 0;\n'
					+ '\t\tfor (z in 0...2) { var b:Array<Int> = ' + c[1] + '; q = b[b.length - 1]; }\n'
					+ '\t\treturn Std.string(q);\n';
			} else {
				tail = '\t\treturn Std.string(a);\n';
			}

			var src:String = 'package p;\nclass T {\n\tpublic static function run():Dynamic {\n'
				+ decl + tail + '\t}\n}\n';

			var got:String;
			try {
				got = Std.string(Reflect.callMethod(null, prepare(mode, src), []));
			} catch (e:Dynamic) {
				got = 'REFUSED: ' + e;
			}

			Sys.println(StringTools.rpad(mode, ' ', 8) + StringTools.rpad(c[0], ' ', 14) + got);
		}
	}

	static function runCase(mode:String, c:Case):Void {
		var handle:Dynamic = null;
		var refused:String = null;

		try {
			handle = prepare(mode, c.s);
		} catch (e:Dynamic) {
			refused = shorten(Std.string(e));
		}

		if (handle == null) {
			line(mode, c, 'unsupported', -1, refused == null ? 'refused' : refused);
			return;
		}

		var times:Array<Float> = [];
		var value:Dynamic = null;
		var failed:String = null;

		for (r in 0...REPS) {
			try {
				// Re-prepared every rep, so a mode that mutates its program in place or warms a cache
				// on the first run is measured on the same footing as one that does not.
				var h:Dynamic = prepare(mode, c.s);
				var t0:Float = haxe.Timer.stamp();
				value = Reflect.callMethod(null, h, []);
				times.push(haxe.Timer.stamp() - t0);
			} catch (e:Dynamic) {
				failed = shorten(Std.string(e));
				break;
			}
		}

		if (failed != null) {
			line(mode, c, 'unsupported', -1, 'run: ' + failed);
			return;
		}

		var got:String = Std.string(value);
		line(mode, c, got == c.x ? 'ok' : 'wrong', median(times) * 1000, got);
	}

	/**
	 * Builds a case and hands back the `run` it declares.
	 *
	 * @param mode `interp`, `cppia` or `jit`.
	 * @param src The module source.
	 * @return The static to call, or null if this mode cannot take the source.
	 */
	static function prepare(mode:String, src:String):Dynamic {
		if (mode == 'interp') {
			// The constructor parses, so handing it the source is the whole of it. Passing an empty
			// string and parsing afterwards fails the package check on the empty parse.
			var env:Environment = new Environment();
			var module:Module = new Module(src, 'T', ['p'], 'mbench');
			env.addModule(module);
			module.init(env);
			module.start(env);
			module.startTypes(env);

			var cls:ScriptedClass = cast env.resolve('p.T');
			return cls == null ? null : cls.reflectGetField('run');
		}

		var decls:Dynamic = new Parser().parseModule(src, 'mbench', 0, ['p']);
		var result:Result = Backend.compile([{name: 'p.T', decls: decls}]);
		if (result.bytes == null) {
			// Thrown rather than returned as null so the reason reaches the results file. Which
			// constructs the compiler declines is half of what this benchmark is reporting.
			throw result.skipped.length > 0 ? result.skipped[0].reason : 'refused';
		}

		var module:cpp.cppia.Module = cpp.cppia.Module.fromData(result.bytes.getData());
		module.boot();

		var cls:Class<Dynamic> = module.resolveClass('p.T');
		return cls == null ? null : Reflect.field(cls, 'run');
	}

	/**
	 * What each mode charges to get one realistic source ready to run.
	 *
	 * The only place `prepare` is timed. Reported on its own because it is the number that decides
	 * whether compiling is worth doing at all: it is paid once per module, against a saving paid per
	 * iteration, so the two together give the break-even point rather than a ranking.
	 */
	static function prepareBench(mode:String):Void {
		var src:String = ModeCases.prepareSource();
		var times:Array<Float> = [];
		var ok:Bool = true;

		for (r in 0...REPS) {
			try {
				var t0:Float = haxe.Timer.stamp();
				var h:Dynamic = prepare(mode, src);
				times.push(haxe.Timer.stamp() - t0);
				if (h == null) {
					ok = false;
					break;
				}
			} catch (e:Dynamic) {
				ok = false;
				break;
			}
		}

		Sys.println('P|' + mode + '|' + src.length + '|' + (ok ? Std.string(Std.int(median(times) * 1e6) / 1000) : 'unsupported'));
	}

	static function line(mode:String, c:Case, status:String, ms:Float, value:String):Void {
		var t:String = ms < 0 ? '-' : Std.string(Std.int(ms * 1000) / 1000);
		Sys.println('R|' + mode + '|' + c.n + '|' + c.t + '|' + c.i + '|' + status + '|' + t + '|' + value);
	}

	static function shorten(s:String):String {
		s = StringTools.replace(StringTools.replace(s, '\n', ' '), '|', '/');
		return s.length > 70 ? s.substr(0, 70) : s;
	}
}
