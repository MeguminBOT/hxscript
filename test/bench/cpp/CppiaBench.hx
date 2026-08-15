import hxscript.Environment;
import hxscript.Module;
import hxscript.cppia.Backend;
import hxscript.compile.Result;
import hxscript.types.ScriptedClass;

/**
 * Measures the same work interpreted, compiled to cppia, and compiled by Haxe.
 *
 * The workload reads an array built at runtime so no side can fold it away, and every side must
 * return the same answer for its timing to mean anything.
 */
class CppiaBench {
	static var SOURCE:String = 'package p;
class T {
	public static function run(data:Array<Int>):Dynamic {
		var total:Int = 0;
		var i:Int = 0;
		var n:Int = data.length;
		while (i < n) {
			var v:Int = data[i];
			if (v > 100) {
				total += v % 7;
			} else {
				total += v * 2;
			}
			i++;
		}
		return total;
	}
}
';

	/** The same loop as `SOURCE`, compiled by Haxe. */
	static function native(data:Array<Int>):Dynamic {
		var total:Int = 0;
		var i:Int = 0;
		var n:Int = data.length;
		while (i < n) {
			var v:Int = data[i];
			if (v > 100) {
				total += v % 7;
			} else {
				total += v * 2;
			}
			i++;
		}
		return total;
	}

	public static function main():Void {
		cpp.cppia.Host.enableJit(true);

		var data:Array<Int> = [];
		var seed:Int = Std.int(haxe.Timer.stamp()) | 1;
		for (i in 0...300000) {
			seed = (seed * 1103515245 + 12345) & 0x3FFFFFFF;
			data.push(seed % 500);
		}

		var env:Environment = new Environment();
		var module:Module = new Module('', 'T', ['p'], 'bench');
		module.parse(SOURCE);
		env.addModule(module);
		module.init(env);
		module.start(env);
		module.startTypes(env);
		var cls:ScriptedClass = cast env.resolve('p.T');
		var interpFn:Dynamic = cls.reflectGetField('run');

		Reflect.callMethod(null, interpFn, [data]);
		var t0:Float = haxe.Timer.stamp();
		var interpreted:Dynamic = Reflect.callMethod(null, interpFn, [data]);
		var interpMs:Float = (haxe.Timer.stamp() - t0) * 1000;

		var parser = new hxscript.syntax.Parser();
		var decls = parser.parseModule(SOURCE, 'bench', 0, ['p']);

		var t1:Float = haxe.Timer.stamp();
		var result:Result = Backend.compile([{name: 'p.T', decls: decls}]);
		var compileMs:Float = (haxe.Timer.stamp() - t1) * 1000;

		if (result.bytes == null) {
			Sys.println('refused: ' + result.skipped[0].reason);
			return;
		}

		var t2:Float = haxe.Timer.stamp();
		var cmodule = cpp.cppia.Module.fromData(result.bytes.getData());
		cmodule.boot();
		var loadMs:Float = (haxe.Timer.stamp() - t2) * 1000;

		var ccls:Class<Dynamic> = cmodule.resolveClass('p.T');
		var cppiaFn:Dynamic = Reflect.field(ccls, 'run');

		Reflect.callMethod(null, cppiaFn, [data]);
		var t3:Float = haxe.Timer.stamp();
		var compiled:Dynamic = Reflect.callMethod(null, cppiaFn, [data]);
		var cppiaMs:Float = (haxe.Timer.stamp() - t3) * 1000;

		native(data);
		var t4:Float = haxe.Timer.stamp();
		var nativeResult:Dynamic = native(data);
		var nativeMs:Float = (haxe.Timer.stamp() - t4) * 1000;

		var agree:Bool = Std.string(interpreted) == Std.string(compiled) && Std.string(compiled) == Std.string(nativeResult);
		Sys.println('answers        ' + interpreted + ' / ' + compiled + ' / ' + nativeResult + (agree ? '  (agree)' : '  DISAGREE'));
		Sys.println('emit           ' + fmt(compileMs) + ' ms   (' + result.bytes.length + ' bytes)');
		Sys.println('load + link    ' + fmt(loadMs) + ' ms');
		Sys.println('interpreted    ' + fmt(interpMs) + ' ms');
		Sys.println('cppia          ' + fmt(cppiaMs) + ' ms');
		Sys.println('native         ' + fmt(nativeMs) + ' ms');
		Sys.println('cppia vs interp  ' + fmt(interpMs / cppiaMs) + 'x faster');
		Sys.println('native vs cppia  ' + fmt(cppiaMs / nativeMs) + 'x faster');
	}

	static function fmt(v:Float):String {
		return Std.string(Math.round(v * 100) / 100);
	}
}
