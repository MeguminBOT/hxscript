import rulescript.RuleScript;

/** Runner for RuleScript. */
class RunRuleScript {
	static function main():Void {
		XBench.run(Sys.args()[0], prepare, exec);
	}

	static function prepare(src:String):Dynamic {
		var rs = new RuleScript();
		return {rs: rs, ast: rs.parser.parse(src)};
	}

	static function exec(h:Dynamic):Dynamic {
		var rs:RuleScript = h.rs;
		return rs.execute(cast h.ast);
	}
}
