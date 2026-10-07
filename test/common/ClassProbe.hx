import hxscript.Script;

class ClassProbe {
	static function p(n:String, decl:String, expr:String, want:String) {
		var s = new Script(decl + "\nres='<none>'; try { res = Std.string(" + expr + "); } catch (e:Dynamic) { res='THREW: '+e; }", "c");
		s.onProgramError = function(e:haxe.Exception) {};
		s.start();
		TestCase.gap(n, Std.string(s.variables.get("res")), want);
	}

	public static function run():Void {
		var base = "class A { public var v:Int = 1; public function new() {} public function who() return 'A'; public function twice() return v*2; }\n";
		p("basic class", base, "{ var a = new A(); a.who() + a.twice(); }", "A2");
		p("ctor args", "class B { public var n:Int; public function new(n:Int) { this.n = n; } }\n", "new B(7).n", "7");
		p("inheritance", base + "class C extends A { public function new() { super(); } override public function who() return 'C'; }\n",
			"{ var c = new C(); c.who() + c.twice(); }", "C2");
		p("super call", base + "class D extends A { public function new() { super(); } override public function who() return 'D' + super.who(); }\n",
			"new D().who()", "DA");
		p("static field", "class E { public static var count:Int = 5; public static function get() return count; public function new() {} }\n",
			"E.get() + E.count", "10");
		p("property get/set",
			"class F { public var p(get,set):Int; var _p:Int=3; function get_p() return _p*2; function set_p(v) { _p=v; return v; } public function new() {} }\n",
			"{ var f=new F(); f.p = 5; f.p; }", "10");
		p("toString", "class G { public function new() {} public function toString() return 'G!'; }\n", "Std.string(new G())", "G!");
		p("interface impl",
			"interface I { public function m():String; }\nclass H implements I { public function new() {} public function m() return 'hi'; }\n",
			"{ var h = new H(); (h is I) + ':' + h.m(); }", "true:hi");
		p("scripted enum", "enum Col { Red; Blue(shade:Int); }\n", "{ var c = Blue(3); switch(c) { case Red: 'r'; case Blue(s): 'b'+s; } }", "b3");
		// A guard must not run when its pattern did not match: the capture variables are unbound
		// there, so evaluating it errors on a name that was never set.
		var guards = "enum G { A(x:Int); B(y:Int); C; }
";
		p("guard taken", guards, "switch (A(9)) { case A(x) if (x > 5): 'big'+x; case A(x): 'small'+x; case B(y): 'b'; case C: 'c'; }", "big9");
		p("guard rejected", guards, "switch (A(1)) { case A(x) if (x > 5): 'big'+x; case A(x): 'small'+x; case B(y): 'b'; case C: 'c'; }", "small1");
		p("guard skipped, other ctor", guards, "switch (B(2)) { case A(x) if (x > 5): 'big'; case A(x): 'small'; case B(y): 'b'+y; case C: 'c'; }", "b2");
		p("guard skipped, no-arg ctor", guards, "switch (C) { case A(x) if (x > 5): 'big'; case A(x): 'small'; case B(y): 'b'; case C: 'c'; }", "c");
		p("enum equality", "enum Col2 { X; Y; }\n", "{ (X == X) + ',' + (X == Y); }", "true,false");
		p("static in method", "class J { static var s = 2; public function new() {} public function m() return s * 3; }\n", "new J().m()", "6");
		// Haxe has every static function before any initialiser runs, whatever their order.
		p("static initialiser calls a function below it",
			"class J2 { public static var s:Int = twice(4); static function twice(n:Int):Int return n * 2; }\n", "J2.s", "8");
		p("field default", "class K { public var arr:Array<Int> = [1,2]; public function new() {} }\n", "new K().arr.length", "2");
		p("nested new", base, "{ var xs = [for (i in 0...3) new A()]; xs.length + ':' + xs[0].who(); }", "3:A");
		p("this in closure", "class L { public var v=9; public function new() {} public function m() { var f = function() return v; return f(); } }\n",
			"new L().m()", "9");
	}

	static function main():Void {
		run();
		TestCase.exit();
	}
}
