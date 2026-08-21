import hxscript.Config;
import hxscript.Environment;
import hxscript.Module;
import hxscript.compile.Compiler;
import hxscript.compile.Report;
import hxscript.runtime.Interp;
import hxscript.types.ScriptedClass;
import TestCase;

/**
 * A host object for a global to hold, so a bound value that is neither a type nor a primitive has
 * something real to be.
 */
class GlobalHolder {
	public static function ping(s:String):String {
		return 'ping-' + s;
	}

	public var tag:String = 'held';

	public function new() {}

	public function shout():String {
		return tag.toUpperCase();
	}
}

/**
 * An interpreter binding a name that is in no table at all, which is the `ModInterp` pattern
 * `docs/advanced.md` documents. Compiled code reaching one of these is the case no other surface
 * covers: there is no variable, no import and no static to find it by.
 */
class ContextInterp extends Interp {
	override public function isResolvable(id:String):Bool {
		return id == 'contextual' || super.isResolvable(id);
	}

	override public function resolve(id:String):Dynamic {
		return id == 'contextual' ? 'from-context' : super.resolve(id);
	}
}

/**
 * Checks that a name the host bound rather than the script declared reaches compiled code, means the
 * same thing there as interpreted, and is read through the narrowest spelling its value allows.
 *
 * **The comparison has to run the compiled class, not the world's.** A world hands back the scripted
 * class, whose statics are the interpreter's, so calling through it compares interpreted to
 * interpreted and passes whatever the emitter wrote. Every case here runs both, the compiled half
 * through the class the emitter built.
 */
class GlobalsTest {
	public static function run():Void {
		agreement();
		spellings();
		aliases();
		shadowing();
		context();
		pins();
		mismatch();
		slots();
		refusal();
		disabled();
	}

	/** Every shape of use, interpreted and compiled, asserted to answer the same thing. */
	static function agreement():Void {
		TestCase.section('a global means the same compiled as interpreted');

		same('read Int', 'return "" + damage;', '21');
		same('write Int', 'damage = 5; return "" + damage;', '5');
		same('compound assign', 'damage += 4; return "" + damage;', '25');
		same('increment', 'damage++; return "" + damage;', '22');
		same('read Bool', 'return "" + flag;', 'true');
		same('Bool in a condition', 'return flag ? "yes" : "no";', 'yes');
		same('read String', 'return label.toUpperCase();', 'HI');
		same('read Float', 'return "" + (ratio * 2);', '3');
		same('call a bound closure', 'return "" + roll(6);', '12');
		same('a bound host object', 'return battle.shout();', 'HELD');
		same('index a bound array', 'return "" + names[1];', 'b');
		same('index a bound map', 'return "" + scores["a"];', '11');
		same('a global in a loop', 'var n = 0; for (i in 0...3) n += damage; return "" + n;', '63');
		same('a name from Config.globalVariables', 'return "" + configured;', 'from-config');
	}

	/**
	 * What each bound value was read as.
	 *
	 * **A `Bool` is the one worth asserting hardest.** cppia has no boolean of its own, so a boolean
	 * that arrives boxed comes back as `1` and prints as `1`, which reads correctly in a condition and
	 * wrongly everywhere else. A typed accessor is what keeps it a boolean, so the spelling and the
	 * printed value are two halves of the same check.
	 */
	static function spellings():Void {
		TestCase.section('a bound value decides how narrowly it is read');

		TestCase.eq('Int reads as Int', spellingOf('return "" + damage;', 'damage'), 'Int');
		TestCase.eq('Float reads as Float', spellingOf('return "" + ratio;', 'ratio'), 'Float');
		TestCase.eq('Bool reads as Bool', spellingOf('return "" + flag;', 'flag'), 'Bool');
		TestCase.eq('String reads as String', spellingOf('return label;', 'label'), 'String');
		TestCase.eq('a host object reads as its class', spellingOf('return battle.shout();', 'battle'), 'GlobalHolder');
		TestCase.eq('an array reads as Array', spellingOf('return "" + names[0];', 'names'), 'Array');
		TestCase.eq('a closure falls back to Dynamic', spellingOf('return "" + roll(1);', 'roll'), 'Dynamic');
	}

	/**
	 * A name bound to a type, which is the one binding that must not become a lookup at all.
	 *
	 * A boxed `Class` cannot be constructed through, called statically through, or read statically
	 * through, so the alias has to become the path itself. `Bucket` is the same class as `Sink` under
	 * a name of the host's choosing, and only the alias was ever refused.
	 */
	static function aliases():Void {
		TestCase.section('a name bound to a type becomes the type');

		same('a type under its own name', 'return Sink.ping("x");', 'ping-x');
		same('a type under a host alias', 'return Bucket.ping("x");', 'ping-x');
		same('new through the alias', 'return new Bucket().shout();', 'HELD');

		TestCase.eq('an alias costs no lookup', spellingOf('return Bucket.ping("x");', 'Bucket'), 'not read');
	}

