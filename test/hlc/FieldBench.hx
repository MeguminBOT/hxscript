import hxscript.Environment;
import hxscript.Module;
import hxscript.compile.Compiler;
import hxscript.compile.Report;
import hxscript.types.ScriptedClass;

/**
 * What a field costs on HashLink, interpreted against compiled.
 *
 * The arithmetic cases are not here and do not need to be: typed locals became registers long ago
 * and are hundreds of times faster compiled. Fields are the other half, and they are the half that
 * did not move, because a scripted instance keeps its fields where the interpreter put them and a
 * compiled body has to ask the same question the interpreter asks. This measures exactly that, so
 * that a change to how it is asked can be believed rather than hoped for.
 *
 * Built and run through `sh test/hlc/build.sh bench`, which is the HL/C route: a native binary with
 * no VM under it, which is how a game ships.
 */
class FieldBench {
	static var SOURCE:String = 'package game;
class Counter {
	public var total:Int = 0;
	public var seen:Int = 0;

	public function new() {}

	public function run(rounds:Int):Int {
		var i:Int = 0;
		while (i < rounds) {
			total = total + 1;
			seen = seen + 1;
			i++;
		}
		return total;
	}
}

class Walker {
	public var v:Int = 0;
	public function new(v:Int) { this.v = v; }
}

class Adder {
	public var total:Int = 0;
	public function new() {}
	public function add(n:Int):Void { total = total + n; }
}

class Fields {
	public static function hostChurn(rounds:Int):Int {
		var h:HostBase = new HostBase();
		var i:Int = 0;
		while (i < rounds) { h.kept = h.kept + 1; i++; }
		return h.kept;
	}

	public static function hostCalls(rounds:Int):Int {
		var h:HostBase = new HostBase();
		var total:Int = 0;
		var i:Int = 0;
		while (i < rounds) { total = total + h.tell(); i++; }
		return total;
	}

	public static function churn(rounds:Int):Int {
		var c:Counter = new Counter();
		return c.run(rounds);
	}

	public static function calls(rounds:Int):Int {
		var a:Adder = new Adder();
		var i:Int = 0;
		while (i < rounds) { a.add(1); i++; }
		return a.total;
	}

	public static function sweep(rounds:Int):Int {
		var all:Array<Walker> = [];
		var i:Int = 0;
		while (i < 64) { all.push(new Walker(i)); i++; }

		var total:Int = 0;
		var r:Int = 0;
		while (r < rounds) {
			var k:Int = 0;
			while (k < 64) { total = total + all[k].v; k++; }
			r++;
		}
		return total;
	}

	public static function arith(rounds:Int):Int {
		var i:Int = 0;
		var s:Int = 0;
		while (i < rounds) { s = s + 2 - 1; i++; }
		return s;
	}
}
';

	static function world():Environment {
		var env:Environment = new Environment();
		var module:Module = new Module('', 'Counter', ['game'], 'bench');
		module.parse(SOURCE);
		env.addModule(module);
		module.init(env);
		module.start(env);
		module.startTypes(env);
		return env;
	}

	static function call(env:Environment, field:String, rounds:Int):Dynamic {
		var cls:ScriptedClass = cast env.resolve('game.Fields');
		return Reflect.callMethod(null, cls.reflectGetField(field), [rounds]);
	}

