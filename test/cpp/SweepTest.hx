import hxscript.Environment;
import hxscript.syntax.Expr.ImportMode;
import hxscript.Module;
import hxscript.compile.Cppia;
import hxscript.compile.Compiler;
import hxscript.syntax.Parser;
import hxscript.types.ScriptedClass;

/** A host object scripts call into, with an optional argument the script leaves off. */
class Sweep {
	public static var shared:Sweep = new Sweep();

	public function new() {}

	public function greet(word:String, ?mark:String):String {
		return word + (mark == null ? '!' : mark);
	}

	public static function tag(name:String, ?suffix:String):String {
		return name + (suffix == null ? '-' : suffix);
	}
}

/**
 * Every construct a script may reasonably use, run interpreted and compiled and compared.
 *
 * The point is the REFUSED column: anything the emitter declines is a script that silently falls
 * back to being interpreted, which is correct but is not the goal.
 */
class SweepTest {
	/** Constructs the emitter declined. Reported, but not a failure: the interpreter still runs them. */
	static var refused:Int = 0;

	public static function run():Void {
		var cases:Array<Array<String>> = [
			['hostMethodOptional', 'return host.greet(\'hi\');', 'hi!', ''],
			['hostMethodAllArgs', 'return host.greet(\'hi\', \'?\');', 'hi?', ''],
			['hostStaticOptional', 'return Sweep.tag(\'x\');', 'x-', ''],
			['keyValueFor', 'var t:String = \'\'; for (k => v in [\'a\' => 1]) t += k + v; return t;', 'a1', ''],
			['patternMatch', 'var p:Dynamic = {n: 3}; switch (p) { case {n: v}: return \'n\' + v; default: return \'no\'; }', 'n3', ''],
			['switchGuard', 'var i:Int = 5; switch (i) { case v if (v > 3): return \'big\'; default: return \'small\'; }', 'big', ''],
			['mapComprehension', 'var m:Map<Int,Int> = [for (k in 0...3) k => k * 2]; return Std.string(m.get(2));', '4', ''],
			['restArgs', 'return Std.string(sum(1, 2, 3));', '6', '\tstatic function sum(...nums:Int):Int { var t:Int = 0; for (n in nums) t += n; return t; }\n'],
			['propertyAccessor', 'var b:Box = new Box(); b.doubled = 5; return Std.string(b.doubled);', '10', '}\nclass Box {\n\tvar raw:Int = 0;\n\tpublic var doubled(get, set):Int;\n\tpublic function new() {}\n\tfunction get_doubled():Int { return raw * 2; }\n\tfunction set_doubled(v:Int):Int { raw = v; return v; }\n'],
			['abstractDecl', 'var m:Meters = 3; return Std.string(m.big());', '300', '}\nabstract Meters(Int) from Int to Int {\n\tpublic function big():Int { return this * 100; }\n'],
			['nestedStruct', 'var p:Dynamic = {pos: {x: 2, y: 7}}; switch (p) { case {pos: {y: b}}: return \'y\' + b; default: return \'no\'; }', 'y7', ''],
			['arrayPattern', 'var a:Array<Int> = [4, 9]; switch (a) { case [x, y]: return Std.string(x + y); default: return \'no\'; }', '13', ''],
			['arrayLiteralPat', 'var a:Array<Int> = [1, 2]; switch (a) { case [1, v]: return \'v\' + v; default: return \'no\'; }', 'v2', ''],
			['structWildcard', 'var p:Dynamic = {a: 1, b: 2}; switch (p) { case {a: _, b: q}: return \'q\' + q; default: return \'no\'; }', 'q2', ''],
			['structGuard', 'var p:Dynamic = {n: 9}; switch (p) { case {n: v} if (v > 5): return \'big\' + v; default: return \'small\'; }', 'big9', ''],
			['patternFallthru', 'var p:Dynamic = {z: 1}; switch (p) { case {q: v}: return \'q\'; default: return \'fell\'; }', 'fell', ''],
			['absCtor', 'var m:Meters = new Meters(4); return Std.string(m.big());', '400', '}\nabstract Meters(Int) from Int to Int {\n\tpublic function new(v:Int) { this = v; }\n\tpublic function big():Int { return this * 100; }\n\tpublic function plus(o:Int):Meters { return new Meters(this + o); }\n\tpublic function raw():Int { return this; }\n\tpublic static function zero():Meters { return new Meters(0); }\n'],
			['absChain', 'var m:Meters = new Meters(2); return Std.string(m.plus(3).big());', '500', '}\nabstract Meters(Int) from Int to Int {\n\tpublic function new(v:Int) { this = v; }\n\tpublic function big():Int { return this * 100; }\n\tpublic function plus(o:Int):Meters { return new Meters(this + o); }\n\tpublic function raw():Int { return this; }\n\tpublic static function zero():Meters { return new Meters(0); }\n'],
			['absStatic', 'var m:Meters = Meters.zero(); return Std.string(m.big());', '0', '}\nabstract Meters(Int) from Int to Int {\n\tpublic function new(v:Int) { this = v; }\n\tpublic function big():Int { return this * 100; }\n\tpublic function plus(o:Int):Meters { return new Meters(this + o); }\n\tpublic function raw():Int { return this; }\n\tpublic static function zero():Meters { return new Meters(0); }\n'],
			['absArg', 'var m:Meters = new Meters(7); return Std.string(Meters.twice(m));', '14', '}\nabstract Meters(Int) from Int to Int {\n\tpublic function new(v:Int) { this = v; }\n\tpublic function big():Int { return this * 100; }\n\tpublic function plus(o:Int):Meters { return new Meters(this + o); }\n\tpublic function raw():Int { return this; }\n\tpublic static function zero():Meters { return new Meters(0); }\n\tpublic static function twice(v:Meters):Int { return v.raw() * 2; }\n'],
			['absField', 'var h:Holder2 = new Holder2(); h.dist = new Meters(5); return Std.string(h.dist.big());', '500', '}\nabstract Meters(Int) from Int to Int {\n\tpublic function new(v:Int) { this = v; }\n\tpublic function big():Int { return this * 100; }\n\tpublic function plus(o:Int):Meters { return new Meters(this + o); }\n\tpublic function raw():Int { return this; }\n\tpublic static function zero():Meters { return new Meters(0); }\n}\nclass Holder2 {\n\tpublic var dist:Meters;\n\tpublic function new() {}\n'],
			['absNoCtor', 'var f:Feet = 6; return Std.string(f.inches());', '72', '}\nabstract Feet(Int) from Int to Int {\n\tpublic function inches():Int { return this * 12; }\n'],
			['absLoop', 'var m:Meters = new Meters(0); for (i in 0...3) m = m.plus(2); return Std.string(m.big());', '600', '}\nabstract Meters(Int) from Int to Int {\n\tpublic function new(v:Int) { this = v; }\n\tpublic function big():Int { return this * 100; }\n\tpublic function plus(o:Int):Meters { return new Meters(this + o); }\n\tpublic function raw():Int { return this; }\n\tpublic static function zero():Meters { return new Meters(0); }\n'],
			['absArray', 'var a:Array<Meters> = [new Meters(1), new Meters(2)]; return Std.string(a[1].big());', '200', '}\nabstract Meters(Int) from Int to Int {\n\tpublic function new(v:Int) { this = v; }\n\tpublic function big():Int { return this * 100; }\n\tpublic function plus(o:Int):Meters { return new Meters(this + o); }\n\tpublic function raw():Int { return this; }\n\tpublic static function zero():Meters { return new Meters(0); }\n'],
			['absCond', 'var m:Meters = new Meters(5); var n:Meters = m.raw() > 3 ? m.plus(1) : m; return Std.string(n.big());', '600', '}\nabstract Meters(Int) from Int to Int {\n\tpublic function new(v:Int) { this = v; }\n\tpublic function big():Int { return this * 100; }\n\tpublic function plus(o:Int):Meters { return new Meters(this + o); }\n\tpublic function raw():Int { return this; }\n\tpublic static function zero():Meters { return new Meters(0); }\n'],
			['absString', 'var w:Word = \'hi\'; return w.shout();', 'HI!', '}\nabstract Word(String) from String to String {\n\tpublic function shout():String { return this.toUpperCase() + \'!\'; }\n'],
			['varArgsField', 'return Std.string(adder(1, 2, 3));', '6', '\tpublic static var adder:Dynamic = Reflect.makeVarArgs(function(a:Array<Dynamic>):Dynamic {\n\t\tvar t:Int = 0;\n\t\tfor (v in a) t += v;\n\t\treturn t;\n\t});\n'],
			['closureField', 'return Std.string(twice(5));', '10', '\tpublic static var twice:Dynamic = function(n:Int):Int { return n * 2; };\n'],
			['opOverload', 'var a:Cash = 3; var b:Cash = 4; var c:Cash = a + b; return Std.string(c.amount());', '7', '}\nabstract Cash(Int) from Int to Int {\n\tpublic function amount():Int { return this; }\n\t@:op(A + B) public function add(o:Cash):Cash { return new Cash(this + o); }\n\tpublic function new(v:Int) { this = v; }\n'],
			['arrayAccess', 'var g:Grid = new Grid(); return Std.string(g[2]);', '20', '}\nabstract Grid(Array<Int>) {\n\tpublic function new() { this = [0, 10, 20]; }\n\t@:arrayAccess public function get(i:Int):Int { return this[i]; }\n'],
			['propGetSet', 'var b:Prop = new Prop(); b.v = 4; return Std.string(b.v);', '8', '}\nclass Prop {\n\tvar raw:Int = 0;\n\tpublic var v(get, set):Int;\n\tpublic function new() {}\n\tfunction get_v():Int { return raw * 2; }\n\tfunction set_v(n:Int):Int { raw = n; return n; }\n'],
			['enumPattern', 'var e:Colour = Red(3); switch (e) { case Red(n): return \'r\' + n; case Blue: return \'b\'; }', 'r3', '}\nenum Colour { Red(n:Int); Blue; }\nclass Unused2 {\n\tpublic function new() {}\n'],
			['keyValueMap', 'var m:Map<String,Int> = [\'a\' => 1, \'b\' => 2]; var t:Int = 0; for (k => v in m) t += v; return Std.string(t);', '3', ''],

			['intDivNeg', 'var a:Int = -7; var b:Int = 2; return Std.string(Std.int(a / b));', '-3', ''],
			['modNeg', 'var a:Int = -7; var b:Int = 3; return Std.string(a % b);', '-1', ''],
			['floorNeg', 'return Std.string(Math.floor(-1.5)) + \'/\' + Std.string(Std.int(-1.5));', '-2/-1', ''],
			['shiftNeg', 'var n:Int = -8; return Std.string(n >> 1) + \'/\' + Std.string(n >>> 28);', '-4/15', ''],
			['floatIntDiv', 'var a:Int = 7; var b:Int = 2; return Std.string(a / b);', '3.5', ''],

			['boolReturn', 'return Std.string(yes()) + \'/\' + Std.string(yes() == true);', 'true/true', '\tstatic function yes():Bool { return true; }\n'],
			['nullBoolReturn', 'var v:Null<Bool> = maybe(); return Std.string(v) + \'/\' + Std.string(v == true);', 'true/true', '\tstatic function maybe():Null<Bool> { return true; }\n'],
			['nullIntReturn', 'var v:Null<Int> = maybe(); return Std.string(v == null) + \'/\' + Std.string(v);', 'false/0', '\tstatic function maybe():Null<Int> { return 0; }\n'],
			['nullIntIsNull', 'var v:Null<Int> = none(); return Std.string(v == null);', 'true', '\tstatic function none():Null<Int> { return null; }\n'],
			['boolField', 'var f:Flag = new Flag(); return Std.string(f.on) + \'/\' + Std.string(f.on == true);', 'true/true', '}\nclass Flag {\n\tpublic var on:Bool = true;\n\tpublic function new() {}\n'],

			['optionalIntLeftOff', 'return Std.string(pad(1));', '1:none', '\tstatic function pad(a:Int, ?b:Int):String { return a + \':\' + (b == null ? \'none\' : Std.string(b)); }\n'],
			['defaultArgValue', 'return Std.string(pad(1)) + \'/\' + Std.string(pad(1, 5));', '6/6', '\tstatic function pad(a:Int, b:Int = 5):Int { return a + b; }\n'],
			['optionalStringLeftOff', 'return say(\'hi\');', 'hi!', '\tstatic function say(w:String, ?mark:String):String { return w + (mark == null ? \'!\' : mark); }\n'],

			['closureOverLoopVar', 'var fs:Array<Void->Int> = []; for (i in 0...3) fs.push(function():Int return i); return Std.string(fs[0]() + fs[1]() + fs[2]());', '3', ''],
			['closureOverWhileVar', 'var fs:Array<Void->Int> = []; var i:Int = 0; while (i < 3) { var k:Int = i; fs.push(function():Int return k); i++; } return Std.string(fs[0]() + fs[2]());', '2', ''],
			['nestedClosureCapture', 'var n:Int = 1; var outer = function():Int { var inner = function():Int { n += 4; return n; }; return inner() + n; }; return Std.string(outer());', '10', ''],
			['recursion', 'return Std.string(fib(10));', '55', '\tstatic function fib(n:Int):Int { return n < 2 ? n : fib(n - 1) + fib(n - 2); }\n'],

			['doWhile', 'var i:Int = 0; var t:Int = 0; do { t += i; i++; } while (i < 3); return Std.string(t);', '3', ''],
			['doWhileRunsOnce', 'var t:Int = 0; do { t = 9; } while (false); return Std.string(t);', '9', ''],
			['breakInNested', 'var t:Int = 0; for (i in 0...3) { for (j in 0...3) { if (j == 1) break; t++; } } return Std.string(t);', '3', ''],
			['continueSkips', 'var t:Int = 0; for (i in 0...5) { if (i % 2 == 0) continue; t += i; } return Std.string(t);', '4', ''],

			['throwStringCaught', 'try { throw \'boom\'; } catch (e:String) { return \'got \' + e; }', 'got boom', ''],
			['throwIntCaughtDynamic', 'try { throw 7; } catch (e:Dynamic) { return \'got \' + Std.string(e); }', 'got 7', ''],
			['throwFromCallee', 'try { return blow(); } catch (e:String) { return \'caught \' + e; }', 'caught deep', '\tstatic function blow():String { throw \'deep\'; }\n'],
			['catchOrder', 'try { throw \'s\'; } catch (e:Int) { return \'int\'; } catch (e:String) { return \'str\'; }', 'str', ''],
			['finallyByReturn', 'var t:Array<String> = []; t.push(step(t)); return t.join(\',\');', 'in,done', '\tstatic function step(t:Array<String>):String { t.push(\'in\'); return \'done\'; }\n'],

			['interfaceDispatch', 'var s:Shape = new Sq(); return Std.string(s.area());', '9', '}\ninterface Shape {\n\tpublic function area():Int;\n}\nclass Sq implements Shape {\n\tpublic function new() {}\n\tpublic function area():Int { return 9; }\n'],
			['isAgainstInterface', 'var s:Dynamic = new Sq(); return Std.string(s is Shape);', 'true', '}\ninterface Shape {\n\tpublic function area():Int;\n}\nclass Sq implements Shape {\n\tpublic function new() {}\n\tpublic function area():Int { return 9; }\n'],
			['safeCastToClass', 'var d:Dynamic = new Sq(); var s:Sq = cast(d, Sq); return Std.string(s.area());', '9', '}\nclass Sq {\n\tpublic function new() {}\n\tpublic function area():Int { return 9; }\n'],
			['unsafeCast', 'var d:Dynamic = 5; var n:Int = cast d; return Std.string(n + 1);', '6', ''],

			['staticInitOrder', 'return Std.string(Table.ready) + \'/\' + Std.string(Table.n);', 'true/7', '}\nclass Table {\n\tpublic static var ready:Bool = true;\n\tpublic static var n:Int = 7;\n'],
			['stringSwitchNoDefault', 'var s:String = \'c\'; switch (s) { case \'a\': return \'A\'; case \'c\': return \'C\'; } return \'fell\';', 'C', ''],
			['switchOnFloat', 'var f:Float = 2.5; switch (f) { case 2.5: return \'hit\'; default: return \'miss\'; }', 'hit', ''],
			['stringCompare', 'return Std.string(\'abc\' < \'abd\') + \'/\' + Std.string(\'b\' > \'a\');', 'true/true', ''],
			['stringOps', 'var s:String = \'a,b,c\'; return s.split(\',\').join(\'-\') + \'/\' + s.substr(2, 1) + \'/\' + Std.string(s.indexOf(\'c\'));', 'a-b-c/b/4', ''],
			['parseIntBad', 'return Std.string(Std.parseInt(\'zz\') == null) + \'/\' + Std.string(Std.parseInt(\'12x\'));', 'true/12', ''],
			['charCodeRoundTrip', 'return String.fromCharCode(\'A\'.charCodeAt(0) + 1);', 'B', ''],

			['arrayFns', 'var a:Array<Int> = [3, 1, 2]; a.sort(function(x:Int, y:Int):Int return x - y); return a.join(\',\') + \'/\' + Std.string(a.indexOf(2));', '1,2,3/1', ''],
			['arrayMapFilter', 'var a:Array<Int> = [1, 2, 3, 4]; return a.filter(function(v:Int):Bool return v % 2 == 0).map(function(v:Int):Int return v * 10).join(\',\');', '20,40', ''],
			['arraySpliceInsert', 'var a:Array<Int> = [1, 2, 3]; a.insert(1, 9); a.splice(0, 1); return a.join(\',\');', '9,2,3', ''],
			['mapRemoveExists', 'var m:Map<String,Int> = [\'a\' => 1]; m.remove(\'a\'); return Std.string(m.exists(\'a\')) + \'/\' + Std.string(m.get(\'a\'));', 'false/null', ''],

			['reflectOnScripted', 'var b:Bag = new Bag(); Reflect.setProperty(b, \'n\', 4); return Std.string(Reflect.getProperty(b, \'n\'));', '4', '}\nclass Bag {\n\tpublic var n:Int = 0;\n\tpublic function new() {}\n'],
			['typeGetClassName', 'var b:Bag = new Bag(); return Type.getClassName(Type.getClass(b));', 's.Bag', '}\nclass Bag {\n\tpublic function new() {}\n'],
			['stringOfScripted', 'var b:Bag = new Bag(); return Std.string(b);', 'bag', '}\nclass Bag {\n\tpublic function new() {}\n\tpublic function toString():String { return \'bag\'; }\n'],
		];

		// Both sides need telling: the interpreter through Config, the emitter through its lists.
		hxscript.Config.globalVariables.set('host', Sweep.shared);
		hxscript.Config.globalImports.set('Sweep', INormal);
		Compiler.ambient = ['Sweep'];
		Compiler.statics = ['host=Sweep::shared'];

		for (c in cases)
			sweep(c[0], c[1], c[2], c[3]);

		// Recorded rather than asserted: the interpreter WIDENS an Int that overflows, deliberately,
		// because a script that never wrote `Int` should not have a value silently corrupted. Compiled
		// code has the declared type and wraps, which is what Haxe does. Both are defensible and they
		// do not agree.
		divergence('intOverflow', 'var n:Int = 2147483647; return Std.string(n + 1);', '');

		TestCase.log('  ' + refused + ' refused');
	}

