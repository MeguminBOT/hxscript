import hxscript.Script;
import hxscript.syntax.Expr;
import hxscript.syntax.Parser;
import TestCase.eq;

/**
 * The escapes of a regular-expression literal.
 *
 * A regular expression has escapes of its own, `\d`, `\.`, `\\`, which mean something to it and
 * nothing to a string. They were read as a string's: `~/\d+/` was refused with
 * `Invalid character: 'd'`, and `~/a\\b/` lost a backslash and looked for a word boundary. Haxe's
 * lexer decodes `\/`, `\n`, `\r` and `\t` and hands every other one to the pattern as written.
 *
 * The patterns are compared as text, which says what the lexer did on every target, and a few are
 * run against the same literal compiled by Haxe.
 */
class RegexTest {
	/** @return The pattern of the regular-expression literal `src` is, null when it is refused. */
	static function pattern(src:String):Null<String> {
		var parser = new Parser();
		parser.allowTypes = parser.allowJSON = parser.allowMetadata = true;

		try {
			return find(parser.parseScript(src + ';', 'RegexTest'));
		} catch (e:Dynamic) {
			return null;
		}
	}

	/** @return The pattern of the first regular expression of `e`. */
	static function find(e:Expr):Null<String> {
		if (e == null)
			return null;

		return switch (e.e) {
			case EConst(CReg(p, _)): p;
			case EBlock(list): list.length > 0 ? find(list[0]) : null;
			case EParent(inner): find(inner);
			case _: null;
		}
	}

	static function ev(b:String):Dynamic {
		var s = new Script("result = (" + b + ");", "r");
		s.onProgramError = function(e:haxe.Exception) trace("ERR " + e.message);
		s.start();
		return s.variables.get("result");
	}

	public static function run():Void {
		eq("class escape", pattern("~/^panel_\\d+$/"), "^panel_\\d+$");
		eq("every class escape", pattern("~/\\w\\W\\b\\B\\s\\S\\d\\D/"), "\\w\\W\\b\\B\\s\\S\\d\\D");
		eq("escaped metacharacters", pattern("~/\\$\\.\\*\\+\\^\\|\\{\\}\\[\\]\\(\\)\\?\\-/"),
			"\\$\\.\\*\\+\\^\\|\\{\\}\\[\\]\\(\\)\\?\\-");
		eq("escaped backslash", pattern("~/a\\\\b/"), "a\\\\b");
		eq("back reference", pattern("~/(a)\\1/"), "(a)\\1");
		eq("hexadecimal escape", pattern("~/\\x41/"), "\\x41");
		eq("unicode escape", pattern("~/\\u00e9\\U00E9/"), "\\u00e9\\U00E9");
		eq("escaped slash", pattern("~/a\\/b/"), "a/b");
		eq("newline, return and tab", pattern("~/a\\nb\\rc\\td/"), "a\nb\rc\td");

		eq("unknown escape refused", pattern("~/\\q/"), null);
		eq("short unicode escape refused", pattern("~/\\u00g9/"), null);

		eq("digits match", ev("~/^panel_\\d+$/.match('panel_12')"), ~/^panel_\d+$/.match('panel_12'));
		eq("digits do not match", ev("~/^panel_\\d+$/.match('panel_x')"), ~/^panel_\d+$/.match('panel_x'));
		eq("dot is a dot", ev("~/^a\\.b$/.match('axb')"), ~/^a\.b$/.match('axb'));
		eq("backslash is a backslash", ev("~/^a\\\\b$/.match('a\\\\b')"), ~/^a\\b$/.match('a\\b'));
		eq("slash is a slash", ev("~/^a\\/b$/.match('a/b')"), ~/^a\/b$/.match('a/b'));
		eq("group after escapes",
			ev("{ var r = ~/(\\w+)\\s*=\\s*(\\d+)/; r.match('hp = 12') ? r.matched(1) + r.matched(2) : 'no'; }"),
			"hp12");
		eq("replace on a class", ev("~/\\s+/g.replace('a  b \\t c', '-')"), ~/\s+/g.replace('a  b \t c', '-'));
	}

	static function main():Void {
		run();
		TestCase.exit();
	}
}
