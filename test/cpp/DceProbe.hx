import hxscript.Script;
import hxscript.syntax.Expr.ImportMode;

/**
 * Checks that the standard-library members scripts reach are still there.
 *
 * Meant to be built BOTH ways: with the library's keep macro and with `-D hxscript_no_keep`, under
 * `-dce std`. The difference between the two runs is what the macro is for.
 */
class DceProbe {
	static function p(name:String, src:String, want:String):Void {
		var s = new Script("res='<none>'; try { res = Std.string(" + src + "); } catch (e:Dynamic) { res='THREW: '+e; }", "d");
		s.onParsingError = function(e:haxe.Exception) {};
		s.onProgramError = function(e:haxe.Exception) {};
		s.start();

		TestCase.gap(StringTools.rpad(name, " ", 22), Std.string(s.variables.get("res")), want);
	}

	public static function run():Void {
		Sys.println("kept: " + hxscript.macro.Keep.types.join(", "));
		Sys.println("");

		p("IntIterator", "{ var t=0; for (i in 0...4) t+=i; t; }", "6");
		p("Reflect", "Reflect.field({a:5}, 'a')", "5");
		p("Type", "Type.getClassName(Type.resolveClass('String'))", "String");
		p("haxe.ds.StringMap", "{ var m=new haxe.ds.StringMap(); m.set('k',7); m.get('k'); }", "7");
		p("EReg", "{ var r=~/a(b+)/; r.match('abbb'); r.matched(1); }", "bbb");
		// `List` is a typedef to `haxe.ds.List`. Kept for the class it names; the bare alias is a
		// separate matter, and an import resolves it.
		p("List (bare)", "{ var l=new List(); l.add(3); l.add(4); l.length; }", "2");
		p("List (import)", "{ var l=new haxe.ds.List(); l.add(3); l.add(4); l.length; }", "2");
		p("Date", "Date.fromTime(0).getTime()", "0");
		p("Sys", "Sys.systemName() != null", "true");

		Sys.println("");
		TestCase.log(TestCase.gaps == 0 ? "  all reachable" : "  " + TestCase.gaps + " unreachable");
	}

	static function main():Void {
		run();
		TestCase.exit();
	}
}
