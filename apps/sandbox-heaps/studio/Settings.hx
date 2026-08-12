package studio;

import haxe.Json;
import sys.FileSystem;
import sys.io.File;

/**
 * What the shell remembers between runs: which keys it takes, and what it is allowed to put on screen.
 *
 * Every entry here exists because the shell was doing something to a running project without being
 * asked. That is the theme, and it is worth stating because it decides the defaults: **anything the
 * shell takes from a project is off unless somebody turns it on.** A prototyping app is not the
 * subject, the thing being prototyped is, and a key the shell claims is a key the project never sees.
 *
 * So `back` is bound and nothing else is. `run` is bound too but cannot compete, since it is only read
 * while nothing is running. Reload and the overlay toggle are real bindings with no default key, so they
 * are there for whoever wants them and cost nothing to whoever does not.
 *
 * Written beside the executable, next to `projects/`, for the same reason that folder is: a
 * double-clicked application does not start in its own directory.
 */
class Settings {
	/** Where the file lives, beside the executable. */
	static inline var FILE:String = 'sandbox.json';

	/** The key that returns to the shell. Bound, because with nothing bound there is no way back. */
	public static var back:Int = hxd.Key.F1;

	/** The key that runs the selection. Only read while nothing is running, so it competes with nothing. */
	public static var run:Int = hxd.Key.F5;

	/** The key that reloads the loaded project. Unbound by default. */
	public static var reload:Int = 0;

	/** The key that shows and hides the overlay. Unbound by default. */
	public static var overlayKey:Int = 0;

	/** Whether the overlay is shown while a project runs. Off, so a project owns its own screen. */
	public static var overlay:Bool = false;

	/** Nothing compiled: every script runs through the interpreter. */
	public static inline var INTERPRETED:String = 'interpreted';

	/** Compiled to HashLink bytecode, which the VM jits as it loads it. */
	public static inline var BYTECODE:String = 'bytecode';

	/**
	 * How a project's scripts are run.
	 *
	 * Two rather than the three the sandbox for lime offers, and the difference is the target's
	 * rather than a feature being missing. cppia is bytecode that hxcpp interprets unless its JIT is
	 * turned on, so there it is worth separating the two. HashLink jits whatever it loads and has
	 * nothing to switch, so bytecode here is already machine code and a third setting would be a
	 * control that did nothing.
	 *
	 * Worth being able to choose rather than always taking the faster, because these are not one
	 * thing running faster. They are two runtimes, and a difference between them is a bug in one of
	 * them. The differential suites exist for exactly that, and being able to drop a project into the
	 * interpreter without rebuilding is the same test with somebody's real code.
	 */
	public static var mode:String = BYTECODE;

	/**
	 * Frames per second the application runs at, or zero for the window's own rate.
	 *
	 * Applies to the sandbox as a whole, since there is one frame loop and the project shares it.
	 */
	public static var fps:Int = 0;

	/** Reads the file, keeping the defaults for anything it does not mention. */
	public static function load():Void {
		var path:String = Projects.beside(FILE);

		if (!FileSystem.exists(path))
			return;

		try {
			var saved:Dynamic = Json.parse(File.getContent(path));

			back = int(saved, 'back', back);
			run = int(saved, 'run', run);
			reload = int(saved, 'reload', reload);
			overlayKey = int(saved, 'overlayKey', overlayKey);
			overlay = bool(saved, 'overlay', overlay);
			fps = int(saved, 'fps', fps);

			var named:Dynamic = Reflect.field(saved, 'mode');
			if (named == INTERPRETED || named == BYTECODE)
				mode = named;
		} catch (e:haxe.Exception) {
		}
	}

	/** Writes the file. Failing is silent for the same reason reading is. */
	public static function save():Void {
		try {
			File.saveContent(Projects.beside(FILE), Json.stringify({
				back: back,
				run: run,
				reload: reload,
				overlayKey: overlayKey,
				overlay: overlay,
				mode: mode,
				fps: fps
			}, '\t'));
		} catch (e:haxe.Exception) {
		}
	}

	/**
	 * Puts what is set here into effect.
	 *
	 * Called after every change and after a project stops, because a project that changed the frame
	 * rate should not have that survive into the next one.
	 */
	public static function apply():Void {
		hxd.Timer.wantedFPS = fps > 0 ? fps : windowRate();
	}

	/**
	 * The window's own refresh rate, for `fps == 0`.
	 *
	 * Asked of the system rather than assumed to be 60, since "Window" meaning 60 on a 144 Hz display
	 * is the setting not doing what it says.
	 *
	 * @return The rate, or 60 when it cannot be asked.
	 */
	static function windowRate():Int {
		var rate:Float = 0;

		try {
			rate = hxd.System.getDefaultFrameRate();
		} catch (e:Dynamic) {
			rate = 0;
		}

		return rate > 0 ? Math.round(rate) : 60;
	}

	/**
	 * Whether a project's scripts should be compiled at all.
	 *
	 * @return Whether to run the runtime compiler on load.
	 */
	public static function compiling():Bool {
		return mode != INTERPRETED;
	}

	/**
	 * Whether choosing between the two modes means anything in this build.
	 *
	 * It does not when there is no compiler to choose, which is a real build rather than a broken
	 * one: an HL/C binary for an architecture HashLink cannot jit for links the extension in and
	 * still has no loader inside it. Offering a control that cannot change what happens is worse than
	 * showing why, so the sheet asks this and says the reason instead.
	 *
	 * @return Whether both modes are reachable.
	 */
	public static function selectable():Bool {
		return hxscript.compile.Compiler.available;
	}

	/** @return Why the run mode cannot be chosen, or null when it can. */
	public static function why():Null<String> {
		return hxscript.compile.Compiler.unavailable();
	}

	/**
	 * @param code The key code, or 0 for unbound.
	 * @return Its name, or `none`.
	 */
	public static function name(code:Int):String {
		if (code <= 0)
			return 'none';

		var named:String = hxd.Key.getKeyName(code);
		return named == null ? 'key $code' : named;
	}

	static function int(from:Dynamic, field:String, fallback:Int):Int {
		var value:Dynamic = Reflect.field(from, field);
		return Std.isOfType(value, Int) ? value : fallback;
	}

	static function bool(from:Dynamic, field:String, fallback:Bool):Bool {
		var value:Dynamic = Reflect.field(from, field);
		return Std.isOfType(value, Bool) ? value : fallback;
	}
}
