package studio;

/**
 * How a project's entry class gets run.
 *
 * Its own module rather than a second type inside `Launcher`, because the headless check reads it
 * too and `Launcher` cannot be compiled without heaps under it.
 */
enum EntryKind {
	/** An `h2d.Scene`: it becomes the scene, and heaps drives it. */
	KScene;

	/** An `h2d.Object`: added to the project's layer, and drawn by being in it. */
	KObject;

	/** A `host.Project`: the host drives it, frame by frame. */
	KProject;

	/** A class with a `static function main()`: called once, and owns whatever it does next. */
	KMain;
}
