import flixel.FlxGame;
import host.Api;
import studio.Projects;
import studio.Shell;

/**
 * The application entry.
 *
 * Two lines of substance. Work out where the user's projects live, then start the window on the shell.
 * Everything else, meaning putting six libraries within reach of a script, generating a bridge per class a
 * project may extend, giving their abstracts a runtime form and wiring the shims, happens because
 * `Project.xml` lists `hxscript` beside the libraries, and is worth noticing precisely because there is
 * nothing here about it.
 *
 * `--projects <dir>` points at a folder somewhere else, for someone who keeps their work outside the
 * application folder. `--run <name>` starts straight into a project rather than at the list, which
 * is what you want once you are iterating on one thing and the shell is a keystroke you press a
 * hundred times a day. The headless check is `console.hxml`, which builds the same host with no
 * window at all.
 */
class Main {
	/**
	 * The resolution a project is given, whatever the window is doing.
	 *
	 * Pinned rather than taken from the stage. Passing zero to `FlxGame` makes flixel adopt the
	 * stage's size, which with `allow-high-dpi` is the display's *physical* pixels, so the same
	 * project would see 1366 wide on one machine and 2049 on the same window at 150% scaling. A
	 * project reads `FlxG.width` to lay itself out, so that is a number that has to mean the same
	 * thing everywhere.
	 *
	 * `ViewportScaleMode` fits this into the band between the bars and never magnifies it, so a
	 * larger window gives a project room around itself rather than a stretched picture.
	 */
	public static inline var WIDTH:Int = 1366;

	/** The height a project is given. */
	public static inline var HEIGHT:Int = 768;

	static function main():Void {
		if (!Projects.open(argument('--projects')))
			Api.log('could not open a projects folder at ' + Projects.root);

		Shell.autoRun = argument('--run');

		openfl.Lib.current.addChild(new FlxGame(WIDTH, HEIGHT, Shell.new, 60, 60, true));
	}

	/**
	 * Reads a `--name value` command-line argument.
	 *
	 * @param name The flag, including its dashes.
	 * @return The value after it, or null when the flag is absent.
	 */
	static function argument(name:String):String {
		var args:Array<String> = Sys.args();

		for (i in 0...args.length)
			if (args[i] == name && i + 1 < args.length)
				return args[i + 1];

		return null;
	}
}
