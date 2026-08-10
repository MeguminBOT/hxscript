import hxscript.Environment;
import hxscript.Module;
import hxscript.error.Diagnostic;
import hxscript.error.Sink;

/**
 * What an error says, which is a separate question from whether one happened.
 *
 * A diagnostic exists to answer a question the raw error does not. The raw error reports the symptom with no
 * position and no cause: `origin:line` and a message, where the message names an identifier and the cause is
 * a build a hundred lines away. These check the three things that turn that into an answer: the position is
 * exact, the source line is quoted, and the hint names the cause rather than repeating the symptom.
 *
 * The assertions look for substrings rather than whole strings on purpose. The wording of a hint is
 * meant to be improved; what must not regress is that it mentions the thing to go and look at.
 */
class DiagnosticTest {
	public static function run():Void {
		var wasPrinting:Bool = Sink.printing;
		Sink.printing = false;

		position();
		unknownName();
		nearMiss();
		cannotCall();
		routing();

		Sink.printing = wasPrinting;
	}

	/** A parse error knows its line, its column, and what the line says. */
	static function position():Void {
		var d:Diagnostic = first('Broken.hx', 'package p;\nclass Broken {\n\tpublic static function go():Int {\n\t\tvar x = foo(;\n\t\treturn x;\n\t}\n}\n');

		if (d == null) {
			TestCase.bad('parse position', 'nothing was reported');
			return;
		}

		TestCase.eq('parse origin', d.origin, 'Broken.hx');
		TestCase.eq('parse line', d.line, 4);
		TestCase.ok('parse column is known', d.column > 0);
		TestCase.ok('the source line is quoted', d.excerpt != null && d.excerpt.indexOf('foo(') >= 0);

		var rendered:String = d.toString();
		TestCase.ok('the rendering carries a caret', rendered.indexOf('^') >= 0);
		TestCase.ok('the rendering names the file and line', rendered.indexOf('Broken.hx:4') >= 0);
	}

	/**
	 * A name nothing resolved says whether it is missing from the build or only from the scope.
	 *
	 * This is the one that matters most. `Unknown identifier: FlxG` is a message about a script and a
	 * problem in a build file, and the distinction between "never compiled in" and "not imported
	 * here" is the difference between two completely different fixes.
	 */
	static function unknownName():Void {
		var inBuild:Diagnostic = firstRun('InScope.hx',
			'package p;\nclass InScope {\n\tpublic static function go():Dynamic {\n\t\treturn StringMap;\n\t}\n}\n');

		if (inBuild == null) {
			TestCase.bad('unknown name, in the build', 'nothing was reported');
		} else {
			TestCase.ok('an unimported type is not called missing', inBuild.hint != null && inBuild.hint.indexOf('is in this build') >= 0);
			TestCase.ok('the import to write is quoted', inBuild.hint != null && inBuild.hint.indexOf('import haxe.ds.StringMap;') >= 0);
		}

		var absent:Diagnostic = firstRun('Absent.hx',
			'package p;\nclass Absent {\n\tpublic static function go():Dynamic {\n\t\treturn NoSuchTypeAnywhere;\n\t}\n}\n');

		if (absent == null) {
			TestCase.bad('unknown name, not in the build', 'nothing was reported');
		} else {
			TestCase.ok('a missing type blames the build', absent.hint != null && absent.hint.indexOf('force-compiled') >= 0);
		}
	}

	/**
	 * A misspelled member suggests the spelling that exists.
	 *
	 * The receiver is a scripted class rather than a standard-library one, and deliberately: a
	 * scripted instance always knows its own members, while a native class only does when the build
	 * kept a field table for it. On hxcpp `Type.getInstanceFields(StringBuf)` is empty however many
	 * methods `StringBuf` has, so a suggestion there is a property of the host's build rather than of
	 * this machinery, and `cannotCall` covers what happens instead.
	 */
	static function nearMiss():Void {
		var d:Diagnostic = firstRun('NearMiss.hx', 'package p;\n'
			+ 'class Target {\n'
			+ '\tpublic function new() {}\n'
			+ '\tpublic function greet():String { return "hi"; }\n'
			+ '}\n'
			+ 'class NearMiss {\n'
			+ '\tpublic static function go():Dynamic {\n'
			+ '\t\tvar t = new Target();\n'
			+ '\t\treturn t.greeet();\n'
			+ '\t}\n'
			+ '}\n', 'NearMiss');

		if (d == null) {
			TestCase.bad('near miss', 'nothing was reported');
			return;
		}

		TestCase.ok('the message names the receiver type', d.message.indexOf('Target') >= 0);
		TestCase.ok('the hint suggests the real name', d.hint != null && d.hint.indexOf('`greet`') >= 0);
	}

	/**
	 * A call that resolved to nothing on a receiver that cannot be enumerated explains what an inline
	 * member looks like from a script, rather than guessing that the member is absent.
	 */
	static function cannotCall():Void {
		var d:Diagnostic = firstRun('NoSuch.hx',
			'package p;\nclass NoSuch {\n\tpublic static function go():Dynamic {\n\t\tvar s = new StringBuf();\n\t\treturn s.definitelyNotAMethod();\n\t}\n}\n');

		if (d == null) {
			TestCase.bad('cannot call', 'nothing was reported');
			return;
		}

		TestCase.ok('the hint mentions callShims', d.hint != null && d.hint.indexOf('callShims') >= 0);
	}

	/** A listener sees everything, and taking one silences the default printer. */
	static function routing():Void {
		var seen:Array<Diagnostic> = [];
		var before:Int = Sink.onDiagnostic.length;

		Sink.listen(function(d:Diagnostic):Void seen.push(d));

		var env:Environment = new Environment();
		env.addModule(new Module('package p;\nclass Routed {\n\tpublic static function go():Int { return ;\n}\n', 'Routed', ['p'], 'Routed.hx'));

		TestCase.ok('a listener receives diagnostics', seen.length > 0);
		TestCase.ok('listening stops the default printer', !Sink.printing);

		Sink.onDiagnostic.splice(before, Sink.onDiagnostic.length - before);
	}

	/**
	 * Parses a module and returns the first diagnostic it produced.
	 *
	 * @param origin The origin to report against.
	 * @param source The module source.
	 * @return The diagnostic, or null when nothing was reported.
	 */
	static function first(origin:String, source:String):Diagnostic {
		var mark:Int = Sink.history.length;

		var env:Environment = new Environment();
		env.addModule(new Module(source, 'Case', ['p'], origin));

		return Sink.history.length > mark ? Sink.history[mark] : null;
	}

	/**
	 * Parses a module, runs its `go`, and returns the diagnostic the failure produced.
	 *
	 * The exception is caught here rather than left to the sink, because a host calling into a script
	 * directly is the common case and the diagnostic has to be reachable from the exception itself.
	 *
	 * @param origin The origin to report against.
	 * @param source The module source.
	 * @param entry Which class in the module to call, when it is not the first one declared.
	 * @return The diagnostic, or null when the call did not fail.
	 */
	static function firstRun(origin:String, source:String, ?entry:String):Diagnostic {
		var env:Environment = new Environment();
		var name:String = entry != null ? entry : source.split('class ')[1].split(' ')[0];

		env.addModule(new Module(source, 'Case', ['p'], origin));
		env.start();

		try {
			var cls:hxscript.types.ScriptedClass = cast env.resolve('p.$name');
			Reflect.callMethod(null, cls.reflectGetField('go'), []);
		} catch (e:hxscript.error.InterpException) {
			return e.toDiagnostic();
		} catch (e:haxe.Exception) {
			return null;
		}

		return null;
	}
}
