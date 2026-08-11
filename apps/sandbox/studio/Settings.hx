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
 * So `back` is bound and nothing else is. `run` is bound too but cannot compete, since it is only read while
 * nothing is running. Reload and the overlay toggle are real bindings with no default key, so they are there
 * for whoever wants them and cost nothing to whoever does not.
 *
 * Written beside the executable, next to `projects/`, for the same reason that folder is: a
 * double-clicked application does not start in its own directory.
 */
class Settings {
	/** Where the file lives, beside the executable. */
	static inline var FILE:String = 'sandbox.json';

	/** The key that returns to the shell. Bound, because with nothing bound there is no way back. */
	public static var back:Int = 112;

	/** The key that runs the selection. Only read while nothing is running, so it competes with nothing. */
	public static var run:Int = 116;

	/** The key that reloads the loaded project. Unbound by default. */
	public static var reload:Int = 0;

	/** The key that shows and hides the overlay. Unbound by default. */
	public static var overlayKey:Int = 0;

	/**
	 * Whether flixel's debugger may open.
	 *
	 * Off, and this is the one that prompted the rest. flixel binds its debugger to `F2`, backtick and
	 * backslash, and does so in release builds as well, so a project that binds any of those finds the
	 * debugger overlay opening on top of itself, from a key it handled, in a build that is not a debug
	 * build, with nothing in its own code to explain it.
	 */
	public static var debugger:Bool = false;

	/** Whether the overlay is shown while a project runs. Off, for the same reason. */
	public static var overlay:Bool = false;

	/** Nothing compiled: every script runs through the interpreter. */
	public static inline var INTERPRETED:String = 'interpreted';

	/** Compiled to cppia bytecode, run by hxcpp's bytecode interpreter. */
	public static inline var CPPIA:String = 'cppia';

	/** Compiled to cppia and JIT-compiled to machine code on top. */
	public static inline var JIT:String = 'jit';

	/**
	 * How a project's scripts are run.
	 *
	 * Worth being able to choose rather than always taking the fastest, because the three are not the same
	 * thing running faster. They are three different runtimes, and a difference between them is a bug in one
	 * of them. The differential suites exist for exactly that, and being able to drop a project into the
	 * interpreter without rebuilding is the same test with somebody's real code.
	 *
	 * Worth knowing before turning the JIT on for something unusual: a fault inside it cannot be
	 * survived. `Compiler.retryWithoutJit` covers a loader that *refuses* a batch, because a refusal
	 * comes back as a value, but a fault while the JIT is generating code is a segmentation fault,
	 * which ends the process from underneath Haxe with nothing to catch and nothing written down.
	 * `--probe` exists for that: it compiles a project headlessly and names the batch before offering
	 * it, and `--nojit` compiles the same batch without the JIT. Bytecode is most of the speed.
	 */
	public static var mode:String = JIT;

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
			debugger = bool(saved, 'debugger', debugger);
			overlay = bool(saved, 'overlay', overlay);
			fps = int(saved, 'fps', fps);

			var named:Dynamic = Reflect.field(saved, 'mode');
			if (named == INTERPRETED || named == CPPIA || named == JIT)
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
				debugger: debugger,
				overlay: overlay,
				mode: mode,
				fps: fps
			}, null, '\t'));
		} catch (e:haxe.Exception) {}
	}

	/**
	 * Puts the debugger setting into effect.
	 *
	 * Called whenever a project starts as well as when the setting changes, because the front end it
	 * writes to is shared with whatever is running: a project is free to set `toggleKeys` itself, and
	 * a project that did should not have that survive into the next one.
	 */
	public static function apply():Void {
		#if FLX_KEYBOARD
		flixel.FlxG.debugger.toggleKeys = debugger ? [F2, GRAVEACCENT, BACKSLASH] : [];
		#end

		flixel.FlxG.log.styles.warning.openConsole = debugger;
		flixel.FlxG.log.styles.error.openConsole = debugger;

		if (!debugger)
			flixel.FlxG.debugger.visible = false;

		var rate:Int = fps > 0 ? fps : windowRate();
		flixel.FlxG.updateFramerate = rate;
		flixel.FlxG.drawFramerate = rate;

		#if hxscript_cppia
		hxscript.compile.Compiler.jit = (mode == JIT);
		#end
	}

	/**
	 * The window's own refresh rate, for `fps == 0`.
	 *
	 * Asked of lime rather than assumed to be 60, since "Window" meaning 60 on a 144 Hz display is
	 * the setting not doing what it says.
	 *
	 * @return The rate, or 60 when the window cannot be asked.
	 */
	static function windowRate():Int {
		var window = lime.app.Application.current == null ? null : lime.app.Application.current.window;
		var rate:Float = window == null ? 0 : window.displayMode.refreshRate;

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
	 * What changing the mode does not do by itself.
	 *
	 * Two of the three switch freely: compiling or not compiling is decided per load, and a world that
	 * was never offered to the compiler simply has nothing to substitute. The JIT is different, and
	 * says so rather than appearing to work. It is a process-wide switch in hxcpp thrown once before
	 * the first module loads, so turning it ON reaches only classes compiled from then on, and turning
	 * it OFF cannot reach the ones already jitted at all.
	 *
	 * @param was The mode before the change.
	 * @return What to tell the user, or null when the change is complete as it stands.
	 */
	public static function caveat(was:String):String {
		if (was == JIT && mode != JIT)
			return 'the JIT stays on for classes already compiled; restart for a clean run';

		if (mode == JIT && was != JIT)
			return 'the JIT applies to classes compiled from now on; restart to jit everything';

		return null;
	}

	/**
	 * Names a key code the way somebody reading it would.
	 *
	 * @param code The key code, or 0 for unbound.
	 * @return Its name, or `none`.
	 */
	public static function name(code:Int):String {
		if (code <= 0)
			return 'none';

		var named:String = flixel.input.keyboard.FlxKey.toStringMap.get(code);
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
