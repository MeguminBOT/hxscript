package studio;

import haxe.Json;
import sys.FileSystem;
import sys.io.File;

#if openfl
#end

using StringTools;

/**
 * Where a user's projects live, and how they get there.
 *
 * The folder is beside the executable rather than in the working directory, and that is not a
 * preference: a double-clicked application does not start in its own folder on any of the three
 * platforms, so anything resolved from the working directory is found when the app is launched from
 * a terminal and missing when it is launched the way users actually launch it.
 *
 * ```
 * <beside the executable>/projects/
 *   my-thing/
 *     project.json     optional; overrides what the folder implies
 *     scripts/         .hx files, path under scripts/ becomes the package
 *     assets/          optional, reachable from the project by path
 * ```
 *
 * **Two lists, kept apart.** The examples this build ships are read where they lie, inside the
 * application folder, and the projects folder holds only what its owner put there. It used to be one
 * list: the examples were copied in on a first run, and from then on nothing could tell an example
 * from somebody's work, so a new build either wrote over their edits or left a stale example in
 * their list forever. An example is now plainly the application's, and copying one into the projects
 * folder is a deliberate act with a button on it.
 *
 * So the projects folder starts empty, which is a worse first screen than three projects and a
 * better arrangement than the one that produced them. The examples box is never empty, and that is
 * what the first screen shows.
 */
class Projects {
	/** The folder projects are read from and written to. */
	public static var root(default, null):String = null;

	/** Where the shipped templates live inside the asset bundle. */
	static inline var TEMPLATES:String = 'assets/templates/';

	/** The file a project may carry to override what its folder implies. */
	static inline var MANIFEST:String = 'project.json';

	/**
	 * Works out the projects folder and makes sure it exists and has something in it.
	 *
	 * @param override_ A path from `--projects`, for somebody keeping their work elsewhere.
	 * @return Whether the folder is usable.
	 */
	public static function open(?override_:String):Bool {
		root = override_ != null ? override_ : beside('projects');

		try {
			if (!FileSystem.exists(root))
				mkdirs(root);
		} catch (e:haxe.Exception) {
			return false;
		}

		return FileSystem.exists(root) && FileSystem.isDirectory(root);
	}

	/**
	 * The examples this build ships, read where they lie.
	 *
	 * **They are not copied into the projects folder any more, and the reason is that they were.**
	 * Seeding put the shipped examples and the user's own work in one list with nothing telling them
	 * apart, so the next build either wrote over somebody's edits or left an old example sitting
	 * there forever. Read in place, an example is plainly the application's and the projects folder
	 * is plainly the user's.
	 *
	 * @return The examples, in name order, empty when the build has no template folder beside it.
	 */
	public static function examples():Array<ProjectInfo> {
		#if openfl
		/** Embedded assets have no directory to read in place, so there is nothing to list here. */
		return [];
		#else
		var dir:String = templateDir();

		if (dir == null)
			return [];

		while (dir.length > 1 && (dir.charAt(dir.length - 1) == '/' || dir.charAt(dir.length - 1) == '\\'))
			dir = dir.substr(0, dir.length - 1);

		var found:Array<ProjectInfo> = [];

		for (name in templates()) {
			var path:String = dir + '/' + name;

			if (!FileSystem.exists(path) || !FileSystem.isDirectory(path))
				continue;

			var info:ProjectInfo = read(name, path);
			info.example = true;
			found.push(info);
		}

		return found;
		#end
	}

	/**
	 * Copies an example into the projects folder, so it can be edited and kept.
	 *
	 * @param from The example.
	 * @param name What to call the copy.
	 * @return The new project, or null when the name is taken or nothing could be written.
	 */
	public static function duplicate(from:ProjectInfo, name:String):ProjectInfo {
		var path:String = '$root/$name';

		if (name.length == 0 || FileSystem.exists(path))
			return null;

		return copyTemplate(from.name, path) ? read(name, path) : null;
	}

	/**
	 * @param name A project, example or conformance-fixture name.
	 * @return The one that answers to it, the user's own first, or null when nothing does.
	 */
	public static function find(name:String):ProjectInfo {
		for (candidate in all())
			if (candidate.name == name)
				return candidate;

		for (candidate in examples())
			if (candidate.name == name)
				return candidate;

		for (candidate in fixtures())
			if (candidate.name == name)
				return candidate;

		return null;
	}

