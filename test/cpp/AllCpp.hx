import TestCase;

/**
 * Every hxcpp-only test, in one program.
 *
 * These need what only hxcpp has: cppia needs `-D scriptable`, and the DCE probe is asking a question
 * about a static target's build. Running them beside the portable suite would mean the other eight
 * targets could not build it at all.
 *
 * The manual tools are deliberately not here: the timings live in `test/bench/cpp` and `SwitchProbe`
 * is one too, `CppiaDump` and `CppiaOne` print bytecode for a human to read, and
 * `FieldFormProbe` walks a directory named on the command line. None of them asserts anything a
 * runner could check, and folding a 200,000-iteration timing into the suite would make it slow for
 * no signal.
 */
class AllCpp {
	/** Each test's name paired with the entry point that runs it. */
	static var tests:Array<{name:String, run:Void->Void}> = [
		{name: 'CppiaTest', run: CppiaTest.run},
		{name: 'CppiaWorldTest', run: CppiaWorldTest.run},
		{name: 'LoadFailureTest', run: LoadFailureTest.run},
		{name: 'StaticInitTest', run: StaticInitTest.run},
		{name: 'SweepTest', run: SweepTest.run},
		{name: 'CompilerTest', run: CompilerTest.run},
		{name: 'ExposeTest', run: ExposeTest.run},
		{name: 'PropTest', run: PropTest.run},
		{name: 'CatchNative', run: CatchNative.run},
		{name: 'DceProbe', run: DceProbe.run}
	];

	public static function main():Void {
		for (test in tests) {
			TestCase.section(test.name);

			try {
				test.run();
			} catch (e:Dynamic) {
				TestCase.bad(test.name, 'threw ' + Std.string(e));
			}
		}

		TestCase.exit();
	}
}
