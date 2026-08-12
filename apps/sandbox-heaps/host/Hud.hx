package host;

#if heaps
import h2d.Object;
#end

/**
 * What a project calls to reach the strip above it.
 *
 * Named for what a script writes rather than for where it goes, because a script that has to know
 * about `studio.Overlay` to print a number is a script coupled to the app it happens to be running
 * in. Everything here is safe to call when the overlay is off and when nothing is running.
 */
@:scriptable
@:scriptAmbient
class Hud {
	/**
	 * Puts a named value on the strip, replacing whatever was there under that name.
	 *
	 * The cheap one, and meant to be called every frame: naming a value means its label is built
	 * once and only the text changes afterwards.
	 *
	 * @param name What to call it.
	 * @param value What it is now.
	 */
	public static function info(name:String, value:Dynamic):Void {
		#if heaps
		studio.Overlay.set(name, value);
		#end
	}

	/** Drops every named value. */
	public static function infoClear():Void {
		#if heaps
		studio.Overlay.clear();
		#end
	}

	/**
	 * @return Where to put a control of your own, for a project that has outgrown a readout.
	 *
	 * Everything added to it is dropped when the project stops.
	 */
	#if heaps
	public static function overlay():Object {
		return studio.Overlay.surface();
	}
	#end

	/** @return Whether anyone is looking, so the work of filling it can be skipped. */
	public static function overlayShown():Bool {
		#if heaps
		return studio.Overlay.shown();
		#else
		return false;
		#end
	}
}
