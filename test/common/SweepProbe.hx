import hxscript.Script;

class SweepProbe {
	static function p(n:String, src:String, want:String) {
		var s = new Script("res='<none>'; try { res = Std.string(" + src + "); } catch (e:Dynamic) { res='THREW: '+e; }", "s");
		s.onParsingError = function(e:haxe.Exception) {};
		s.onProgramError = function(e:haxe.Exception) {};
		s.start();
		TestCase.gap(n, Std.string(s.variables.get("res")), want);
	}

	static function raw(n:String, src:String, want:String) {
		var s = new Script(src, "s");
		s.onParsingError = function(e:haxe.Exception) TestCase.log("  GAP   " + n + " PARSE: " + e.message);
		s.onProgramError = function(e:haxe.Exception) TestCase.log("  GAP   " + n + " RUN: " + e.message);
		s.start();
		TestCase.gap(n, Std.string(s.variables.get("res")), want);
	}

	static inline var BS:String = "\\";

	/**
	 * Checks that printing a parsed expression produces source that parses back to the same value.
	 *
	 * @param name What is being checked.
	 * @param source The script source to round-trip.
	 */
	static function roundTrip(name:String, source:String) {
		var parser = new hxscript.syntax.Parser();
		parser.allowTypes = parser.allowJSON = parser.allowMetadata = true;

		var printed:String = new hxscript.syntax.Printer().exprToString(parser.parseScript(source, "rt"));

		function run(src:String):String {
			var s = new Script("res = " + src, "rt");
			s.onParsingError = function(e:haxe.Exception) {};
			s.onProgramError = function(e:haxe.Exception) {};
			s.start();
			return Std.string(s.variables.get("res"));
		}

		var want:String = run(source);
		var got:String = run(printed);

		TestCase.gap(name + ' => printed ' + printed, got, want);
	}

	public static function run():Void {
		trace("-- numeric edges --");
		p("int div neg", "Std.int(-7 / 2)", "-3");
		p("mod neg", "-7 % 3", "-1");
		p("bit ops", "(6 & 3) + (6 | 3) + (6 ^ 3)", "14");
		p("shifts", "(1 << 4) + (16 >> 2) + (-8 >>> 28)", "35");
		p("postfix vs pre", "{ var i=1; var a=i++; var b=++i; a*10+b; }", "13");
		p("compound field", "{ var o={v:1}; o.v += 5; o.v; }", "6");
		p("compound arr", "{ var a=[1]; a[0] *= 7; a[0]; }", "7");
		p("num to string", "1 + 2 + 'x' + 1 + 2", "3x12");
		p("float fmt", "0.5 + 0.25", "0.75");
		// An exponent used to be applied as `* Math.pow(10, -k)`, which is not correctly rounded, so
		// `1e-5` and `0.00001` were different doubles.
		p("neg exponent", "1e-5 == 0.00001", "true");
		p("pos exponent", "1.5e3", "1500");
		p("exponent of a fraction", "2.5e-3 == 0.0025", "true");
		trace("-- preprocessor --");
		raw("if define", "#if hxscript\nres='yes';\n#else\nres='no';\n#end", "yes");
		raw("if not def", "#if nope\nres='yes';\n#else\nres='no';\n#end", "no");
		raw("elseif", "#if nope\nres='a';\n#elseif hxscript\nres='b';\n#else\nres='c';\n#end", "b");
		raw("nested pp", "#if hxscript\n#if nope\nres='x';\n#else\nres='y';\n#end\n#end", "y");
		trace("-- strings / lexer --");
		p("escapes", "'a\tb\nc'.length", "5");
		p("unicode esc", "'\u0041'", "A");
		p("nested interp", "{ var a=[1,2]; '${a[0] + a[1]}'; }", "3");
		p("interp field", "{ var o={n:'z'}; 'v=${o.n}'; }", "v=z");
		p("regex replace", "~/a+/g.replace('aaXaa','-')", "-X-");
		p("dquote no interp", "{ var v=1; \"$v\"; }", "$v");
		trace("-- printing round-trip --");
		// A printed expression has to parse back to the same value: escaping the quotes but not the
		// backslashes meant a string holding one stopped round-tripping.
		roundTrip("plain", "'hello'");
		roundTrip("quote", "'say " + String.fromCharCode(34) + "hi" + String.fromCharCode(34) + "'");
		roundTrip("backslash", "'a" + BS + BS + "b'");
		roundTrip("tab", "'a\tb'");
		// `identChars` includes digits, but an identifier cannot start with one, so `$5` is literal.
		roundTrip("dollar then digit", "'costs $5'");
		// A cast printed its type through the declaration helper, which prefixes ` : `, so the output
		// was `cast(v, : T)` and did not parse.
		roundTrip("cast to type", "cast(5, Float)");
		roundTrip("check type", "(5 : Float)");

		trace("-- errors --");
		p("multi-catch", "{ try { throw 5; } catch (s:String) { 'str'; } catch (i:Int) { 'int'; } }", "int");
		p("rethrow", "{ try { try { throw 'x'; } catch (e:Dynamic) { throw e; } } catch (e:Dynamic) { 'outer:'+e; } }", "outer:x");
		p("null safe", "{ var o = null; o?.field; }", "null");
		p("catch order", "{ try { throw 'a'; } catch (e:Int) { 'i'; } catch (e:String) { 's'; } }", "s");
		trace("-- imports / using --");
		raw("import alias", "import Math as M;\nres = M.max(1,2);", "2");
		raw("import field", "import Math.abs;\nres = abs(-3);", "3");
		raw("using ext", "using StringTools;\nres = 'ab'.startsWith('a');", "true");

		trace("-- declaration modifiers --");
		raw("final class", "final class SwF { public function new() {} public function v() return 3; }\nres = new SwF().v();", "3");
		raw("abstract class", "abstract class SwA { public function new() {} public function v() return 4; }\nres = new SwA().v();", "4");
		raw("extern member", "class SwE { public function new() {} public extern function v() return 7; }\nres = new SwE().v();", "7");
		raw("abstract member", "abstract class SwB { public function new() {} public abstract function v():Int; }\nres = 8;", "8");
		raw("final still a var", "final n = 9;\nres = n;", "9");
		raw("untyped", "res = untyped 5;", "5");
	}

	static function main():Void {
		run();
		TestCase.exit();
	}
}
