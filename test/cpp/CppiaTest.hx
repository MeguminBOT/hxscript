import haxe.io.Bytes;
import hxscript.Environment;
import hxscript.Module;
import hxscript.cppia.Backend;
import hxscript.compile.Unit;
import hxscript.compile.Result;
import hxscript.types.ScriptedClass;

/**
 * Differential test for the cppia backend: each case runs from the same source through both the
 * interpreter and the compiler, and the two answers must agree.
 *
 * The host must be built with `-D scriptable`.
 */
class CppiaTest {
	/** Constructs the emitter declined. Reported, but not a failure: the interpreter still runs them. */
	static var refused:Int = 0;

	/**
	 * Puts the abstract fixture in the build, which naming it in a script cannot do.
	 *
	 * `-dce no` keeps what is there; it does not type what nothing references. A fixture only ever named
	 * from script source is never typed, so its `@:build` never runs, no wrapper is generated, and the
	 * script fails with `Type not found`. That is also what a host gets wrong in exactly this way, and why
	 * `Autowire.include` exists.
	 */
	@:keep static var fixture:OpBlend = OpBlend.ADD;

	/** Keeps the typedef fixture's target in the build, for the same reason. */
	@:keep static var aliased:AliasTarget = null;

	/** The plain abstract with `inline` constants, which is the shape `flixel.util.FlxColor` has. */
	@:keep static var colour:OpColor = OpColor.RED;

	/** The enum abstract whose constants collide with its own accessors, as `flixel.util.FlxAxes` does. */
	@:keep static var axes:HostAxes = HostAxes.X;

	/** The abstract with an assignable static, which is the one shape that cannot be folded. */
	@:keep static var vector:OpVec = OpVec.ZERO;

	/** The abstract over a class, which is the shape every geometry type in a framework has. */
	@:keep static var vec:HostVec = null;

