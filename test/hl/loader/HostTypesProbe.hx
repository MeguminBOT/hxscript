import hxscript.Environment;
import hxscript.Module;
import hxscript.compile.Compiler;
import hxscript.compile.Report;
import hxscript.types.ScriptedClass;

/**
 * The cases the cppia test carries beyond the shared corpus, asked of HashLink.
 *
 * They are not in the corpus because each needs a host fixture, and the corpus holds only what runs
 * anywhere. That is a good reason to keep them out of it and a bad reason to leave one backend
 * untested on them, since a fixture in `test/common/fixtures` is as available here as there.
 *
 * What they are about: a native enum abstract's constant is a value once compiled and nothing else,
 * and a host type reached through a typedef, or through a typedef of a typedef, has to resolve to
 * what it aliases rather than to a name nothing answers to.
 */
class HostTypesProbe {
	/**
	 * Names the fixtures in Haxe so they are in the build.
	 *
	 * Nothing else here mentions them: they appear only inside the script strings below, and a string
	 * is not a reference, so dead code elimination has no reason to keep either. This is the
	 * reference, and it is the same problem a real host has with any type its scripts name and its
	 * own code does not.
	 */
	@:keep static function force():Void {
		var alias:AliasTarget = new AliasTarget();
		var blend:OpBlend = OpBlend.ADD;

		if (alias.n == -1 && blend == OpBlend.NORMAL)
			Sys.println('unreachable, and only here to be a reference');
	}

	static var passed:Int = 0;
	static var failed:Int = 0;
	static var refused:Int = 0;

	/**
	 * Runs one case both ways and compares.
	 *
	 * @param label How to name it.
	 * @param body The method body.
	 * @param want What it should produce.
	 * @param before Declarations preceding the class, such as the imports these need.
	 */
	static function check(label:String, body:String, want:String, before:String):Void {
		var source:String = 'package p;\n' + before + '\nclass T {\n\tpublic static function run():Dynamic {\n\t\t' + body + '\n\t}\n}\n';

		var interpreted:String = run(source, false);

		if (interpreted != want) {
			failed++;
			say(label, 'the interpreter gave ' + interpreted + ', wanting ' + want);
			return;
		}

		var got:String = run(source, true);

		if (StringTools.startsWith(got, 'REFUSED')) {
			refused++;
			say(label, got);
			return;
		}

		if (got == want) {
			passed++;
			say(label, got);
		} else {
			failed++;
			say(label, got + '   INTERPRETED ' + want);
		}
	}

	/**
	 * @param source The module.
	 * @param compile Whether to offer it to the backend first.
	 * @return What `run()` answered, or what went wrong.
	 */
	static function run(source:String, compile:Bool):String {
		try {
			var env:Environment = new Environment();
			var module:Module = new Module('', 'T', ['p'], 'hosttypes');
			module.parse(source);
			env.addModule(module);
			module.init(env);
			module.start(env);
			module.startTypes(env);

			if (compile) {
				var report:Report = Compiler.compile(env, [module]);
				if (report.compiled.length == 0)
					return 'REFUSED ' + (report.skipped.length > 0 ? report.skipped[0].reason : 'no reason given');
			}

			var cls:ScriptedClass = cast env.resolve('p.T');
			return Std.string(Reflect.callMethod(null, cls.reflectGetField('run'), []));
		} catch (e:Dynamic) {
			return 'threw ' + Std.string(e);
		}
	}

	static function say(label:String, what:String):Void {
		var pad:String = label;
		while (pad.length < 38)
			pad += ' ';
		Sys.println('  ' + pad + what);
		Sys.stdout().flush();
	}

	public static function main():Void {
		Sys.println('-- host enum abstracts and typedefs --');

		var blend:String = 'import OpBlend;';

		check('enum abstract constant folds', 'return Std.string(OpBlend.ADD);', 'add', blend);
		check('enum abstract constant compares', 'return OpBlend.ADD == "add" ? "eq" : "ne";', 'eq', blend);
		check('enum abstract constant in a call', 'return Std.string(OpBlend.NORMAL).toUpperCase();', 'NORMAL', blend);

		check('new through a host typedef', 'var v = new AliasFixture(); return v.n;', '7', 'import AliasTarget.AliasFixture;');
		check('host typedef of a typedef', 'var v = new AliasTwice(); return v.n;', '7', 'import AliasTarget.AliasTwice;');

		Sys.println('== ' + passed + ' passed, ' + failed + ' failed ==, ' + refused + ' refused');
		Sys.exit(failed == 0 ? 0 : 1);
	}
}