	/**
	 * Reports a construct the two modes answer differently on purpose.
	 *
	 * @param name The construct.
	 * @param body The script body.
	 * @param extra Anything the class needs beside it.
	 */
	static function divergence(name:String, body:String, extra:String):Void {
		var src:String = 'package s;
class C {
	public static function go():Dynamic {
'
			+ body + '
	}
' + extra + '}
';

		TestCase.gap(name, 'interp=' + viaInterp(src) + ' cppia=' + viaCppia(src), 'the two to agree');
	}

	static function sweep(name:String, body:String, want:String, extra:String):Void {
		var src:String = 'package s;\nclass C {\n\tpublic static function go():Dynamic {\n'
			+ body + '\n\t}\n' + extra + '}\n';

		var interp:String = viaInterp(src);
		var compiled:String = viaCppia(src);

		var detail:String = 'interp=' + StringTools.rpad(interp, ' ', 10) + 'cppia=' + compiled;

		if (StringTools.startsWith(compiled, 'REFUSED')) {
			refused++;
			TestCase.log('  REFUSED ' + StringTools.rpad(name, ' ', 20) + detail);
		} else if (compiled == want && interp == want) {
			TestCase.ok(name + '   ' + detail, true);
		} else {
			TestCase.bad(name, detail + '   wanted ' + want);
		}
	}

	static function viaInterp(src:String):String {
		try {
			var env = new Environment();
			env.addModule(new Module(src, 'C', ['s'], 'sweep'));
			for (m in env.modules) m.init(env);
			for (m in env.modules) m.start(env);
			for (m in env.modules) m.startTypes(env);
			var cls:ScriptedClass = cast env.resolve('s.C');
			return Std.string(Reflect.callMethod(null, cls.reflectGetField('go'), []));
		} catch (e:Dynamic) {
			return 'THREW: ' + e;
		}
	}

	static function viaCppia(src:String):String {
		try {
			var decls = new Parser().parseModule(src, 'sweep', 0, ['s']);
			var r = Cppia.compile([{name: 's.C', decls: decls}], Compiler.ambient, null, Compiler.statics);
			if (r.bytes == null)
				return 'REFUSED: ' + (r.skipped.length > 0 ? r.skipped[0].reason : '?');

			var m = cpp.cppia.Module.fromData(r.bytes.getData());
			m.boot();
			return Std.string(Reflect.callMethod(null, Reflect.field(m.resolveClass('s.C'), 'go'), []));
		} catch (e:Dynamic) {
			return 'THREW: ' + e;
		}
	}

	static function main():Void {
		run();
		TestCase.exit();
	}
}
