import host.App;
import host.Keys;
import host.Screen;
import hxscript.Config;
import hxscript.Environment;
import hxscript.Module;
import hxscript.types.ScriptedClass;
import hxscript.types.TypeCollection;
import sys.FileSystem;
import sys.io.File;

using StringTools;

/**
 * A coding environment built on the library: write as many scripts as you like under `scripts/`,
 * then list, test, run or watch them without ever rebuilding this program.
 *
 *     haxe -cp src -cp examples/workbench --macro include('bridges') --run Workbench <command>
 *
 * `--run` rather than `-main ... --interp`: only `--run` passes arguments through to the program.
 *
 * | command | what it does |
 * | --- | --- |
 * | `list` | every class the scripts declare, marked with what the workbench can do with it |
 * | `test` | runs every `static function test()` found and reports pass/fail |
 * | `run <Name>` | plays a scripted `App` |
 * | `watch <Name>` | plays it again from the top whenever any script changes |
 *
 * The host owns no game logic at all. It owns a screen, a keyboard, a clock and this shell; the
 * program being written lives entirely in `scripts/`.
 */
class Workbench {
	/** Where the scripts live. Every `.hx` under here, at any depth, is loaded. */
	static inline var ROOT:String = 'examples/workbench/scripts';

	/** Frames per second the run loop aims for. */
	static inline var FPS:Float = 30;

	/** The world every script and type lives in, rebuilt on each load. */
	static var world:Environment;

	static function main():Void {
		var args:Array<String> = Sys.args();
		var command:String = args.length > 0 ? args[0] : 'list';
		var target:String = args.length > 1 ? args[1] : null;

		switch (command) {
			case 'list':
				if (load())
					list();

			case 'test':
				if (load())
					Sys.exit(test() ? 0 : 1);

			case 'run':
				if (target == null)
					Sys.println('run needs a name. Try `list` first');
				else if (load())
					play(target);

			case 'watch':
				if (target == null)
					Sys.println('watch needs a name. Try `list` first');
				else
					watch(target);

			default:
				Sys.println('commands: list | test | run <Name> | watch <Name>');
		}
	}

	/**
	 * Reads every script under `ROOT` into a fresh world.
	 *
	 * A file's path under `ROOT` becomes its package, so `scripts/blocks/Board.hx` is `blocks.Board` and can
	 * be imported as such, which is the same arrangement a Haxe classpath gives you.
	 *
	 * @return Whether the world started with something in it.
	 */
	static function load():Bool {
		if (!FileSystem.exists(ROOT)) {
			Sys.println('no scripts at $ROOT (run from the repository root)');
			return false;
		}

		// Let scripts name the host surface without importing it.
		for (path in ['host.App', 'host.Screen', 'host.Keys'])
			if (TypeCollection.main.fromPath(path) != null)
				Config.globalImports.set(path, INormal);

		// A fresh world per load: reloading means throwing the old one away, not patching it.
		world = new Environment();

		var files:Array<String> = [];
		walk(ROOT, files);

		for (file in files) {
			var rel:String = file.substr(ROOT.length + 1);
			var parts:Array<String> = rel.split('/');
			var name:String = parts.pop().substr(0, -3);

			var module = new Module(File.getContent(file), name, parts, file);
			module.onParsingError = function(e:haxe.Exception):Void Sys.println('parse error in $rel: ' + e.message);
			module.onProgramError = function(e:haxe.Exception):Void Sys.println('error in $rel: ' + e.details());
			world.addModule(module);
		}

		world.start();

		if (files.length == 0)
			Sys.println('no .hx files under $ROOT');

		return files.length > 0;
	}

	/**
	 * Collects every `.hx` under a directory, recursively.
	 *
	 * @param dir The directory to read.
	 * @param out Where to append the paths.
	 */
	static function walk(dir:String, out:Array<String>):Void {
		for (entry in FileSystem.readDirectory(dir)) {
			var full:String = '$dir/$entry';

			if (FileSystem.isDirectory(full))
				walk(full, out);
			else if (entry.endsWith('.hx'))
				out.push(full);
		}
	}

	/** @return Every scripted class in the world, sorted by name. */
	static function classes():Array<ScriptedClass> {
		var found:Map<String, ScriptedClass> = [];

		for (module in world.modules)
			for (name => type in module.types)
				if (type is ScriptedClass)
					found.set(name, cast type);

		var names:Array<String> = [for (n in found.keys()) n];
		names.sort(Reflect.compare);
		return [for (n in names) found.get(n)];
	}

