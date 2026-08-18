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

	/**
	 * Declarations the scanner must NOT report, because `abstract` is three keywords in Haxe 4.
	 *
	 * It is a type, a class modifier and a method modifier, and the pattern matches the word after it
	 * whichever one it was. flixel's `FlxBaseTilemap` has all three shapes and produced
	 * `FlxBaseTilemap.class`, `.public` and `.function`, handed on to `Compiler.addMetadata` as though
	 * they were types. Nothing failed, since metadata on a path nothing declares does nothing, so the
	 * only symptom was three junk entries in the count `-D hxscript_verbose` prints. The positive
	 * cases above cannot catch this: they only ask what the scanner finds, never what it invents.
	 */
	static var REJECT:Array<String> = [
		'abstract class Base<T> extends Other {}',
		'\tabstract public function width():Float;',
		'\tabstract  public function spaced():Float;',
		'\tabstract function orient(t:Null<T>):Null<T>;',
		'\tabstract private var held:Int;',
		'abstract interface Odd {}'
	];

	/**
	 * Paths as a preset may write them, each with the path the abstract is declared under.
	 *
	 * `Compiler.addMetadata` matches on the declared path, which is the package and the type, and a
	 * script imports a sub-type through its module as well. Handing it the import spelling matches
	 * nothing and says nothing, so the abstract gets no wrapper and no runtime form: its constants
	 * answer nothing and an import of it binds to null. That is what the scanner did to every abstract
	 * sharing a module with another type, which was two thirds of what it found, and the same door is
	 * open to anything written by hand in a preset's `abstracts`.
	 */
	static var PATHS:Array<{src:String, want:String}> = [
		{src: 'flixel.util.FlxAxes', want: 'flixel.util.FlxAxes'},
		{src: 'flixel.text.FlxText.FlxTextAlign', want: 'flixel.text.FlxTextAlign'},
		{src: 'flixel.util.typeLimit.NextState.InitialState', want: 'flixel.util.typeLimit.InitialState'},
		{src: 'Top', want: 'Top'},
		{src: 'pack.Top', want: 'pack.Top'},
		// A package is lowercase by Haxe's own rule, so nothing here is a module to drop.
		{src: 'h2d.col.Point', want: 'h2d.col.Point'},
		{src: 'openfl.display.BlendMode', want: 'openfl.display.BlendMode'}
	];

	public static function run():Void {
		var missed:Array<String> = [];

		for (p in PATHS) {
			var got:String = hxscript.setup.Abstracts.declared(p.src);
			if (got != p.want)
				missed.push('("' + p.src + '" gave "' + got + '", wanted "' + p.want + '")');
		}

		for (c in CASES) {
			if (hxscript.setup.Abstracts.declaredAbstracts(c.src).indexOf(c.want) < 0)
				missed.push(c.want);
		}

		for (src in REJECT) {
			var got:Array<String> = hxscript.setup.Abstracts.declaredAbstracts(src);
			if (got.length > 0)
				missed.push('(invented ' + got.join('/') + ' from "' + StringTools.trim(src) + '")');
		}

		/** A word that only looks like one, so the pattern cannot be loosened into matching prose. */
		if (hxscript.setup.Abstracts.declaredAbstracts('// an abstract Thing(Int) in a comment').length > 0)
			missed.push('(matched a comment)');

		if (missed.length > 0) {
			haxe.macro.Context.error('the abstract scanner missed: ' + missed.join(', '),
				haxe.macro.Context.currentPos());
		}
	}
}
#end
