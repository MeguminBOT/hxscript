import hxscript.Environment;
import hxscript.Module;
import hxscript.compile.Compiler;
import hxscript.types.ScriptedClass;

/**
 * Measures what a name the host bound costs, per spelling.
 *
 * A bound name used to refuse its whole module, so the baseline it has to beat is not a field read,
 * it is interpreting everything around it. What the tiers are for is the distance between the two
 * ends: a name bound to a host static is a field access and a name bound to a bare value is a call,
 * and knowing the gap is what tells a host whether moving one onto a static is worth doing.
 *
 * The typed and untyped rows differ only in the accessor the emitter picked, which is decided by
 * what the name held while it compiled. The local row is the control: the same arithmetic with
 * nothing bound in it.
 */
class CppiaGlobalsBench {
	/** A host static for the cheapest spelling to point at. */
	public static var current:Int = 7;

	static var LOOP:String = 'package p;
class %C% {
	public static function run(n:Int):Int {
		var total:Int = 0;
		var i:Int = 0;
		while (i < n) {
			total = total + %READ%;
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
		Sys.println('  ' + COUNT + ' reads per row, JIT on. Times are the whole loop; ns/read is one read.');
		Sys.println('');
		Sys.println('                      interpreted        compiled       ns/read       gain');
		Sys.println('---------------------------------------------------------------------------');

		measure('local (control)', 'L', 'seed', 'var seed:Int = 7;');
		/**
		 * Registered only for the interpreter. The emitter is handed `Config.globalStatics` itself, so
		 * this is also the check that the two sides no longer need telling separately.
		 */
		hxscript.Config.globalStatics.set('current', 'CppiaGlobalsBench::current');
		measure('host static', 'S', 'current');
		measure('global, typed Int', 'G', 'damage');
		measure('global, Dynamic', 'D', 'damage', null, ['damage:Dynamic']);
		measure('global, host object', 'O', 'held.length');

		Sys.println('');
		Sys.println('A global whose type has a slot pool is read out of a real typed static, so it costs');
		Sys.println('what a local costs and the control is not a target it falls short of. One without');
		Sys.println('stays a call into the interpreter, which is still an order of magnitude over');
		Sys.println('interpreting; giving such a name a home on a host static is what closes that gap.');
		Sys.println('');
	}

	/**
	 * Times one spelling both ways.
	 *
	 * @param label How to name the row.
	 * @param name The class to declare, so each case is its own path.
	 * @param read What the loop body adds.
	 * @param prelude A statement to put before the loop, for the control's local.
	 * @param pins `Compiler.globalNames` for this case.
	 */
	static function measure(label:String, name:String, read:String, ?prelude:String, ?pins:Array<String>):Void {
		var source:String = StringTools.replace(LOOP, '%C%', name);
		source = StringTools.replace(source, '%READ%', read);

		if (prelude != null)
			source = StringTools.replace(source, 'var total:Int = 0;', prelude + ' var total:Int = 0;');

		Compiler.globalNames = pins == null ? [] : pins;

		Compiler.reset();
		var interpreted:Float = time(world(source), 'p.' + name, false);

		Compiler.reset();
		var made:Environment = world(source);
		Compiler.compile(made);

		if (!Compiler.isCompiled('p.' + name)) {
			Sys.println(pad(label, 22) + 'left interpreted');
			return;
		}

		var compiled:Float = time(made, 'p.' + name, true);

		Sys.println(pad(label, 22)
			+ pad(Std.int(interpreted) + ' ms', 17)
			+ pad(Std.int(compiled) + ' ms', 14)
			+ pad(nanos(compiled), 14)
			+ (compiled <= 0 ? '-' : Std.int(interpreted / compiled) + 'x'));

		Compiler.globalNames = [];
	}

	/** @return A world with the bound names every case may read. */
	static function world(source:String):Environment {
		var env:Environment = new Environment();
		env.variables.set('damage', 7);
		env.variables.set('held', [1, 2, 3, 4, 5, 6, 7]);
		env.addModule(new Module(source, 'B', ['p']));
		env.start();
		return env;
	}

	/**
	 * @param env The world.
	 * @param path The class to run.
	 * @param useCompiled Whether to run the class the emitter built rather than the world's.
	 * @return How long the loop took, in milliseconds.
	 */
	static function time(env:Environment, path:String, useCompiled:Bool):Float {
		var fn:Dynamic = useCompiled ? Reflect.field(Compiler.substitute(path),
			'run') : (cast(env.resolve(path), ScriptedClass)).reflectGetField('run');

		Reflect.callMethod(null, fn, [1000]);

		var started:Float = haxe.Timer.stamp();
		Reflect.callMethod(null, fn, [COUNT]);
		return (haxe.Timer.stamp() - started) * 1000;
	}

	static function pad(s:String, n:Int):String {
		return StringTools.rpad(s, ' ', n);
	}

	/**
	 * @param ms How long the whole loop took.
	 * @return What one read cost, to a tenth of a nanosecond.
	 */
	static function nanos(ms:Float):String {
		var each:Float = (ms * 1000000) / COUNT;
		return (Math.round(each * 10) / 10) + ' ns';
	}
}
