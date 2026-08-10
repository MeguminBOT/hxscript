import hxscript.Environment;
import hxscript.Module;
import hxscript.compile.Cppia;
import hxscript.compile.Result;
import hxscript.types.ScriptedClass;

/**
 * Measures work that crosses into the host, rather than work a script does to itself.
 *
 * `CppiaBench` times a loop over an array of `Int`, which is the case compiling flatters most: every
 * value has a type the emitter can name, so the bytecode is plain arithmetic. Real scripts are not
 * shaped like that. A renderer spends its frame calling methods on engine objects, and the emitter
 * has no type for those, so it emits `Dynamic` and every call becomes a lookup by name.
 *
 * If that lookup costs what the interpreter's own lookup costs, compiling buys nothing for the code
 * that actually runs per frame, which is the thing this is here to find out.
 */
class CppiaHostBench {
	/** Calls a method on a host object, the shape of pushing a vertex. */
	static var CALLS:String = 'package p;
class C {
	public static function run(sink:HostSink, n:Int):Dynamic {
		var i:Int = 0;
		while (i < n) {
			sink.push(i);
			i++;
		}
		return sink.total;
	}
}
';

	/** Reads and writes a field on a host object. */
	static var FIELDS:String = 'package p;
class F {
	public static function run(sink:HostSink, n:Int):Dynamic {
		var i:Int = 0;
		while (i < n) {
			sink.total = sink.total + i;
			i++;
		}
		return sink.total;
	}
}
';

	/** The same amount of arithmetic with no host in it, as a control. */
	static var PURE:String = 'package p;
class P {
	public static function run(sink:HostSink, n:Int):Dynamic {
		var total:Float = 0;
		var i:Int = 0;
		while (i < n) {
			total = total + i;
			i++;
		}
		return total;
	}
}
';

	/** Reads and writes fields on another SCRIPTED class, which is what a renderer does per column. */
	static var SCRIPTED:String = 'package p;
class Holder {
	public var a:Float = 0;
	public var b:Float = 1;
	public function new() {}
}
class S {
	public static function run(sink:HostSink, n:Int):Dynamic {
		var h:Holder = new Holder();
		var i:Int = 0;
		while (i < n) {
			h.a = h.a + h.b;
			i++;
		}
		return h.a;
	}
}
';

	/** Reads a typed array held in a field, which is the renderer's other per-column operation. */
	static var ARRAYS:String = 'package p;
class Grid {
	public var data:Array<Float>;
	public function new() {
		data = [];
		var i:Int = 0;
		while (i < 1024) {
			data.push(i);
			i++;
		}
	}
}
class A {
	public static function run(sink:HostSink, n:Int):Dynamic {
		var g:Grid = new Grid();
		var total:Float = 0;
		var i:Int = 0;
		while (i < n) {
			total = total + g.data[i & 1023];
			i++;
		}
		return total;
	}
}
';

	static inline var COUNT:Int = 2000000;

	public static function main():Void {
		cpp.cppia.Host.enableJit(true);

		Sys.println('');
		Sys.println('              interpreted      cppia     native     gain');
		Sys.println('--------------------------------------------------------');

		measure('host method', CALLS, 'p.C', 'C', nativeCalls);
		measure('host field', FIELDS, 'p.F', 'F', nativeFields);
		measure('pure arithmetic', PURE, 'p.P', 'P', nativePure);
		measure('scripted field', SCRIPTED, 'p.S', 'S', nativeScripted);
		measure('typed array', ARRAYS, 'p.A', 'A', nativeArrays);

		Sys.println('');
	}

	/** The host method loop, compiled by Haxe. */
	static function nativeCalls(sink:HostSink, n:Int):Dynamic {
		var i:Int = 0;
		while (i < n) {
			sink.push(i);
			i++;
		}
		return sink.total;
	}

	/** The host field loop, compiled by Haxe. */
	static function nativeFields(sink:HostSink, n:Int):Dynamic {
		var i:Int = 0;
		while (i < n) {
			sink.total = sink.total + i;
			i++;
		}
		return sink.total;
	}