	public static function run():Void {
		/**
		 * On by default, because it is a different code path: an expression the JIT has no generator
		 * for emits nothing at all rather than falling back, so a construct can pass every test here
		 * and still do nothing in a host that turned the JIT on.
		 *
		 * `HXSCRIPT_NO_JIT=1` runs the same cases through the interpreting loader instead, which is
		 * what a host that called `Backend.jit = false` or was dropped to it by `retryWithoutJit` runs.
		 * Both are shipped configurations, so both are worth a pass.
		 */
		var jit:Bool = Sys.getEnv('HXSCRIPT_NO_JIT') != '1';
		cpp.cppia.Host.enableJit(jit);
		TestCase.log('  cppia jit: ' + jit);

		Corpus.run(check);

		// A native abstract's constant is a value and nothing else once compiled, and the emitter has
		// to say so. Naming it as a static instead produced `Bad link`, which the loader raises for the
		// whole module and attributes to nothing inside it, so one such constant cost every class in
		// the batch its bytecode.
		var blend:String = 'import OpBlend;';
		// Through `Std.string` rather than returned bare, because the interpreter hands back the boxed
		// wrapper and the compiler hands back the value, and this is about the value being right rather
		// than about which side does the unboxing.
		check('enum abstract constant folds', 'return Std.string(OpBlend.ADD);', 'add', '', blend);
		check('enum abstract constant compares', 'return OpBlend.ADD == "add" ? "eq" : "ne";', 'eq', '', blend);
		check('enum abstract constant in a call', 'return Std.string(OpBlend.NORMAL).toUpperCase();', 'NORMAL', '', blend);
		/**
		 * The other half of a host abstract: everything it declares that is not a constant. An abstract
		 * has no runtime form, so Haxe moves its members onto a companion class and passes the value
		 * that would be `this` first. Compiled script code takes the same route, which is what makes
		 * `FlxColor.fromRGB(...)` and `colour.getDarkened(0.5)` mean anything once compiled.
		 */
		check('a static method of an abstract', 'return OpBlend.additive("add") ? "y" : "n";', 'y', '', blend);
		check('a static method of an abstract, false', 'return OpBlend.additive("no") ? "y" : "n";', 'n', '', blend);

		/**
		 * The same thing for a PLAIN abstract, which is what flixel's FlxColor is. Being an enum
		 * abstract used to stand in for being a constant, so `FlxColor.RED` had no bytecode spelling and
		 * one of them anywhere in a script left the whole module interpreted, which is most flixel
		 * scripts. `RED` also collides with the `get_red` accessor, so the wrapper holds it as a plain
		 * static rather than behind a lazy getter, and reading only the getter found nothing.
		 */
		var colour:String = 'import OpColor;';
		check('plain abstract constant folds', 'return Std.string(OpColor.BLUE);', Std.string(OpColor.BLUE), '', colour);
		check('constant colliding with an accessor folds', 'return Std.string(OpColor.RED);', Std.string(OpColor.RED), '',
			colour);
		check('plain abstract constant compares', 'return OpColor.RED == ' + Std.string(OpColor.RED) + ' ? "eq" : "ne";', 'eq',
			'', colour);
		check('enum abstract constant colliding with an accessor folds', 'return Std.string(HostAxes.X);',
			Std.string(HostAxes.X), '', 'import HostAxes;');

		/**
		 * The other half of the same decision: an ordinary `static var` is assignable, so its value is
		 * not the emitter's to write down. It is READ instead, from the implementation class, which is
		 * where the host's own code reads it and so is the same variable rather than the wrapper's copy.
		 */
		var vector:String = 'import OpVec;';
		check('a static of an abstract that is not a constant', 'var z:Int = OpVec.ZERO; return Std.string(z);', '0', '',
			vector);

		/**
		 * A member reached on the value, which is the shape most of a colour or a vector's surface has.
		 * `red` is an accessor and `toHexString` a method, and both are statics of the implementation
		 * taking the value first. Read wrongly rather than refused before this: the accessor fell to
		 * `Reflect.getProperty` on the underlying `Int` and answered null.
		 */
		check('an accessor on a host abstract value', 'var c:OpColor = OpColor.RED; return Std.string(c.red);', '255', '',
			colour);
		check('a read-only accessor on a host abstract value', 'var c:OpColor = OpColor.BLUE; return Std.string(c.alpha);',
			'255', '', colour);
		check('a method on a host abstract value', 'var c:OpColor = OpColor.RED; return c.toHexString();', 'FFFF0000', '',
			colour);
		check('a method on a host abstract, chained', 'var c:OpColor = OpColor.RED; return Std.string(c.red + c.alpha);', '510',
			'', colour);
		check('a host abstract over a class, its accessor', 'var v = new HostVec(3, 4); return Std.string(v.length);', '5', '',
			'import HostVec;');
		check('a host abstract over a class, its method',
			'var v = new HostVec(1, 2); return Std.string(v.plus(new HostVec(3, 4)));', '4:6', '', 'import HostVec;');

		check('new through a host typedef', 'var v = new AliasFixture(); return v.n;', '7',
			'', 'import AliasTarget.AliasFixture;');

		check('host typedef of a typedef', 'var v = new AliasTwice(); return v.n;', '7',
			'', 'import AliasTarget.AliasTwice;');

		TestCase.log('  refused by the emitter: ' + refused);
	}

	static function main():Void {
		run();
		TestCase.exit();
	}