	/** A local of the same name, which must win the way it does interpreted. */
	static function shadowing():Void {
		TestCase.section('a name the script declares wins');

		same('a local shadows a global', 'var damage = 99; damage += 1; return "" + damage;', '100');
		same('a parameter shadows a global', 'return inner(7);', '7',
			'static function inner(damage:Int):String return "" + damage;');
	}

	/** A name no table holds, bound by an interpreter of the host's own. */
	static function context():Void {
		TestCase.section('an Interp override reaches compiled code');

		var was:Class<Interp> = Config.interpClass;
		Config.interpClass = ContextInterp;

		same('a name only resolve() answers for', 'return contextual;', 'from-context');

		Config.interpClass = was;
	}

	/** The host correcting or declaring what a name holds. */
	static function pins():Void {
		TestCase.section('a host can say what a name holds');

		Compiler.globalNames = ['damage:Dynamic'];
		TestCase.eq('a pin beats the bound value', spellingOf('return "" + damage;', 'damage'), 'Dynamic');
		Compiler.globalNames = [];

		/**
		 * A name bound only after the compile, which reading a value cannot decide because there is no
		 * value to read. Declaring it is the whole of what the host has to do.
		 */
		Compiler.globalNames = ['later:Int'];
		Compiler.reset();

		var env:Environment = world('class C { public static function go():String return "" + later; }');
		var report:Report = Compiler.compile(env);
		table(env).set('later', 7);

		TestCase.ok('a name bound after the compile still compiles', report.compiled.length > 0);
		TestCase.eq('and answers once it is bound', compiled(), '7');

		Compiler.globalNames = [];
	}

	/**
	 * A host changing what a compiled name holds.
	 *
	 * Reported rather than coerced. Coercing would make a compiled read answer something the same
	 * interpreted read would not, and a divergence nothing mentions is worse than a throw that names
	 * both types.
	 *
	 * **Reported at the write.** A compiled read of a typed global is a static field read with no room
	 * for a check in it, so the write is both the only place that can notice and the better one: it
	 * names the line that broke the contract rather than a read that merely suffered from it.
	 */
	static function mismatch():Void {
		TestCase.section('a rebound global is reported, not coerced');

		Compiler.reset();

		var env:Environment = world('class C { public static function go():String return "" + damage; }');
		Compiler.compile(env);

		TestCase.eq('reads what it was compiled against', compiled(), '21');

		var complaint:String = try {
			table(env).set('damage', 'oops');
			'nothing was said';
		} catch (e:Dynamic) {
			Std.string(e);
		}

		TestCase.ok('a changed type is reported', complaint.indexOf('was compiled as Int') >= 0);
		TestCase.ok('and the report names what it holds now', complaint.indexOf('String') >= 0);

		/** The refused write left the name as it was, rather than half-applied. */
		TestCase.eq('and the name still holds what it did', compiled(), '21');
	}

	/**
	 * What keeping a fast copy of a global has to hold up against.
	 *
	 * A compiled read of a typed global is a static field read, 2.3ns against 92ns through the
	 * interpreter, and the copy behind it is only sound while every way of writing the name reaches
	 * it. There are three, and a fourth case where there must be no copy at all.
	 */
	static function slots():Void {
		TestCase.section('a copied global stays in step with the table');

		/** The host writing the table directly, which is what `Bindings` exists to notice. */
		Compiler.reset();
		var byHost:Environment = world('class C { public static function go():String return "" + damage; }');
		Compiler.compile(byHost);
		TestCase.eq('starts at what it was bound to', compiled(), '21');

		table(byHost).set('damage', 99);
		TestCase.eq('a host write is seen', compiled(), '99');
		TestCase.eq('and the interpreter agrees', interpreted(byHost), '99');

		table(byHost).remove('damage');
		table(byHost).set('damage', 5);
		TestCase.eq('a removed and re-set name is seen', compiled(), '5');

		/** An interpreted script writing it, which goes through `setVar` into the same table. */
		Compiler.reset();
		var byScript:Environment = world('class C {
'
			+ 'public static function bump():Void { damage = 77; }
'
			+ 'public static function go():String return "" + damage;
}');
		Compiler.compile(byScript);

		var scripted:ScriptedClass = cast byScript.resolve('C');
		Reflect.callMethod(null, scripted.reflectGetField('bump'), []);
		TestCase.eq('an interpreted write is seen by compiled code', compiled(), '77');

		/** A second world claiming a module the first one compiled. */
		Compiler.reset();
		var first:Environment = world('class C { public static function go():String return "" + damage; }');
		Compiler.compile(first);
		table(first).set('damage', 11);
		TestCase.eq('the first world reads its own', compiled(), '11');

		var second:Environment = world('class C { public static function go():String return "" + damage; }');
		Compiler.compile(second);
		table(second).set('damage', 22);
		TestCase.eq('a second world re-points the copy', compiled(), '22');

		/**
		 * A static initialiser runs while the module boots, which is before any copy has been filled,
		 * so one reading a global has to ask the interpreter rather than read an empty slot.
		 */
		Compiler.reset();
		var booting:Environment = world('class C {
'
			+ 'public static var seeded:Int = damage;
'
			+ 'public static function go():String return "" + seeded;
}');
		Compiler.compile(booting);
		TestCase.eq('a static initialiser reads the real value', compiled(), '21');
	}