	/** The scripted-object field loop, compiled by Haxe. */
	static function nativeScripted(sink:HostSink, n:Int):Dynamic {
		var h:NativeHolder = new NativeHolder();
		var i:Int = 0;
		while (i < n) {
			h.a = h.a + h.b;
			i++;
		}
		return h.a;
	}

	/** The typed-array loop, compiled by Haxe. */
	static function nativeArrays(sink:HostSink, n:Int):Dynamic {
		var data:Array<Float> = [];
		var k:Int = 0;
		while (k < 1024) {
			data.push(k);
			k++;
		}

		var total:Float = 0;
		var i:Int = 0;
		while (i < n) {
			total = total + data[i & 1023];
			i++;
		}
		return total;
	}

	/** The control loop, compiled by Haxe. */
	static function nativePure(sink:HostSink, n:Int):Dynamic {
		var total:Float = 0;
		var i:Int = 0;
		while (i < n) {
			total = total + i;
			i++;
		}
		return total;
	}

	/**
	 * Times one workload three ways and prints the row.
	 *
	 * @param label How to name it.
	 * @param source The script to run.
	 * @param path The class it declares.
	 * @param name The module name.
	 * @param native The same loop written in Haxe.
	 */
	static function measure(label:String, source:String, path:String, name:String, native:HostSink->Int->Dynamic):Void {
		var env:Environment = new Environment();
		var module:Module = new Module(source, name, ['p'], 'bench');
		env.addModule(module);
		env.variables.set('HostSink', HostSink);
		module.init(env);
		module.start(env);
		module.startTypes(env);

		var cls:ScriptedClass = cast env.resolve(path);
		var interpFn:Dynamic = cls.reflectGetField('run');

		var interpMs:Float = time(interpFn, null);
		var interpAnswer:Dynamic = last;

		var decls = new hxscript.syntax.Parser().parseModule(source, name, 0, ['p']);
		var result:Result = Cppia.compile([{name: path, decls: decls}], ['HostSink']);

		if (result.bytes == null) {
			Sys.println(pad(label, 16) + 'refused: ' + result.skipped[0].reason);
			return;
		}

		var cmodule = cpp.cppia.Module.fromData(result.bytes.getData());
		cmodule.boot();

		var cppiaMs:Float = time(Reflect.field(cmodule.resolveClass(path), 'run'), null);
		var cppiaAnswer:Dynamic = last;

		var nativeMs:Float = time(null, native);
		var nativeAnswer:Dynamic = last;

		var agree:Bool = Std.string(interpAnswer) == Std.string(cppiaAnswer) && Std.string(cppiaAnswer) == Std.string(nativeAnswer);

		Sys.println(pad(label, 16)
			+ pad(fmt(interpMs) + ' ms', 15)
			+ pad(fmt(cppiaMs) + ' ms', 11)
			+ pad(fmt(nativeMs) + ' ms', 11)
			+ fmt(interpMs / cppiaMs)
			+ 'x'
			+ (agree ? '' : '   DISAGREE: ' + interpAnswer + ' / ' + cppiaAnswer + ' / ' + nativeAnswer));
	}

	/** The answer the last timed run produced. */
	static var last:Dynamic = null;

	/**
	 * Runs a workload once to warm it and once for the clock, on a fresh sink each time.
	 *
	 * @param fn The script function, or null to time `native` instead.
	 * @param native The Haxe function, used when `fn` is null.
	 * @return Milliseconds for the timed run.
	 */
	static function time(fn:Dynamic, native:HostSink->Int->Dynamic):Float {
		if (fn != null) {
			Reflect.callMethod(null, fn, [new HostSink(), COUNT]);
		} else {
			native(new HostSink(), COUNT);
		}

		var sink:HostSink = new HostSink();
		var started:Float = haxe.Timer.stamp();
		last = (fn != null) ? Reflect.callMethod(null, fn, [sink, COUNT]) : native(sink, COUNT);
		return (haxe.Timer.stamp() - started) * 1000;
	}

	static function fmt(v:Float):String {
		return Std.string(Math.round(v * 100) / 100);
	}

	static function pad(s:String, n:Int):String {
		while (s.length < n)
			s += ' ';
		return s;
	}
}
