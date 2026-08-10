package studio;

/**
 * One project on disk, as the shell knows it.
 *
 * Everything except `entry` is derived from the folder rather than declared, so a project that has
 * no `project.json` at all still works: drop a folder with a `scripts/` in it and it appears in the
 * list. The file exists to override what the folder implies, not to be required before anything
 * happens.
 *
 * ```json
 * {
 *   "title": "Bouncing things",
 *   "kind": "flixel",
 *   "entry": "Playground",
 *   "description": "what this is, one line, shown in the detail pane"
 * }
 * ```
 */
@:structInit
class ProjectInfo {
	/** The folder name, which is the identity: unique, and what `--run <name>` takes. */
	public var name:String;

	/** The folder's full path. */
	public var path:String;

	/** What to call it. Defaults to the folder name. */
	public var title:String;

	/**
	 * What the project is built on: `flixel`, `openfl`, `lime`, or `unknown`.
	 *
	 * Only ever a label. The launcher decides what to run by what the scripts actually declare, not
	 * by this, because a project that says `flixel` and declares an `openfl.display.Sprite` should
	 * run rather than be refused on the strength of a string in a file.
	 */
	public var kind:String;

	/** One line about the project, for the detail pane. */
	public var description:String;

	/** The class to run, when the project names one. Null means "work it out". */
	public var entry:Null<String>;

	/** Absolute paths of every `.hx` under `scripts/`, in load order. */
	public var scripts:Array<String>;

	/** Why the project cannot be loaded, when it cannot. Null when it is fine. */
	public var problem:Null<String>;

	/** @return The name, with the title after it when they differ. */
	public function toString():String {
		return title == name ? name : '$name  ($title)';
	}
}
