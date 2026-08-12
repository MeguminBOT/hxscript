package host;

#if heaps
import h2d.Object;
#end

/**
 * The base a project extends when it wants to own its own loop.
 *
 * Three ways of writing a project run in this app, and this is the one for the level below a scene
 * graph, where a script reaches heaps directly and draws for itself. The other two need nothing from
 * here: a project extending `h2d.Scene` becomes the scene, and one extending `h2d.Object` is added
 * to it.
 *
 * The host owns the `hxd.App`, because a script cannot subclass one: it would have had to exist
 * before the process did. So the host hands the same lifecycle back, calling `start` once, `update`
 * per frame, `stop` on the way out, and the input callbacks in between. Nothing is lost by the
 * arrangement, because `h2d`, `h3d`, `hxd` and `hxd.Key` are all reachable by name from inside these
 * methods.
 *
 * Deliberately small. A bridge generates one override per inherited method, so every method here is
 * paid for in binary size by every project whether it uses it or not, and anything declared here is
 * something a project cannot change without rebuilding the app.
 */
@:scriptable
@:scriptAmbient
class Project {
	/** Shown in the shell's project list. Set it in `new`. */
	public var title:String = 'untitled';

	/**
	 * What to draw into, given by the host before `start`.
	 *
	 * Owned by the app, not by the project: the shell adds it, sizes it, and empties it when the
	 * project stops, so a project that forgets to clean up after itself cannot leak into the next
	 * one.
	 *
	 * Gated, so this class still compiles in the headless check, which has no heaps under it. A base
	 * that only compiles in one of the two builds is a base the other build cannot bridge, and then
	 * the check cannot answer the one question it exists to answer.
	 */
	#if heaps
	public var layer:Object = null;
	#end

	/** Set true to end the run and return to the shell. */
	public var done:Bool = false;

	public function new() {}

	/** Called once, after `layer` is set and before the first `update`. */
	public function start():Void {}

	/**
	 * Advances the project by one frame.
	 *
	 * @param elapsed Seconds since the previous update.
	 */
	public function update(elapsed:Float):Void {}

	/** Called once after the run ends, however it ended. `layer` is emptied afterwards. */
	public function stop():Void {}

	/**
	 * A key went down.
	 *
	 * @param code The `hxd.Key` value, which a script can compare against `Key.SPACE` and friends.
	 */
	public function onKeyDown(code:Int):Void {}

	/**
	 * A key came up.
	 *
	 * @param code The `hxd.Key` value.
	 */
	public function onKeyUp(code:Int):Void {}

	/**
	 * The pointer moved.
	 *
	 * @param x Where, in the project's own canvas.
	 * @param y Where, in the project's own canvas.
	 */
	public function onMouseMove(x:Float, y:Float):Void {}

	/**
	 * The pointer went down.
	 *
	 * @param x Where, in the project's own canvas.
	 * @param y Where, in the project's own canvas.
	 */
	public function onMouseDown(x:Float, y:Float):Void {}
}
