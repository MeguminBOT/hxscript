import hxscript.Script;

class GapProbe {
	static function p(n:String, b:String, want:String) {
		var s = new Script("res='<none>'; try { res = Std.string(" + b + "); } catch (e:Dynamic) { res = 'THREW: ' + e; }", "g");
		s.onProgramError = function(e:haxe.Exception) {};
		s.start();
		TestCase.gap(n, Std.string(s.variables.get("res")), want);
	}

	public static function run():Void {
		p("map keys iter", "{ var m=['a'=>1,'b'=>2]; var n=0; var seen=''; for (k in m.keys()) { n++; if (k=='a'||k=='b') seen+='x'; } n+seen; }", "2xx");
		p("map value iter", "{ var m=['a'=>1,'b'=>2]; var t=0; for (v in m) t+=v; t; }", "3");
		p("map kv iter", "{ var m=['a'=>1]; var t=''; for (k => v in m) t += k+v; t; }", "a1");
		p("array map()", "[1,2,3].map(function(x) return x*2).join(',')", "2,4,6");
		p("array filter()", "[1,2,3,4].filter(function(x) return x%2==0).join(',')", "2,4");
		p("array sort()", "{ var a=[3,1,2]; a.sort(function(x,y) return x-y); a.join(','); }", "1,2,3");
		p("closure capture", "{ var fs=[]; for (i in 0...3) fs.push(function() return i); fs[1](); }", "1");
		p("string methods", "'Hello'.toUpperCase() + '-' + 'abc'.indexOf('b')", "HELLO-1");
		p("interpolation", "{ var n='x'; var v=2; '$n=${v*3}'; }", "x=6");
		p("switch string", "{ switch('b') { case 'a': 1; case 'b': 2; default: 0; } }", "2");
		p("ternary+coalesce", "{ var a=null; (a ?? 5) + (true ? 1 : 0); }", "6");
		p("Math/Std", "Std.int(Math.max(2.7, 1)) + Std.parseInt('10')", "12");
		p("try typed catch", "{ try { throw 'oops'; } catch (e:String) { 'caught:'+e; } }", "caught:oops");
		p("nested closure", "{ function outer() { var c=0; return function() return ++c; } var f=outer(); f(); f(); }", "2");
		p("static ext using", "{ 'a,b,c'.split(','). length; }", "3");
		p("regex", "{ var r=~/a(b+)c/; r.match('xabbcx') ? r.matched(1) : 'no'; }", "bb");
		p("array destructure", "{ switch([1,2]) { case [a,b]: a*10+b; default: 0; } }", "12");
		p("do-while", "{ var i=0; do i++; while(i<3); i; }", "3");
		p("String.fromCharCode", "String.fromCharCode(65)", "A");
		p("Reflect fields", "{ var o={a:1,b:2}; Reflect.fields(o).length; }", "2");
	}

	static function main():Void {
		run();
		TestCase.exit();
	}
}
