/**
 * The shared timing harness. Each library supplies two closures: `prepare`, which parses and builds
 * whatever the library needs (untimed), and `exec`, which runs the prepared program (timed).
 *
 * Splitting them keeps per-library setup, which differs a lot, out of the execution numbers, and
 * lets parse throughput be measured on its own.
 *
 * Output is one machine-readable line per case so the runs can be collated across binaries:
 *   R|<lib>|<case>|<tier>|<status>|<ms>|<value>
 */
class XBench {
	static inline var REPS:Int = 5;

	/**
	 * The MEDIAN of the reps, not the fastest.
	 *
	 * Best-of-N answers "how fast can this go when nothing interferes", which flatters whichever
	 * library happened to get the quietest slice of the machine. The median answers "what does this
	 * usually cost", which is the question a host budgeting a frame is actually asking, and it is
	 * robust at both ends: an unlucky scheduler spike moves it no more than a lucky one does.
	 *
	 * @param xs Timings, reordered in place.
	 * @return The middle timing.
	 */
	static function median(xs:Array<Float>):Float {
		xs.sort(function(a:Float, b:Float):Int return (a < b) ? -1 : ((a > b) ? 1 : 0));
		return xs[Std.int(xs.length / 2)];
	}

	public static function run(lib:String, prepare:String->Dynamic, exec:Dynamic->Dynamic):Void {
		// One case per process invocation: two of the libraries under test segfault outright on a
		// case, which would otherwise take the whole run down and lose every case after it.
		var only:String = (Sys.args().length > 1) ? Sys.args()[1] : null;

		// Iterations per case, so the whole corpus can be run at several scales. A difference that
		// only shows at one scale is a setup or warm-up artefact rather than a per-operation cost.
		var iters:Int = (Sys.args().length > 2) ? Std.parseInt(Sys.args()[2]) : 100000;

		if (only == "__parse") {
			parseBench(lib, prepare);
			return;
		}

		if (only == "__list") {
			for (c in BenchCases.all(iters))
				Sys.println(c.n);
			return;
		}

		for (c in BenchCases.all(iters)) {
			if (only != null && c.n != only)
				continue;
			var handle:Dynamic = null;
			var prepared:Bool = false;

			try {
				handle = prepare(c.s);
				prepared = (handle != null);
			} catch (e:Dynamic) {
				prepared = false;
			}

			if (!prepared) {
				line(lib, c, "unsupported", -1, "parse");
				continue;
			}

			var times:Array<Float> = [];
			var value:Dynamic = null;
			var failed:String = null;

			for (r in 0...REPS) {
				try {
					// Re-prepare each rep so a library that mutates its program in place, or caches
					// state on the interpreter, is measured on the same footing as one that does not.
					var h:Dynamic = prepare(c.s);
					var t0:Float = haxe.Timer.stamp();
					value = exec(h);
					times.push(haxe.Timer.stamp() - t0);
				} catch (e:Dynamic) {
					failed = shorten(Std.string(e));
					break;
				}
			}

			if (failed != null) {
				line(lib, c, "unsupported", -1, "run: " + failed);
				continue;
			}

			var got:String = Std.string(value);
			var status:String = (got == c.x) ? "ok" : "wrong";
			line(lib, c, status, median(times) * 1000, got);
		}
	}

	/** Parse throughput, on a source of realistic size. */
	static function parseBench(lib:String, prepare:String->Dynamic):Void {
		var src:String = BenchCases.parseSource();
		var times:Array<Float> = [];
		var ok:Bool = true;
		for (r in 0...REPS) {
			try {
				var t0:Float = haxe.Timer.stamp();
				prepare(src);
				times.push(haxe.Timer.stamp() - t0);
			} catch (e:Dynamic) {
				ok = false;
				break;
			}
		}
		Sys.println("P|" + lib + "|" + src.length + "|" + (ok ? Std.string(Std.int(median(times) * 1e6) / 1000) : "unsupported"));
	}

	static function line(lib:String, c:BenchCases.Case, status:String, ms:Float, value:String):Void {
		var t:String = (ms < 0) ? "-" : Std.string(Std.int(ms * 1000) / 1000);
		Sys.println("R|" + lib + "|" + c.n + "|" + c.t + "|" + c.i + "|" + status + "|" + t + "|" + value);
	}

	static function shorten(s:String):String {
		s = StringTools.replace(StringTools.replace(s, "\n", " "), "|", "/");
		return (s.length > 70) ? s.substr(0, 70) : s;
	}
}
