import TestCase;

/**
 * Every portable test, in one program, for one target.
 *
 * The suite is run across nine targets. Building each test separately would be 15 compilations per
 * target and 135 across the matrix, most of the cost being the library itself recompiled every time.
 * Aggregating makes it one per target.
 *
 * It also gives the matrix a single exit code per target, which is what `run.sh` reads. Each test
 * remains runnable on its own; `main` here does what each test's own `main` does, once, at the end.
 */
class AllCommon {
	/** Each test's name paired with the entry point that runs it. */
	static var tests:Array<{name:String, run:Void->Void}> = [
		{name: 'AbstractTest', run: AbstractTest.run},
		{name: 'AccessTest', run: AccessTest.run},
		{name: 'ArgsTest', run: ArgsTest.run},
		{name: 'BitwiseTest', run: BitwiseTest.run},
		{name: 'ClassProbe', run: ClassProbe.run},
		{name: 'DiagnosticTest', run: DiagnosticTest.run},
		{name: 'FieldBindTest', run: FieldBindTest.run},
		{name: 'GapProbe', run: GapProbe.run},
		{name: 'StdProbe', run: StdProbe.run},
		{name: 'InterpStringTest', run: InterpStringTest.run},
		{name: 'LoopTest', run: LoopTest.run},
		{name: 'PrinterTest', run: PrinterTest.run},
		{name: 'RangeTest', run: RangeTest.run},
		{name: 'ReturnTest', run: ReturnTest.run},
		{name: 'ScriptedAbstractTest', run: ScriptedAbstractTest.run},
		{name: 'StructTest', run: StructTest.run},
		{name: 'SweepProbe', run: SweepProbe.run},
		{name: 'TypedTest', run: TypedTest.run},
		{name: 'UsingTest', run: UsingTest.run}
	];

	public static function main():Void {
		for (test in tests) {
			TestCase.section(test.name);

			// One test throwing must not take the other fourteen with it, or a single regression hides
			// the state of everything after it and the target reports one failure instead of its real
			// condition.
			try {
				test.run();
			} catch (e:Dynamic) {
				TestCase.bad(test.name, 'threw ' + Std.string(e));
			}
		}

		TestCase.exit();
	}
}