	/** A name nothing holds, which must still be refused rather than compiled into a lookup that throws. */
	static function refusal():Void {
		TestCase.section('a name nothing holds is still refused');

		Compiler.reset();

		var env:Environment = world('class C { public static function go():String return "" + nosuchname; }');
		var report:Report = Compiler.compile(env);

		TestCase.ok('a typo does not compile', report.compiled.length == 0);
		TestCase.ok('and is reported as an unresolved identifier', report.skipped.length > 0 && report.skipped[0].reason.indexOf('unresolved identifier nosuchname') >= 0);
	}

	/** The older behaviour, for a host that would rather be told than served quietly. */
	static function disabled():Void {
		TestCase.section('globals can be turned off');

		Compiler.globals = false;
		Compiler.reset();

		var env:Environment = world('class C { public static function go():String return "" + damage; }');
		var report:Report = Compiler.compile(env);

		TestCase.ok('a global refuses its module again', report.compiled.length == 0);
		TestCase.ok('and says which name it was', report.skipped.length > 0 && report.skipped[0].reason.indexOf('unresolved identifier damage') >= 0);

		Compiler.globals = true;
	}

	/**
	 * Runs one body both ways and checks the two agree, and that the compiled half really is compiled.
	 *
	 * @param label How to name it.
	 * @param body The method body.
	 * @param want What both halves should answer.
	 * @param extra Extra members of the class the body sits in.
	 */
	static function same(label:String, body:String, want:String, ?extra:String):Void {
		var source:String = 'class C {\n'
			+ (extra == null ? '' : extra + '\n')
			+ 'public static function go():String { '
			+ body
			+ ' }\n}';

		Compiler.reset();
		var interpretedWorld:Environment = world(source);
		var interpretedAnswer:String = interpreted(interpretedWorld);

		Compiler.reset();
		var compiledWorld:Environment = world(source);
		Compiler.compile(compiledWorld);

		if (!Compiler.isCompiled('C')) {
			TestCase.bad(label, 'was left interpreted, so nothing was compared');
			return;
		}

		var compiledAnswer:String = compiled();

		if (interpretedAnswer != compiledAnswer) {
			TestCase.bad(label, 'interpreted ' + interpretedAnswer + ', compiled ' + compiledAnswer);
			return;
		}

		TestCase.eq(label, compiledAnswer, want);
	}

	/**
	 * @param body A method body naming the global.
	 * @param name The global to ask about.
	 * @return How the emitter spelled it, or `not read` when it needed no lookup at all.
	 */
	static function spellingOf(body:String, name:String):String {
		Compiler.reset();

		var env:Environment = world('class C { public static function go():String { ' + body + ' } }');
		var report:Report = Compiler.compile(env);

		for (use in report.globals) {
			if (use.name == name)
				return use.spelling;
		}

		return 'not read';
	}

	/** @return A world holding one module, with every kind of value a host binds. */
	static function world(source:String):Environment {
		Config.globalVariables.set('configured', 'from-config');

		var env:Environment = new Environment();
		env.variables.set('damage', 21);
		env.variables.set('flag', true);
		env.variables.set('label', 'hi');
		env.variables.set('ratio', 1.5);
		env.variables.set('roll', function(sides:Int) return sides * 2);
		env.variables.set('Sink', GlobalHolder);
		env.variables.set('Bucket', GlobalHolder);
		env.variables.set('battle', new GlobalHolder());
		env.variables.set('names', ['a', 'b', 'c']);
		env.variables.set('scores', ['a' => 11, 'b' => 22]);

		env.addModule(new Module(source, 'G', []));
		env.start();
		return env;
	}

	/**
	 * The table the class `C` resolves its host-bound names against.
	 *
	 * **Not the module's.** A scripted class runs on an interpreter of its own, seeded with a copy of
	 * the module's names at `init` rather than sharing them, so writing `module.variables` afterwards
	 * reaches neither an interpreted read inside the class nor a compiled one. Compiled code is bound
	 * to the same table its interpreted form reads, which is this one.
	 *
	 * @param env The world.
	 * @return The class's own bindings.
	 */
	static function table(env:Environment):hxscript.runtime.Bindings {
		return @:privateAccess cast(env.resolve('C'), ScriptedClass).interp.variables;
	}

	/** @return The world's only module. */
	static function module(env:Environment):Module {
		for (m in env.modules)
			return m;

		return null;
	}

	/** @return What the world's scripted class answers, which is the interpreter's. */
	static function interpreted(env:Environment):String {
		var cls:ScriptedClass = cast env.resolve('C');
		return Std.string(Reflect.callMethod(null, cls.reflectGetField('go'), []));
	}

	/** @return What the class the emitter built answers, which is the only compiled route to it. */
	static function compiled():String {
		var cls:Dynamic = Compiler.substitute('C');
		return Std.string(Reflect.callMethod(null, Reflect.field(cls, 'go'), []));
	}
}
