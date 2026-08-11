import haxe.Json;
import sys.FileSystem;

/**
 * A project with nothing under it.
 *
 * The other three templates each sit on a library. This one sits on nothing: it is a class with a
 * static `main`, which the launcher calls once. When it returns, the shell comes back, so this shape
 * suits anything that computes an answer rather than drawing one, such as a parser, a solver, a
 * converter, or a scratch test of an idea.
 *
 * `log` and `trace` both reach the Console window, which the button in the top bar opens. `probe`
 * answers whether a type or a member is really reachable from a script, which is the question that
 * otherwise only gets answered by a null field at the worst moment.
 */
class Report {
	static function main():Void {
		log('plain project: no framework, just a static main()');
		log('');

		var facts:Array<String> = [
			'project folder   ' + projectPath,
			'screen           ' + screenWidth + ' x ' + screenHeight,
			'uptime           ' + Math.round(uptime() * 10) / 10 + 's'
		];

		for (fact in facts)
			log(fact);

		log('');
		log(sizes());
		log('');
		log(Probe.report('what a plain project can reach', [
			'haxe.Json',
			'haxe.io.Bytes',
			'sys.FileSystem',
			'sys.io.File',
			'StringTools::replace',
			'Math::round'
		]));

		log('');
		log('main() is done, so the shell comes back.');
	}

	/** @return A line per file in this project, so the folder is visibly readable from a script. */
	static function sizes():String {
		var out:Array<String> = ['this project on disk'];

		list(projectPath, '', out);

		return out.join('\n');
	}

	/**
	 * Walks a folder, appending a line per file.
	 *
	 * @param dir Where to look.
	 * @param indent What to put in front of each line.
	 * @param out Where to append.
	 */
	static function list(dir:String, indent:String, out:Array<String>):Void {
		if (!FileSystem.exists(dir) || !FileSystem.isDirectory(dir))
			return;

		for (name in FileSystem.readDirectory(dir)) {
			var full:String = dir + '/' + name;

			if (FileSystem.isDirectory(full)) {
				out.push('  ' + indent + name + '/');
				list(full, indent + '  ', out);
			} else {
				out.push('  ' + indent + name + '   ' + FileSystem.stat(full).size + ' bytes');
			}
		}
	}
}
