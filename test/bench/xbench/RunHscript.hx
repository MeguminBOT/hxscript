/** Runner for the classic hscript API, used for both hscript and hscript-improved. */
class RunHscript {
	static function main():Void {
		XBench.run(Sys.args()[0], prepare, exec);
	}

	static function prepare(src:String):Dynamic {
		var p = new hscript.Parser();
		p.allowTypes = true;
		p.allowJSON = true;
		p.allowMetadata = true;
		return {ast: p.parseString(src, "bench"), interp: new hscript.Interp()};
	}

	static function exec(h:Dynamic):Dynamic {
		var i:hscript.Interp = h.interp;
		return i.execute(h.ast);
	}
}
