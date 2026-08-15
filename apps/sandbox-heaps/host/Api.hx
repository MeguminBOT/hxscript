package host;

/**
 * The handful of things every backend can answer, so a script does not have to know which one it is
 * running on.
 *
 * Marked rather than listed. `@:scriptAmbient` says scripts may name this type; `@:scriptStatic`
 * says they may reach a static by a bare name, so a script writes `log('hi')` and not
 * `host.Api.log('hi')`. `hxscript.setup.Boot` turns both marks into
 * `Config.globalVariables` for interpreted code *and* the runtime compiler's lists for compiled
 * code, from the same marks.
 *
 * Filling only one of those two is the trap the marks exist to avoid: a script that works right up
 * until the day it is compiled, or the reverse.
 */
@:scriptAmbient
class Api {
	/** Which backend is running: `console`, `openfl`, `flixel` or `heaps`. */
	@:scriptStatic('backend')
	public static var backend:String = 'console';

	/** The drawable width the backend gave us, in pixels (characters, on the console backend). */
	@:scriptStatic('screenWidth')
	public static var screenWidth:Int = 0;

	/** The drawable height the backend gave us. */
	@:scriptStatic('screenHeight')
	public static var screenHeight:Int = 0;

	/** The loaded project's folder, so a script can find the files it shipped beside its scripts. */
	@:scriptStatic('projectPath')
	public static var projectPath:String = '';

	/** The loaded project's folder name. */
	@:scriptStatic('project')
	public static var project:String = '';

	/** Set by the backend, so `quit()` means something on each of them. */
	public static var onQuit:Void->Void = null;

	/**
	 * Where `log` goes in addition to standard output.
	 *
	 * Standard output is not a place in a windowed build: a double-clicked application has no console
	 * attached on Windows, macOS or Linux, so a script calling `log` produced nothing anybody could
	 * see. The host sets this to somewhere on screen.
	 */
	public static var onLog:String->Void = null;

	/** When the sandbox booted, for `uptime`. */
	static var began:Float = haxe.Timer.stamp();

	/**
	 * Prints a line, through whatever the backend considers output.
	 *
	 * @param value Anything; stringified.
	 */
	@:scriptStatic('log')
	public static function log(value:Dynamic):Void {
		var line:String = Std.string(value);

		if (onLog != null)
			onLog(line);

		#if sys
		Sys.println(line);
		#else
		trace(line);
		#end
	}

	/** Ends the run, if the backend has something to end. */
	@:scriptStatic('quit')
	public static function quit():Void {
		if (onQuit != null)
			onQuit();
	}

	/**
	 * Seconds since the sandbox started.
	 *
	 * A function rather than the property it wants to be, and the reason is worth knowing before you
	 * design an API around these marks. `Expose` puts a **value** into `Config.globalVariables`,
	 * read once with `Reflect.field` at startup. A static `var` therefore exposes whatever it held at
	 * that moment and never changes again; a static property with no backing field exposes `null`,
	 * because there is no field of that name to read, only `get_uptime`.
	 *
	 * `screenWidth` and `screenHeight` get away with being vars because each backend assigns them
	 * before `Sandbox.boot`, and they do not change afterwards. Anything that does has to be a call.
	 *
	 * @return Seconds since the sandbox started.
	 */
	@:scriptStatic('uptime')
	public static function uptime():Float {
		return haxe.Timer.stamp() - began;
	}

	/**
	 * The 3D scene to build into.
	 *
	 * heaps keeps two scene graphs and a project may want either. A 2D project becomes an
	 * `h2d.Object` and is drawn by being one, and a 3D project can become an `h3d.scene.Object` the
	 * same way, since that base is bridged. Most do not: what a 3D project owns is a world of
	 * objects rather than one object, so it asks for the scene and puts things in it.
	 *
	 * Asking is what turns that scene on: a project that never calls this costs nothing.
	 *
	 * @return The scene's root, or null in a build with no 3D.
	 */
	@:scriptStatic('world')
	public static function world():Dynamic {
		return onWorld == null ? null : onWorld();
	}

	/** Given by the app, so this class needs no reference to the launcher. */
	public static var onWorld:Void->Dynamic = null;
}