	/**
	 * Whether a scripted class descends from a native one.
	 *
	 * @param cls The scripted class.
	 * @param base The native base to look for.
	 * @return Whether `base` is somewhere up the chain.
	 */
	static function descendsFrom(cls:ScriptedClass, base:Class<Dynamic>):Bool {
		var native:Dynamic = cls.instanceClass;

		while (native != null) {
			if (native == base)
				return true;
			native = Type.getSuperClass(native);
		}

		return false;
	}

	/** Prints what the scripts declare, and what can be done with each. */
	static function list():Void {
		Sys.println('scripts in $ROOT\n');

		for (cls in classes()) {
			var tag:String = '        ';
			var note:String = '';

			if (descendsFrom(cls, App)) {
				tag = '  [run] ';
				var made:Dynamic = safeNew(cls);
				if (made != null) {
					var app:App = made;
					note = '  ${app.title}  ${app.width}x${app.height}';
				}
			} else if (Reflect.isFunction(cls.reflectGetField('test'))) {
				tag = ' [test] ';
			}

			Sys.println(tag + cls.name + note);
		}

		Sys.println('\ncommands: list | test | run <Name> | watch <Name>');
		Sys.println('  haxe -cp src -cp examples/workbench --macro include(\'bridges\') --run Workbench run BlockDrop');
	}

	/**
	 * Runs every scripted `static function test()` and reports.
	 *
	 * A test returns either a `Bool` or a string; anything other than `true` or an empty string is
	 * treated as a failure and printed, so a script can explain itself.
	 *
	 * @return Whether every test passed.
	 */
	static function test():Bool {
		var run:Int = 0;
		var failed:Int = 0;

		for (cls in classes()) {
			var fn:Dynamic = cls.reflectGetField('test');
			if (!Reflect.isFunction(fn))
				continue;

			run++;
			var result:Dynamic = null;

			try {
				result = Reflect.callMethod(null, fn, []);
			} catch (e:haxe.Exception) {
				failed++;
				Sys.println('FAIL ${cls.name}\n     threw: ' + e.details());
				continue;
			}

			var ok:Bool = (result == true) || (result is String && cast(result, String).length == 0);
			if (ok) {
				Sys.println('ok   ${cls.name}');
			} else {
				failed++;
				Sys.println('FAIL ${cls.name}  ' + Std.string(result));
			}
		}

		Sys.println('\n$run test(s), $failed failed');
		return failed == 0;
	}

	/**
	 * Instantiates a scripted class, reporting rather than throwing.
	 *
	 * @param cls The class to build.
	 * @return The instance, or null.
	 */
	static function safeNew(cls:ScriptedClass):Dynamic {
		try {
			return cls.typeCreateInstance([]);
		} catch (e:haxe.Exception) {
			Sys.println('could not construct ${cls.name}: ' + e.message);
			return null;
		}
	}

	/**
	 * Runs one scripted `App` to completion.
	 *
	 * @param name The class to run.
	 */
	static function play(name:String):Void {
		var cls:ScriptedClass = null;
		for (c in classes())
			if (c.name == name)
				cls = c;

		if (cls == null) {
			Sys.println('no script declares `$name`. Try `list`');
			return;
		}

		if (!descendsFrom(cls, App)) {
			Sys.println('$name is not an App, so there is nothing to run');
			return;
		}

		var made:Dynamic = safeNew(cls);
		if (made == null)
			return;

		var app:App = made;
		var screen = new Screen(app.width, app.height);

		Screen.reset();
		app.start(screen);

		var frame:Float = 1 / FPS;
		var last:Float = Sys.time();

		while (!app.done) {
			// One blocking read per frame. A terminal has no non-blocking key poll that is portable,
			// and a game that steps on input is the honest shape for a console prototype.
			var k:Int = Keys.read();
			if (k == Keys.ESCAPE)
				break;

			app.key(k);

			var now:Float = Sys.time();
			app.step(now - last);
			last = now;

			screen.clear();
			app.draw(screen);
			screen.present();
		}

		app.stop();
		Sys.println('');
	}

	/**
	 * Runs a program, and runs it again from the top whenever any script changes.
	 *
	 * @param name The class to run.
	 */
	static function watch(name:String):Void {
		var last:Float = -1;

		while (true) {
			var at:Float = newest();

			if (at != last) {
				last = at;
				Screen.reset();
				Sys.println('--- reloaded ${Date.now().toString()} ---');

				if (load())
					play(name);

				Sys.println('\nwatching: edit a script to run again, ctrl-c to stop');
			}

			Sys.sleep(0.25);
		}
	}

	/** @return The most recent modification time across every script. */
	static function newest():Float {
		if (!FileSystem.exists(ROOT))
			return -1;

		var files:Array<String> = [];
		walk(ROOT, files);

		var at:Float = 0;
		for (f in files) {
			var t:Float = FileSystem.stat(f).mtime.getTime();
			if (t > at)
				at = t;
		}

		return at;
	}
}
