import hxscript.Environment;
import hxscript.Module;
import hxscript.compile.Compiler;
import hxscript.compile.Report;
import hxscript.types.ScriptedClass;

/** A host static a script can call and that always throws, for the case that crosses back out. */
class Bomb {
	public static function now(what:String):Int {
		throw 'the host threw ' + what;
	}
}

/**
 * Whether throwing works in an HL/C program once a script has been compiled.
 *
 * Worth asking on its own, because exceptions are the one thing that has to cross between jitted
 * code and code the C generator wrote in both directions and has to unwind the stack while doing it.
 * Three things could have gone wrong and only one of them shows up as a wrong answer:
 *
 * A throw out of compiled code has to reach a `catch` that HL/C compiled. HL's exceptions are
 * setjmp and longjmp inside libhl, which both halves share, so this should hold, and if it does not
 * it takes the process with it rather than returning something wrong.
 *
 * Capturing a stack across a jitted frame looked like the doubtful one, and the answer turned out to
 * be that there is nothing to be doubtful about. A release HL/C build reports **no** exception stack
 * at all, and the case that throws from the host alone is here to say so: both give zero frames, so
 * the empty trace is what this target does rather than something compiled code took away. That
 * control is the whole reason the number is worth printing.
 *
 * What is required is only that asking does not crash. Naming a jitted frame cannot work in any
 * case, since `hlc_resolve_symbol` asks the symbol server about an address that is in no image it
 * knows, so nothing here asks the frames to be useful.
 */
class ThrowProbe {
	static var SOURCE:String = 'package p;
class T {
	public static function boom(what:String):Int {
		throw "a script threw " + what;
	}

	public static function caughtHere(what:String):String {
		try {
			boom(what);
			return "nothing was thrown";
		} catch (e:Dynamic) {
			return "caught " + Std.string(e);
		}
	}

	public static function fromTheHost():String {
		try {
			Bomb.now("through a script");
			return "nothing was thrown";
		} catch (e:Dynamic) {
			return "caught " + Std.string(e);
		}
	}

	public static function deep(n:Int):Int {
		if (n <= 0)
			throw "the bottom";
		return deep(n - 1) + 1;
	}

	public static function fine(n:Int):Int {
		return n * 2;
	}
}
';

	static var failures:Int = 0;

	public static function main():Void {
		Sys.println('-- throwing across compiled and generated code --');

		var env:Environment = new Environment();
		env.variables.set('Bomb', Bomb);

		var module:Module = new Module('', 'T', ['p'], 'hlc');
		module.parse(SOURCE);
		env.addModule(module);
		module.init(env);
		module.start(env);
		module.startTypes(env);

		var built:Report = Compiler.compile(env, [module]);
		say('the module compiled', built.compiled.length > 0);

		if (built.skipped.length > 0)
			Sys.println('    refused: ' + built.skipped[0].reason);

		var cls:ScriptedClass = cast env.resolve('p.T');

		say('a script catches its own throw', text(cls, 'caughtHere', ['once']) == 'caught a script threw once');
		say('a script catches what the host threw', text(cls, 'fromTheHost', []) == 'caught the host threw through a script');

		var out:String = 'nothing was thrown';
		try {
			Reflect.callMethod(null, cls.reflectGetField('boom'), ['outward']);
		} catch (e:Dynamic) {
			out = Std.string(e);
		}
		say('the host catches what a script threw', out == 'a script threw outward');

		var deep:String = 'nothing was thrown';
		var frames:Int = -1;
		try {
			Reflect.callMethod(null, cls.reflectGetField('deep'), [12]);
		} catch (e:Dynamic) {
			deep = Std.string(e);
			frames = stack();
		}
		say('a throw twelve frames down still arrives', deep == 'the bottom');
		say('capturing a stack across jitted frames did not crash', frames >= 0);

		var ordinary:Int = -1;
		try {
			Bomb.now('from the host alone');
		} catch (e:Dynamic) {
			ordinary = stack();
		}

		Sys.println('    across jitted frames: ' + frames + ', from the host alone: ' + ordinary);
		say('a host-only throw did not crash either', ordinary >= 0);

		say('the world still works afterwards', Std.string(Reflect.callMethod(null, cls.reflectGetField('fine'), [21])) == '42');

		var again:String = 'nothing was thrown';
		try {
			Reflect.callMethod(null, cls.reflectGetField('boom'), ['twice']);
		} catch (e:Dynamic) {
			again = Std.string(e);
		}
		say('and it can throw again', again == 'a script threw twice');

		Sys.println(failures == 0 ? '== throwing holds ==' : '== ' + failures + ' failed ==');
		Sys.exit(failures == 0 ? 0 : 1);
	}

	/**
	 * Renders the stack of the exception just caught.
	 *
	 * The rendering is what is being tested rather than the result. Frames from jitted code are in no
	 * image the symbol server knows, so what they read as is not something to require anything of.
	 *
	 * @return How many frames it gave, or -1 when asking threw.
	 */
	static function stack():Int {
		try {
			var frames:Array<haxe.CallStack.StackItem> = haxe.CallStack.exceptionStack();
			haxe.CallStack.toString(frames);
			return frames.length;
		} catch (e:Dynamic) {
			return -1;
		}
	}

	/**
	 * @param cls The compiled class.
	 * @param field Which function.
	 * @param args What to call it with.
	 * @return What it answered, as a string.
	 */
	static function text(cls:ScriptedClass, field:String, args:Array<Dynamic>):String {
		return Std.string(Reflect.callMethod(null, cls.reflectGetField(field), args));
	}

	static function say(what:String, ok:Bool):Void {
		if (!ok)
			failures++;

		var pad:String = what;
		while (pad.length < 54)
			pad += ' ';

		Sys.println('  ' + pad + (ok ? 'yes' : 'NO'));
	}
}
