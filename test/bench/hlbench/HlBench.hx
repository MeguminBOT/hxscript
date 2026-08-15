import ModeCases.Case;
#if hxscript_hl
import hxscript.Environment;
import hxscript.Module;
import hxscript.compile.Compiler;
import hxscript.compile.Report;
import hxscript.types.ScriptedClass;
#end

/**
 * What a script costs on HashLink against the same program compiled by Haxe.
 *
 * The other two benchmark suites both compare like with like: `xbench` puts six interpreters beside
 * each other, and `mbench` puts one library's three hxcpp modes beside each other. Neither answers
 * the question a host actually asks before moving logic into a script, which is what it costs
 * against not scripting it at all. This one does, on HashLink, in four columns:
 *
 *   hashlink/vm      the corpus written as Haxe, compiled to `.hl`, run by the VM
 *   hashlink/c       the same Haxe, compiled to C and linked as a native binary
 *   hxscript hl/c    the corpus as SCRIPTS, compiled to HashLink bytecode at run time
 *   hxscript interp  the same scripts, walked as a tree
 *
 * The first two are the floor: what the language costs when Haxe has seen the code. The last two are
 * what the library charges on top, and the gap between the third and the first is the number worth
 * knowing, because that is the price of the code being editable after you shipped.
 *
 * Three of the four columns come out of ONE binary, on purpose. `native`, `hxs-hl` and `hxs-interp`
 * are modes of this program, so the compiled Haxe and the scripts are measured in the same process,
 * by the same clock, against the same allocator. Only `hashlink/vm` is a second build, because
 * running on the VM is the thing being measured.
 *
 * Same timing rules as the other two suites, deliberately, since the three documents are read
 * together: preparing is untimed, every rep re-prepares, the figure reported is the median of five,
 * and every case is checked against a known value so that a mode which skips the work is caught
 * rather than recorded as instant.
 *
 * Output is one machine-readable line per case:
 *   R|<mode>|<case>|<tier>|<iterations>|<status>|<median ms>|<value>
 */
class HlBench {
	static inline var REPS:Int = 5;

	/**
	 * The MEDIAN of the reps rather than the fastest, for the reason `MBench` gives: best-of-N
	 * reports how fast a thing goes when nothing interferes, and a host budgeting a frame is asking
	 * what it usually costs.
	 */
	static function median(xs:Array<Float>):Float {
		xs.sort(function(a:Float, b:Float):Int return (a < b) ? -1 : ((a > b) ? 1 : 0));
		return xs[Std.int(xs.length / 2)];
	}

	public static function main():Void {
		var args:Array<String> = Sys.args();
		var mode:String = args.length > 0 ? args[0] : 'native';
		var only:String = args.length > 1 ? args[1] : null;
		var iters:Int = args.length > 2 ? Std.parseInt(args[2]) : NativeCases.SCALE;

		if (only == '__list') {
			for (name in NativeCases.names())
				Sys.println(name);
			return;
		}

		/**
		 * A natively compiled case has its loop bound written into it, so it can only be run at the
		 * scale it was generated for. Refused rather than silently run at the wrong one, because two
		 * columns measured at two scales look like a result.
		 */
		if (iters != NativeCases.SCALE) {
			Sys.println('R|$mode|-|-|$iters|unsupported|-|built for n=' + NativeCases.SCALE);
			return;
		}

		if (only == '__prepare') {
			prepareBench(mode, iters);
			return;
		}

		var byName:Map<String, Case> = new Map();
		for (c in ModeCases.all(iters))
			byName.set(c.n, c);

		for (name in NativeCases.names()) {
			if (only != null && name != only)
				continue;

			var c:Case = byName.get(name);
			if (c == null)
				continue;

			runCase(mode, c);
		}
	}

	/**
	 * Runs one case in one mode and reports what it cost.
	 *
	 * @param mode `native`, `hxs-hl` or `hxs-interp`.
	 * @param c The case.
	 */
	static function runCase(mode:String, c:Case):Void {
		if (mode == 'native') {
			runNative(c);
			return;
		}

		#if !hxscript_hl
		line(mode, c, 'unsupported', -1, 'built without the library');
		#else
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
				// Re-prepared every rep, so a mode that warms a cache on its first run is measured on
				// the same footing as one that does not.
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
		#end
	}

