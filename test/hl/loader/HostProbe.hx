import hxscript.Environment;
import hxscript.Module;
import hxscript.compile.Compiler;
import hxscript.compile.Report;
import hxscript.types.ScriptedClass;

/**
 * Uses the library the way a host does: build a world, call `Compiler.compile`, keep calling the
 * same scripted functions.
 *
 * Nothing here knows that a backend exists. The point is that a host does not have to: the calls it
 * was already making are the ones that get faster.
 */
class HostProbe {
	static var SOURCE:String = 'package game;
class Rules {
	public static function step(n:Int):Int {
		return n * 2 + 1;
	}
	public static function score(rounds:Int):Int {
		var total:Int = 0;
		for (i in 0...rounds)
			total += step(i % 100);
		return total;
	}
	public static function grade(points:Int):Bool {
		return points > 1000;
	}
}
';

	static function world():Environment {
		var env:Environment = new Environment();
		var module:Module = new Module('', 'Rules', ['game'], 'host');
		module.parse(SOURCE);
		env.addModule(module);
		module.init(env);
		module.start(env);
		module.startTypes(env);
		return env;
	}

	static function call(env:Environment, field:String, args:Array<Dynamic>):Dynamic {
		var cls:ScriptedClass = cast env.resolve('game.Rules');
		return Reflect.callMethod(null, cls.reflectGetField(field), args);
	}

	static function best(run:Void->Dynamic, reps:Int, inner:Int):Float {
		var lowest:Float = -1;
		for (r in 0...reps) {
			var t:Float = haxe.Timer.stamp();
			for (k in 0...inner)
				run();
			var ms:Float = ((haxe.Timer.stamp() - t) * 1000) / inner;
			if (lowest < 0 || ms < lowest)
				lowest = ms;
		}
		return lowest;
	}

	static function say(what:String):Void {
		Sys.println(what);
		Sys.stdout().flush();
	}

	public static function main():Void {
		say('-- a host that does not know a backend exists --');

		if (!Compiler.available) {
			say('  no backend in this build');
			Sys.exit(1);
		}

		var before:Environment = world();
		var wantScore:Dynamic = call(before, 'score', [20000]);
		var wantGrade:Dynamic = call(before, 'grade', [2000]);
		var slow:Float = best(function():Dynamic return call(before, 'score', [20000]), 3, 1);

		var env:Environment = world();
		var report:Report = Compiler.compile(env);

		say('  compiled  ' + report.compiled.join(', '));
		for (skip in report.skipped)
			say('  skipped   ' + skip.toString());
		for (fail in report.failed)
			say('  failed    ' + fail.toString());
		say('  bytecode  ' + report.bytes + ' bytes in ' + Math.round(report.ms) + ' ms');

		var gotScore:Dynamic = call(env, 'score', [20000]);
		var gotGrade:Dynamic = call(env, 'grade', [2000]);

		var ok:Bool = Std.string(gotScore) == Std.string(wantScore) && Std.string(gotGrade) == Std.string(wantGrade);
		say('  score     ' + Std.string(gotScore) + (Std.string(gotScore) == Std.string(wantScore) ? '' : '   WANTED ' + Std.string(wantScore)));
		say('  grade     ' + Std.string(gotGrade) + (Std.string(gotGrade) == Std.string(wantGrade) ? '' : '   WANTED ' + Std.string(wantGrade)));

		if (!ok) {
			say('== the compiled world answers differently ==');
			Sys.exit(1);
		}

		var fast:Float = best(function():Dynamic return call(env, 'score', [20000]), 3, 20);
		say('  score()   ' + Math.round(slow) + ' ms interpreted, ' + (Math.round(fast * 100) / 100) + ' ms compiled, x'
			+ Math.round(slow / fast) + ' faster');

		say('== the same calls, same answers ==');
	}
}
