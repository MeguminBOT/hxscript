import hxscript.Config;
import hxscript.Script;
import TestCase.ok;

/**
 * That a local holding null and named like a type still reads the type's field, interpreted, unless
 * `Config.strictNullAccess` asks for the raise.
 *
 * Before the flag existed, `var Math:Dynamic = null; Math.PI` looked the first name up as a type once
 * the local answered null, and read `Math.PI`. With the flag off that answer has to stay. Compiled
 * code reads the local and answers null, which is why this is not a corpus case.
 */
class NullShadowTest {
	/**
	 * Runs `Math.PI > 3` behind a null local named `Math`.
	 *
	 * @param strict The value `Config.strictNullAccess` takes for the run.
	 * @return The value stringified, or `threw: <error>`.
	 */
	static function eval(strict:Bool):String {
		var was:Bool = Config.strictNullAccess;
		Config.strictNullAccess = strict;

		var result:String;
		try {
			var s = new Script('function run() { var Math:Dynamic = null; return Math.PI > 3; }', 'NullShadowTest.hxs');
			s.onProgramError = function(e:haxe.Exception):Void {};
			s.start();
			result = Std.string(s.call('run', []));
		} catch (e:Dynamic) {
			result = 'threw: ' + Std.string(e);
		}

		Config.strictNullAccess = was;
		return result;
	}

	public static function run():Void {
		trace('-- a null local named like a type --');
		ok('flag off: the type answers, as before the flag', eval(false) == 'true');
		ok('flag on: the null raises', StringTools.startsWith(eval(true), 'threw: ') && eval(true).indexOf('PI') >= 0);
	}

	static function main():Void {
		run();
		TestCase.exit();
	}
}