	/**
	 * Runs the compiled-by-Haxe version of a case.
	 *
	 * Nothing to prepare: it was compiled when this binary was built, which is the whole of what the
	 * column is here to show. The reps are still taken and the median still reported, so the figure
	 * beside it was arrived at the same way.
	 *
	 * @param c The case, for its name and expected value.
	 */
	static function runNative(c:Case):Void {
		var why:Null<String> = NativeCases.skipped(c.n);
		if (why != null) {
			line('native', c, 'unsupported', -1, why);
			return;
		}

		var times:Array<Float> = [];
		var value:Dynamic = null;

		for (r in 0...REPS) {
			var t0:Float = haxe.Timer.stamp();
			value = NativeCases.run(c.n);
			times.push(haxe.Timer.stamp() - t0);
		}

		var got:String = Std.string(value);
		line('native', c, got == c.x ? 'ok' : 'wrong', median(times) * 1000, got);
	}

	/**
	 * Builds a case and hands back the `run` it declares.
	 *
	 * @param mode `hxs-hl` or `hxs-interp`.
	 * @param src The module source.
	 * @return The static to call, or null when this mode cannot take the source.
	 */
	#if hxscript_hl
	static function prepare(mode:String, src:String):Dynamic {
		var env:Environment = new Environment();
		var module:Module = new Module(src, 'T', ['p'], 'hlbench');
		env.addModule(module);
		module.init(env);
		module.start(env);
		module.startTypes(env);

		if (mode == 'hxs-hl') {
			var report:Report = Compiler.compile(env, [module]);

			/**
			 * A refused module falls back to the interpreter silently, which would file an
			 * interpreted time under the compiled column. Reported as unsupported instead, since a
			 * row that is really the other column is worse than a missing row.
			 */
			if (report.compiled.indexOf('p.T.run') < 0)
				return null;
		}

		var cls:ScriptedClass = cast env.resolve('p.T');
		return cls == null ? null : cls.reflectGetField('run');
	}
	#end

	/**
	 * What each mode charges to get ready, which does not scale with the loop count and so is
	 * measured once rather than per case.
	 *
	 * `native` pays nothing here and says so: its preparation happened in the build that produced
	 * this binary, and pretending otherwise would hide the one cost the scripted columns carry that
	 * it does not.
	 *
	 * @param mode The mode.
	 * @param iters The scale, reported so the line can be read beside the others.
	 */
	static function prepareBench(mode:String, iters:Int):Void {
		if (mode == 'native') {
			Sys.println('P|native|0|compiled into the binary');
			return;
		}

		#if !hxscript_hl
		Sys.println('P|$mode|0|built without the library');
		#else
		var src:String = ModeCases.prepareSource();
		var times:Array<Float> = [];

		for (r in 0...REPS) {
			var t0:Float = haxe.Timer.stamp();
			try {
				prepare(mode, src);
			} catch (e:Dynamic) {
				Sys.println('P|$mode|0|' + shorten(Std.string(e)));
				return;
			}
			times.push(haxe.Timer.stamp() - t0);
		}

		Sys.println('P|$mode|' + fmt(median(times) * 1000) + '|ok');
		#end
	}

	/**
	 * Writes one result line.
	 *
	 * Flushed per line, so a row still sitting in a buffer when a case ends the process does not
	 * blame the wrong case.
	 */
	static function line(mode:String, c:Case, status:String, ms:Float, value:String):Void {
		Sys.println('R|'
			+ mode
			+ '|'
			+ c.n
			+ '|'
			+ c.t
			+ '|'
			+ c.i
			+ '|'
			+ status
			+ '|'
			+ (ms < 0 ? '-' : fmt(ms))
			+ '|'
			+ flatten(value));
		Sys.stdout().flush();
	}

	static function fmt(ms:Float):String {
		return Std.string(Math.round(ms * 1000) / 1000);
	}

	static function flatten(v:String):String {
		var flat:String = StringTools.replace(v, '\r', ' ');
		flat = StringTools.replace(flat, '\n', ' ');
		return StringTools.replace(flat, '|', '/');
	}

	static function shorten(v:String):String {
		var flat:String = flatten(v);
		return flat.length > 90 ? flat.substr(0, 87) + '...' : flat;
	}
}