	/**
	 * The conformance projects, when this build carries them.
	 *
	 * **Found but never listed**, which is the whole point of them being separate. `conform` has no
	 * window to draw in and `heaps3d` and `widgets` carry a `SelfTest` naming cases for `--conform`
	 * to run: they are how the app is tested, not things to show somebody who opened it. They shipped
	 * as examples once and put three test harnesses in every build's list.
	 *
	 * `./build.sh --with-tests` copies them in; an ordinary build has none and this answers empty.
	 *
	 * @return The fixtures, in name order, empty when the build was made without them.
	 */
	public static function fixtures():Array<ProjectInfo> {
		var dir:String = beside('assets/conformance');

		if (!FileSystem.exists(dir) || !FileSystem.isDirectory(dir))
			return [];

		var found:Array<ProjectInfo> = [];

		for (name in FileSystem.readDirectory(dir)) {
			var path:String = dir + '/' + name;

			if (FileSystem.exists(path + '/scripts'))
				found.push(read(name, path));
		}

		found.sort(function(a:ProjectInfo, b:ProjectInfo):Int return a.name < b.name ? -1 : (a.name > b.name ? 1 : 0));
		return found;
	}

	/**
	 * A path beside the running executable.
	 *
	 * `Sys.programPath` is the executable's own file, so its directory is the application folder
	 * whatever the working directory happens to be. On macOS that is inside the `.app` bundle, which
	 * is the right place for a portable tool: the projects travel with the application.
	 *
	 * @param name What to put beside it.
	 * @return The full path.
	 */
	public static function beside(name:String):String {
		var exe:String = Sys.programPath();
		var at:Int = Std.int(Math.max(exe.lastIndexOf('/'), exe.lastIndexOf('\\')));

		return at < 0 ? name : exe.substr(0, at + 1) + name;
	}

	/**
	 * Every project in the folder, in name order.
	 *
	 * A directory holding a `scripts/` folder is a project. Nothing else is required, so a folder
	 * copied in from somewhere else appears without ceremony.
	 *
	 * @return The projects, empty when there are none.
	 */
	public static function all():Array<ProjectInfo> {
		var found:Array<ProjectInfo> = [];

		if (root == null || !FileSystem.exists(root))
			return found;

		var names:Array<String> = FileSystem.readDirectory(root);
		names.sort(function(a:String, b:String):Int return a < b ? -1 : (a > b ? 1 : 0));

		for (name in names) {
			var path:String = '$root/$name';

			if (!FileSystem.isDirectory(path) || !FileSystem.exists('$path/scripts'))
				continue;

			found.push(read(name, path));
		}

		return found;
	}

	/**
	 * Reads one project folder.
	 *
	 * A malformed `project.json` is recorded on the project rather than thrown, because a project that
	 * cannot be read still has to appear in the list. Being told why the one you are looking for is missing
	 * is the whole point.
	 *
	 * @param name The folder name.
	 * @param path Its full path.
	 * @return The project.
	 */
	public static function read(name:String, path:String):ProjectInfo {
		var title:String = name;
		var kind:String = 'unknown';
		var description:String = '';
		var entry:String = null;
		var problem:String = null;

		var manifest:String = '$path/$MANIFEST';

		if (FileSystem.exists(manifest)) {
			try {
				var json:Dynamic = Json.parse(File.getContent(manifest));

				if (json.title != null)
					title = json.title;
				if (json.kind != null)
					kind = json.kind;
				if (json.description != null)
					description = json.description;
				if (json.entry != null)
					entry = json.entry;
			} catch (e:haxe.Exception) {
				problem = '$MANIFEST could not be read: ' + e.message;
			}
		}

		var scripts:Array<String> = [];
		Projects.scripts(path, scripts);

		if (scripts.length == 0 && problem == null)
			problem = 'no .hx files under scripts/';

		return {
			name: name,
			path: path,
			title: title,
			kind: kind,
			description: description,
			entry: entry,
			scripts: scripts,
			problem: problem
		};
	}

	/**
	 * Creates a project from one of the shipped templates.
	 *
	 * @param name The folder to create.
	 * @param kind Which template: `flixel`, `openfl` or `lime`.
	 * @return The created project, or null when the name is taken or the template is missing.
	 */
	public static function create(name:String, kind:String):ProjectInfo {
		var path:String = '$root/$name';

		if (name.length == 0 || FileSystem.exists(path))
			return null;

		/**
		 * A project with nothing in it, for a build carrying no examples to copy. A folder with a
		 * `scripts/` in it is the whole of what makes a project, so this is a real one; it just has
		 * nothing to run yet, which is a better answer than refusing to make one.
		 */
		if (kind == EMPTY) {
			try {
				mkdirs(path + '/scripts');
			} catch (e:haxe.Exception) {
				return null;
			}

			return read(name, path);
		}

		if (!copyTemplate(kind, path))
			return null;

		return read(name, path);
	}

	/** The template name meaning "no template", offered when the build ships none. */
	public static inline var EMPTY:String = 'empty';

