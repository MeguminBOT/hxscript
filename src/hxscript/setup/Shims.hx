package hxscript.setup;

import hxscript.Config;

/**
 * Step 4: registers real closures for members that have no runtime form.
 */
class Shims {
	/** What was registered, for the setup report. */
	public static var registered:Array<String> = [];

	/** Registers every shim the libraries in this build need. Safe to call more than once. */
	public static function register():Void {
		if (registered.length > 0)
			return;

		hxscript.stdlib.Shims.register();

		#if python
		hxscript.python.Shims.register();
		#end

		#if flixel
		hxscript.flixel.Shims.register();
		#end
	}

	/**
	 * Registers one shim and remembers it.
	 *
	 * @param key `<fully.qualified.Owner>.<method>`.
	 * @param shim Receives the receiver and the call arguments.
	 */
	public static function set(key:String, shim:(o:Dynamic, args:Array<Dynamic>) -> Dynamic):Void {
		Config.callShims.set(key, shim);
		registered.push(key);
	}
}
