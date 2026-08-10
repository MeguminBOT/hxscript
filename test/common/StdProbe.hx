import hxscript.Script;

/**
 * Calls every standard-library member the shim table covers, from a script.
 *
 * These are members with no runtime form of their own, either `inline` in the standard library or, on
 * python, a static over a builtin. Nothing a host compiles references them, so whether a script can reach
 * one depends on the shim table rather than on the standard library, and a future Haxe release turning an
 * ordinary method `inline` would otherwise surface as a user's bug report.
 */
class StdProbe {
	/**
	 * Evaluates an expression in a script and compares the result.
	 *
	 * @param name What is being checked.
	 * @param body The expression to evaluate.
	 * @param want The expected result.
	 */
	static function p(name:String, body:String, want:String):Void {
		var s = new Script("res = '<none>'; try { res = Std.string(" + body + "); } catch (e:Dynamic) res = 'THREW: ' + e;", "std");
		s.onParsingError = function(e:haxe.Exception) {};
		s.onProgramError = function(e:haxe.Exception) {};
		s.start();
		TestCase.gap(name, Std.string(s.variables.get("res")), want);
	}

	public static function run():Void {
		trace("-- StringTools --");
		p("hex", "StringTools.hex(255, 4)", "00FF");
		p("lpad", "StringTools.lpad('7', '0', 3)", "007");
		p("rpad", "StringTools.rpad('7', '0', 3)", "700");
		p("startsWith", "StringTools.startsWith('abc', 'ab')", "true");
		p("startsWith false", "StringTools.startsWith('abc', 'bc')", "false");
		p("endsWith", "StringTools.endsWith('abc', 'bc')", "true");
		p("contains", "StringTools.contains('abc', 'b')", "true");
		p("trim", "'[' + StringTools.trim('  ab  ') + ']'", "[ab]");
		p("ltrim", "'[' + StringTools.ltrim('  ab') + ']'", "[ab]");
		p("rtrim", "'[' + StringTools.rtrim('ab  ') + ']'", "[ab]");
		p("replace", "StringTools.replace('a-b-c', '-', '+')", "a+b+c");
		p("isSpace", "StringTools.isSpace('a b', 1)", "true");
		p("fastCodeAt", "StringTools.fastCodeAt('A', 0)", "65");
		p("unsafeCodeAt", "StringTools.unsafeCodeAt('A', 0)", "65");
		p("isEof", "StringTools.isEof(0)", "true");
		p("iterator", "{ var n = 0; for (c in StringTools.iterator('abc')) n += c; n; }", "294");
		p("keyValueIterator", "{ var n = 0; for (i => c in StringTools.keyValueIterator('ab')) n += i; n; }", "1");
		p("htmlEscape", "StringTools.htmlEscape('<a>&')", "&lt;a&gt;&amp;");
		p("htmlUnescape", "StringTools.htmlUnescape('&lt;a&gt;&amp;')", "<a>&");

		trace("-- Array --");
		p("push and length", "{ var a = []; a.push(1); a.push(2); a.length; }", "2");
		p("pop", "{ var a = [1, 2]; a.pop(); }", "2");
		p("shift", "{ var a = [1, 2]; a.shift(); }", "1");
		p("unshift", "{ var a = [2]; a.unshift(1); a.join(','); }", "1,2");
		p("insert", "{ var a = [1, 3]; a.insert(1, 2); a.join(','); }", "1,2,3");
		p("remove", "{ var a = [1, 2]; a.remove(1); a.join(','); }", "2");
		p("contains", "[1, 2].contains(2)", "true");
		p("indexOf", "[1, 2, 3].indexOf(3)", "2");
		p("join", "[1, 2].join('-')", "1-2");
		p("reverse", "{ var a = [1, 2]; a.reverse(); a.join(','); }", "2,1");
		p("sort", "{ var a = [3, 1, 2]; a.sort(function(x, y) return x - y); a.join(','); }", "1,2,3");
		p("slice", "[1, 2, 3].slice(1).join(',')", "2,3");
		p("concat", "[1].concat([2]).join(',')", "1,2");
		p("copy", "[1, 2].copy().join(',')", "1,2");
		p("map", "[1, 2].map(function(x) return x * 2).join(',')", "2,4");
		p("filter", "[1, 2, 3].filter(function(x) return x > 1).join(',')", "2,3");

		trace("-- String --");
		p("split", "'a,b'.split(',').join('-')", "a-b");
		p("charAt", "'abc'.charAt(1)", "b");
		p("charCodeAt", "'A'.charCodeAt(0)", "65");
		p("indexOf", "'abc'.indexOf('c')", "2");
		p("toUpperCase", "'ab'.toUpperCase()", "AB");
		p("toLowerCase", "'AB'.toLowerCase()", "ab");
		p("substr", "'abcd'.substr(1, 2)", "bc");
		p("substring", "'abcd'.substring(1, 3)", "bc");

		trace("-- Math and Std --");
		p("Math.max", "Math.max(2, 3)", "3");
		p("Math.floor", "Math.floor(3.7)", "3");
		p("Math.abs", "Math.abs(-2)", "2");
		p("Std.int", "Std.int(3.9)", "3");
		p("Std.parseInt", "Std.parseInt('42')", "42");
		p("Std.string", "Std.string(1) + Std.string(true)", "1true");
	}

	static function main():Void {
		run();
		TestCase.exit();
	}
}
