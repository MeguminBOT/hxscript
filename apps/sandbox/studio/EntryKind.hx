package studio;

/**
 * How a project's entry class gets run.
 *
 * Its own module rather than a second type inside `Launcher`, because the headless check reads it
 * too and `Launcher` cannot be compiled without flixel, openfl and lime under it.
 */
enum EntryKind {
	/** A `flixel.FlxState`: flixel's own lifecycle drives it. */
	KState;

	/** An `openfl.display.Sprite`: the display list drives it, the host only adds it. */
	KSprite;

	/** A `host.Project`: the host drives it, frame by frame. */
	KProject;

	/** A class with a `static function main()`: called once, and owns whatever it does next. */
	KMain;
}
