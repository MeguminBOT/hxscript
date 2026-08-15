#if macro
/**
 * Checks that the abstract scanner recognises every way Haxe lets an abstract be declared.
 *
 * Runs at macro time, from the suite's hxml, because what it tests is macro-only: the scanner reads
 * source text before typing, so it cannot be reached from a compiled test.
 *
 * It exists because the pattern used to allow metadata and `private` in front of `abstract` and
 * nothing else, so `enum abstract Foo(Int)` matched none of it. Every enum abstract in a scanned
 * package was skipped without a word: in flixel that was forty of them, more than the thirty-three
 * the scanner did find, and it included `FlxKey`. A script importing one got the module registered
 * with no type behind it and failed at run time with `Module FlxKey does not define type FlxKey`,
 * which reads like a missing library rather than a pattern that could not see the declaration.
 */
class AbstractScan {
	/** The declarations the scanner has to recognise, each with the name it must return. */
	static var CASES:Array<{src:String, want:String}> = [
		{src: 'abstract Plain(Int) {}', want: 'Plain'},
		{src: '@:forward abstract Meta(Held) to Held from Held {}', want: 'Meta'},
		{src: '@:enum\nabstract OldEnum(Int) {}', want: 'OldEnum'},
		{src: 'enum abstract NewEnum(Int) from Int to Int {}', want: 'NewEnum'},
		{src: 'private abstract Hidden(Int) {}', want: 'Hidden'},
		{src: 'private enum abstract HiddenEnum(Int) {}', want: 'HiddenEnum'},
		{src: 'extern abstract Ext(Int) {}', want: 'Ext'},
		{src: '@:build(X.y()) private enum abstract Both(Int) {}', want: 'Both'},
		{src: '\tenum abstract Indented(Int) {}', want: 'Indented'}
	];

	public static function run():Void {
		var missed:Array<String> = [];

		for (c in CASES) {
			if (hxscript.setup.Abstracts.declaredAbstracts(c.src).indexOf(c.want) < 0)
				missed.push(c.want);
		}

		/** A word that only looks like one, so the pattern cannot be loosened into matching prose. */
		if (hxscript.setup.Abstracts.declaredAbstracts('// an abstract Thing(Int) in a comment').length > 0)
			missed.push('(matched a comment)');

		if (missed.length > 0) {
			haxe.macro.Context.error('the abstract scanner missed: ' + missed.join(', '), haxe.macro.Context.currentPos());
		}
	}
}
#end
