import insanity.Script;

/**
 * Runner for hscript-insanity.
 *
 * hscript-insanity is still `insanity`; this library is the one that moved, to `hxscript`. One runner cannot
 * import both, and the shared runner built against hscript-insanity failed to resolve its import and was
 * skipped silently, since a build failure here drops a library rather than stopping the suite. That took the
 * column out of the comparison without taking anything out of the document.
 *
 * The body is deliberately identical to `RunHxScript`'s. Any difference between them would show up
 * as a difference between the libraries.
 */
class RunInsanity {
	static function main():Void {
		XBench.run(Sys.args()[0], prepare, exec);
	}

	static function prepare(src:String):Dynamic {
		// `Script`'s constructor parses, so it is handed an empty source and the real one is parsed
		// once, after the hooks are installed. Constructing with `src` and re-parsing to install them
		// meant this ran the parser TWICE, which every other runner does once, and `prepare` is
		// exactly what the parse-throughput case times, so it reported roughly double.
		var s = new Script("", "bench");
		s.onParsingError = function(e) {};
		s.onProgramError = function(e) {};
		s.parse(src);
		return (s.program == null) ? null : s;
	}

	static function exec(h:Dynamic):Dynamic {
		var s:Script = cast h;
		var v:Dynamic = s.start();
		if (s.failed)
			throw "script failed";
		return v;
	}
}
