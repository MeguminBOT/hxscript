import hxscript.Environment;
import hxscript.Module;
import hxscript.compile.Compiler;
import hxscript.compile.Report;
import hxscript.hl.Loader;
import hxscript.types.ScriptedClass;

/**
 * Whether a script can be compiled and run inside an **HL/C** program.
 *
 * The reason this exists apart from the other probes: they run on HL/JIT, where the whole program is
 * bytecode and the extension is loaded by name when the module starts. HL/C is the other way to ship
 * HashLink, and it is the one a game with mod support is most likely to be built as: Haxe becomes C,
 * the C becomes an ordinary native binary, and there is no bytecode and no VM process.
 *
 * The question is whether a native binary like that can still be a host for compiled scripts. It
 * links `libhl`, and `libhl` exports the executable-memory allocator the jit needs, so the pieces
 * are there. What differs is the binding: an HL/C program resolves its natives at link time instead
 * of loading them when a module starts, which also means the `?` that makes the extension optional
 * on HL/JIT has nothing to do here.
 *
 * Prints one line per fact so a failure names which of them broke.
 */
class HlcProbe {
	static var SOURCE:String = 'package p;
class T {
	public static function total(n:Int):Int {
		var sum:Int = 0;
		var i:Int = 0;
		while (i < n) {
			sum += i * 3;
			i++;
		}
		return sum;
	}

	public static function greet(who:String):String {
		return "hello " + who;
	}
}
';

	static var failures:Int = 0;

	public static function main():Void {
		Sys.println('-- a compiled script inside an HL/C binary --');

		say('the extension is here', Loader.available);

		var world:Environment = new Environment();
		var module:Module = new Module('', 'T', ['p'], 'hlc');
		module.parse(SOURCE);
		world.addModule(module);
		module.init(world);
		module.start(world);
		module.startTypes(world);

		var report:Report = Compiler.compile(world, [module]);

		say('the compiler is in this build', Compiler.available);
		say('it took the module', report.compiled.length > 0);

		if (report.skipped.length > 0)
			Sys.println('  refused: ' + report.skipped[0].reason);

		var cls:ScriptedClass = cast world.resolve('p.T');

		var total:Dynamic = Reflect.callMethod(null, cls.reflectGetField('total'), [1000]);
		say('an integer answer is right', Std.string(total) == '1498500');

		var greeting:Dynamic = Reflect.callMethod(null, cls.reflectGetField('greet'), ['mods']);
		say('a string answer is right', Std.string(greeting) == 'hello mods');

		var began:Float = haxe.Timer.stamp();
		var last:Dynamic = null;
		for (i in 0...200)
			last = Reflect.callMethod(null, cls.reflectGetField('total'), [10000]);
		var took:Float = (haxe.Timer.stamp() - began) * 1000;

		Sys.println('  200 x total(10000) in ' + Math.round(took * 100) / 100 + ' ms');
		say('and still right after all of them', Std.string(last) == '149985000');

		Sys.println(failures == 0 ? '== it works ==' : '== ' + failures + ' failed ==');
		Sys.exit(failures == 0 ? 0 : 1);
	}

	static function say(what:String, ok:Bool):Void {
		if (!ok)
			failures++;

		var pad:String = what;
		while (pad.length < 40)
			pad += ' ';

		Sys.println('  ' + pad + (ok ? 'yes' : 'NO'));
	}
}
