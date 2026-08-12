import hxscript.Environment;
import hxscript.Module;
import hxscript.cppia.Backend;
import hxscript.compile.Result;
import hxscript.types.ScriptedClass;

/**
 * Checks whether a native failure inside compiled code can be caught by the script that caused it.
 *
 * A script's own `throw` is a value the interpreter and cppia both understand. Calling something that
 * turned out to be null is not: it fails inside the runtime, and whether that unwinds into a script's
 * `catch` or straight past it decides whether a guard around risky code is worth anything.
 */
class CatchNative {
	static var SRC:String = 'package p;
class T {
	public static function run(f:Dynamic):Dynamic {
		try {
			f();
			return "called";
		} catch (e:Dynamic) {
			return "caught";
		}
	}
}
';

	public static function run():Void {
		cpp.cppia.Host.enableJit(true);

		var env = new Environment();
		var m = new Module(SRC, 'T', ['p'], 'probe');
		env.addModule(m);
		m.init(env);
		m.start(env);
		m.startTypes(env);

		var cls:ScriptedClass = cast env.resolve('p.T');
		Sys.println('interpreted -> ' + safely(cls.reflectGetField('run')));

		var decls = new hxscript.syntax.Parser().parseModule(SRC, 'T', 0, ['p']);
		var r:Result = Backend.compile([{name: 'p.T', decls: decls}]);
		if (r.bytes == null) {
			Sys.println('refused: ' + r.skipped[0].reason);
			return;
		}

		var mod = cpp.cppia.Module.fromData(r.bytes.getData());
		mod.boot();
		Sys.println('compiled    -> ' + safely(Reflect.field(mod.resolveClass('p.T'), 'run')));
	}

	/** Calls the script with a null function, reporting what escaped if anything did. */
	static function safely(fn:Dynamic):String {
		try {
			return Std.string(Reflect.callMethod(null, fn, [null]));
		} catch (e:Dynamic) {
			return 'ESCAPED: ' + e;
		}
	}

	static function main():Void {
		run();
		TestCase.exit();
	}
}