	/** Names of the templates this build ships. */
	public static function templates():Array<String> {
		var found:Array<String> = [];

		for (id in templateIds()) {
			var rest:String = id.substr(TEMPLATES.length);
			var at:Int = rest.indexOf('/');

			if (at <= 0)
				continue;

			var name:String = rest.substr(0, at);

			if (found.indexOf(name) < 0)
				found.push(name);
		}

		found.sort(function(a:String, b:String):Int return a < b ? -1 : (a > b ? 1 : 0));
		return found;
	}

	/**
	 * Writes one template out to a folder.
	 *
	 * @param kind The template name.
	 * @param into Where to write it.
	 * @return Whether anything was written.
	 */
	static function copyTemplate(kind:String, into:String):Bool {
		var prefix:String = TEMPLATES + kind + '/';
		var written:Int = 0;

		for (id in templateIds()) {
			if (!id.startsWith(prefix))
				continue;

			var text:String = templateText(id);

			if (text == null)
				continue;

			var target:String = into + '/' + id.substr(prefix.length);
			var at:Int = target.lastIndexOf('/');

			if (at > 0)
				mkdirs(target.substr(0, at));

			try {
				File.saveContent(target, text);
				written++;
			} catch (e:haxe.Exception) {}
		}

		return written > 0;
	}

	/**
	 * Every template file this build can read, by asset id.
	 *
	 * The templates are text **assets** in the application build, because they have to survive being inside
	 * a packaged application. On macOS that is a bundle, with no source tree next to the binary to copy
	 * from. The headless check has no asset bundle, so it falls back to the source tree, which is the only
	 * place templates can be in that build and the only place it ever runs.
	 *
	 * @return Ids under `assets/templates/`, in whatever order the source gives them.
	 */
	static function templateIds():Array<String> {
		#if openfl
		return [for (id in Assets.list()) if (id.startsWith(TEMPLATES)) id];
		#else
		var dir:String = templateDir();

		if (dir == null)
			return [];

		var files:Array<String> = [];
		collect(dir, TEMPLATES, files);
		return files;
		#end
	}

	/**
	 * Reads one template file.
	 *
	 * @param id The asset id, which doubles as the path under the template directory.
	 * @return Its contents, or null when it cannot be read.
	 */
	static function templateText(id:String):String {
		try {
			#if openfl
			return Assets.getText(id);
			#else
			var dir:String = templateDir();
			return dir == null ? null : File.getContent(dir + '/' + id.substr(TEMPLATES.length));
			#end
		} catch (e:haxe.Exception) {
			return null;
		}
	}

	#if !openfl
	/** @return The template directory in the source tree, or null when there is not one. */
	static function templateDir():String {
		for (guess in [TEMPLATES, beside(TEMPLATES)])
			if (FileSystem.exists(guess) && FileSystem.isDirectory(guess))
				return guess;

		return null;
	}

	/**
	 * Lists every file under a directory as `prefix`-relative ids.
	 *
	 * @param dir Where to look.
	 * @param prefix What to put in front of each result.
	 * @param out Where to append.
	 */
	static function collect(dir:String, prefix:String, out:Array<String>):Void {
		for (name in FileSystem.readDirectory(dir)) {
			var full:String = '$dir/$name';

			if (FileSystem.isDirectory(full))
				collect(full, '$prefix$name/', out);
			else
				out.push(prefix + name);
		}
	}
	#end

	/**
	 * Every `.hx` a project would load, in load order.
	 *
	 * Public because the file watcher asks the same question several times a second and has no use
	 * for the rest of what reading a project produces.
	 *
	 * @param path The project folder.
	 * @param out Where to append.
	 */
	public static function scripts(path:String, out:Array<String>):Void {
		walk('$path/scripts', out);
	}

	/**
	 * Collects every `.hx` under a directory, deepest paths last.
	 *
	 * @param dir Where to look.
	 * @param out Where to append.
	 */
	static function walk(dir:String, out:Array<String>):Void {
		if (!FileSystem.exists(dir) || !FileSystem.isDirectory(dir))
			return;

		var names:Array<String> = FileSystem.readDirectory(dir);
		names.sort(function(a:String, b:String):Int return a < b ? -1 : (a > b ? 1 : 0));

		for (name in names) {
			var full:String = '$dir/$name';

			if (FileSystem.isDirectory(full))
				walk(full, out);
			else if (name.endsWith('.hx'))
				out.push(full);
		}
	}

	/**
	 * Creates a directory and every parent it needs.
	 *
	 * @param path The directory to create.
	 */
	public static function mkdirs(path:String):Void {
		var parts:Array<String> = path.replace('\\', '/').split('/');
		var built:String = '';

		for (part in parts) {
			built = built.length == 0 ? part : '$built/$part';

			if (built.length == 0 || built.endsWith(':'))
				continue;

			if (!FileSystem.exists(built))
				FileSystem.createDirectory(built);
		}
	}
}
