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
	static function main():Void {
		if (!Projects.open(argument('--projects')))
			Api.log('could not open a projects folder at ' + Projects.root);

		Shell.autoRun = argument('--run');

		openfl.Lib.current.addChild(new FlxGame(0, 0, Shell.new, 60, 60, true));
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