	/**
	 * @return The lowest of several runs, in milliseconds.
	 *
	 * The lowest rather than the median, unlike the mode benchmark, because this is a before-and-
	 * after on one machine rather than a figure to publish: what is wanted is the least interfered
	 * with of the runs, and both sides are measured the same way.
	 */
	static function best(run:Void->Dynamic, reps:Int):Float {
		var lowest:Float = -1;

		for (r in 0...reps) {
			var at:Float = haxe.Timer.stamp();
			run();
			var ms:Float = (haxe.Timer.stamp() - at) * 1000;
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
		var rounds:Int = 200000;
		var sweeps:Int = 2000;

		say('-- what a field costs, interpreted against compiled --');

		var slow:Environment = world();
		var wantChurn:Dynamic = call(slow, 'churn', rounds);
		var wantSweep:Dynamic = call(slow, 'sweep', sweeps);
		var wantHostChurn:Dynamic = call(slow, 'hostChurn', rounds);
		var wantHostCalls:Dynamic = call(slow, 'hostCalls', rounds);
		var wantCalls:Dynamic = call(slow, 'calls', rounds);
		var wantArith:Dynamic = call(slow, 'arith', rounds);

		var churnSlow:Float = best(function():Dynamic return call(slow, 'churn', rounds), 3);
		var sweepSlow:Float = best(function():Dynamic return call(slow, 'sweep', sweeps), 3);
		var hostChurnSlow:Float = best(function():Dynamic return call(slow, 'hostChurn', rounds), 3);
		var hostCallsSlow:Float = best(function():Dynamic return call(slow, 'hostCalls', rounds), 3);
		var callsSlow:Float = best(function():Dynamic return call(slow, 'calls', rounds), 3);
		var arithSlow:Float = best(function():Dynamic return call(slow, 'arith', rounds), 3);

		if (!Compiler.available) {
			say('  no backend in this build: ' + (Compiler.unavailable() ?? 'no reason given'));
			Sys.exit(1);
		}

		var fast:Environment = world();
		var report:Report = Compiler.compile(fast);

		for (skip in report.skipped)
			say('  skipped   ' + skip.toString());
		for (fail in report.failed)
			say('  failed    ' + fail.toString());

		if (report.compiled.length == 0) {
			say('== nothing compiled, so there is nothing to compare ==');
			Sys.exit(1);
		}

		var gotChurn:Dynamic = call(fast, 'churn', rounds);
		var gotSweep:Dynamic = call(fast, 'sweep', sweeps);
		var gotHostChurn:Dynamic = call(fast, 'hostChurn', rounds);
		var gotHostCalls:Dynamic = call(fast, 'hostCalls', rounds);
		var gotCalls:Dynamic = call(fast, 'calls', rounds);
		var gotArith:Dynamic = call(fast, 'arith', rounds);

		var agree:Bool = Std.string(gotChurn) == Std.string(wantChurn)
			&& Std.string(gotSweep) == Std.string(wantSweep)
			&& Std.string(gotHostChurn) == Std.string(wantHostChurn)
			&& Std.string(gotHostCalls) == Std.string(wantHostCalls)
			&& Std.string(gotCalls) == Std.string(wantCalls)
			&& Std.string(gotArith) == Std.string(wantArith);

		if (!agree) {
			say('  churn     ' + Std.string(gotChurn) + ' wanted ' + Std.string(wantChurn));
			say('  sweep     ' + Std.string(gotSweep) + ' wanted ' + Std.string(wantSweep));
			say('  calls     ' + Std.string(gotCalls) + ' wanted ' + Std.string(wantCalls));
			say('  hostF     ' + Std.string(gotHostChurn) + ' wanted ' + Std.string(wantHostChurn));
			say('  hostM     ' + Std.string(gotHostCalls) + ' wanted ' + Std.string(wantHostCalls));
			say('  arith     ' + Std.string(gotArith) + ' wanted ' + Std.string(wantArith));
			say('== the compiled world answers differently, so the timings mean nothing ==');
			Sys.exit(1);
		}

		var churnFast:Float = best(function():Dynamic return call(fast, 'churn', rounds), 3);
		var sweepFast:Float = best(function():Dynamic return call(fast, 'sweep', sweeps), 3);
		var hostChurnFast:Float = best(function():Dynamic return call(fast, 'hostChurn', rounds), 3);
		var hostCallsFast:Float = best(function():Dynamic return call(fast, 'hostCalls', rounds), 3);
		var callsFast:Float = best(function():Dynamic return call(fast, 'calls', rounds), 3);
		var arithFast:Float = best(function():Dynamic return call(fast, 'arith', rounds), 3);

		row('churn  (scripted field)', churnSlow, churnFast);
		row('sweep  (many instances)', sweepSlow, sweepFast);
		row('calls  (scripted method)', callsSlow, callsFast);
		row('hostF  (host field)', hostChurnSlow, hostChurnFast);
		row('hostM  (host method)', hostCallsSlow, hostCallsFast);
		row('arith  (typed locals)', arithSlow, arithFast);

		Sys.exit(0);
	}

	static function row(name:String, slow:Float, fast:Float):Void {
		var gain:String = fast <= 0 ? 'n/a' : (Math.round((slow / fast) * 10) / 10) + 'x';
		say('  ' + pad(name, 26) + pad(round(slow) + ' ms', 12) + pad(round(fast) + ' ms', 12) + gain);
	}

	static function round(ms:Float):String {
		return Std.string(Math.round(ms * 100) / 100);
	}

	static function pad(v:String, width:Int):String {
		var out:String = v;
		while (out.length < width)
			out += ' ';
		return out + ' ';
	}
}
