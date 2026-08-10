import hxscript.Environment;
import hxscript.Module;
import hxscript.compile.Compiler;
import hxscript.macro.Expose;
import hxscript.types.ScriptedClass;

/** A host type a script may name, with statics it may reach by a bare name. */
@:scriptAmbient
class Armoury {
	@:scriptStatic('armoury')
	public static var shared:Armoury = new Armoury();

	@:scriptStatic
	public static var version:Int = 3;

	public var stock:Int = 12;

	public function new() {}

	public function take(n:Int):Int {
		stock -= n;
		return stock;
	}
}

/** Not marked, so the emitter should not be told where it lives. */
class Hidden {
	public static var secret:Int = 99;

	public function new() {}
}

/** Checks the macro finds what is marked, and that what it produces actually compiles. */
class ExposeTest {
	// `armoury` and `version` are bare names here: no import, no declaration.
	static var SCRIPT:String = 'package s;\nclass Raid {\n'
		+ '\tpublic static function run():Int {\n'
		+ '\t\tvar left:Int = armoury.take(5);\n'
		+ '\t\treturn left + version;\n'
		+ '\t}\n}\n';

	public static function run():Void {
		var types:Array<String> = Expose.ambient();
		var binds:Array<String> = Expose.statics();

		Sys.println('ambient (' + types.length + '): ' + types.join(', '));
		Sys.println('statics (' + binds.length + '): ' + binds.join(', '));
		Sys.println('Hidden exposed? ' + (types.indexOf('Hidden') >= 0));

		// One call fills the interpreter's globals and the compiler's lists from the same marks.
		Expose.apply();

		var env = new Environment();
		env.addModule(new Module(SCRIPT, 'Raid', ['s'], 'raid'));
		for (m in env.modules) m.init(env);
		for (m in env.modules) m.start(env);
		for (m in env.modules) m.startTypes(env);

		var cls:ScriptedClass = cast env.resolve('s.Raid');
		Sys.println('interpreted -> ' + Reflect.callMethod(null, cls.reflectGetField('run'), []));

		Armoury.shared.stock = 12;

		var report = Compiler.compile(env);
		Sys.println('compiled ' + report.compiled.length + ', skipped ' + report.skipped.length
			+ ', substituting ' + report.substituting);
		for (s in report.skipped) Sys.println('  ' + s.name + ': ' + s.reason);

		var after:ScriptedClass = cast env.resolve('s.Raid');
		Sys.println('compiled    -> ' + Reflect.callMethod(null, after.reflectGetField('run'), []));
	}

	static function main():Void {
		run();
		TestCase.exit();
	}
}