	/**
	 * Runs one body both ways and compares. A refusal is reported but does not count as a failure.
	 *
	 * @param label How to name the case in the report.
	 * @param body The method body to run.
	 * @param want The expected result.
	 * @param extra Extra class members.
	 * @param before Declarations preceding the class.
	 */
	static function check(label:String, body:String, want:String, extra:String = '', before:String = ''):Void {
		var source:String = 'package p;\n' + before + '\n' + 'class T {\n' + extra + '\n' + '\tpublic static function run():Dynamic {\n' + '\t\t' + body
			+ '\n' + '\t}\n' + '}\n';

		var interpreted:String = runInterpreted(source);
		if (interpreted != want) {
			TestCase.bad(label, 'interpreter itself gave ' + interpreted + ', wanted ' + want);
			return;
		}

		var decls = parse(source);
		if (decls == null) {
			TestCase.bad(label, 'could not parse');
			return;
		}

		var result:Result = Backend.compile([{name: 'p.T', decls: decls}]);

		if (result.bytes == null) {
			refused++;
			var why:String = result.skipped.length > 0 ? result.skipped[0].reason : 'no reason given';
			TestCase.log('  skip ' + label + '   refused: ' + why);
			return;
		}

		var got:String = runCompiled(result.bytes, label);
		if (got == want) {
			TestCase.ok(label, true);
		} else {
			TestCase.bad(label, 'cppia gave ' + got + ', interpreter gave ' + interpreted);
		}
	}

	/**
	 * Requires that the emitter decline a body, for the reason it should decline it for.
	 *
	 * The opposite assertion to `check`, and worth making separately: a construct with no bytecode
	 * spelling has two possible outcomes, and only one of them is acceptable. Refusing costs the
	 * module its speedup and nothing else. Emitting something the loader will not take costs every
	 * module in the batch, and says so in terms that name neither the class nor the field.
	 *
	 * @param label How to name the case in the report.
	 * @param body The method body.
	 * @param mentions A word the reason must contain, so it is refused for the right cause.
	 * @param before Declarations preceding the class.
	 */
	static function refuses(label:String, body:String, mentions:String, before:String = ''):Void {
		var source:String = 'package p;\n' + before + '\nclass T {\n\tpublic static function run():Dynamic {\n\t\t' + body + '\n\t}\n}\n';

		var decls = parse(source);
		if (decls == null) {
			TestCase.bad(label, 'could not parse');
			return;
		}

		var result:Result = Backend.compile([{name: 'p.T', decls: decls}]);

		if (result.bytes != null) {
			TestCase.bad(label, 'the emitter accepted it');
			return;
		}

		refused++;

		var why:String = result.skipped.length > 0 ? result.skipped[0].reason : '';

		if (why.indexOf(mentions) < 0)
			TestCase.bad(label, 'refused, but for "' + why + '" rather than anything about ' + mentions);
		else
			TestCase.ok(label + '   ' + why, true);
	}

	static function parse(source:String):Array<hxscript.syntax.Expr.ModuleDecl> {
		try {
			var parser = new hxscript.syntax.Parser();
			return parser.parseModule(source, 'test', 0, ['p']);
		} catch (e:Dynamic) {
			Sys.println('parse error: ' + e);
			return null;
		}
	}

	static function runInterpreted(source:String):String {
		try {
			var env:Environment = new Environment();
			var module:Module = new Module('', 'T', ['p'], 'test');
			var problem:String = null;
			module.onParsingError = function(e:haxe.Exception):Void {
				if (problem == null)
					problem = 'parse: ' + e.message;
			};
			module.onProgramError = function(e:haxe.Exception):Void {
				if (problem == null)
					problem = 'program: ' + e.message;
			};
			module.parse(source);
			env.addModule(module);
			module.init(env);
			module.start(env);
			module.startTypes(env);

			if (problem != null)
				return problem;

			var cls:ScriptedClass = cast env.resolve('p.T');
			return Std.string(Reflect.callMethod(null, cls.reflectGetField('run'), []));
		} catch (e:Dynamic) {
			return 'threw: ' + e;
		}
	}

	static function runCompiled(bytes:Bytes, label:String):String {
		try {
			var module = cpp.cppia.Module.fromData(bytes.getData());
			module.boot();
			var cls:Class<Dynamic> = module.resolveClass('p.T');
			if (cls == null)
				return 'class did not resolve';
			return Std.string(Reflect.callMethod(cls, Reflect.field(cls, 'run'), []));
		} catch (e:Dynamic) {
			return 'load threw: ' + e;
		}
	}
}
