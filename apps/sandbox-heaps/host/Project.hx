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

	/**
	 * A mouse button went down or came up.
	 *
	 * Beside `onMouseDown` rather than replacing it, because that one is part of what projects are
	 * already written against and its shape says nothing about which button or about letting go.
	 * Anything that holds a button needs both edges and needs to know which one, and a shooter needs
	 * exactly that twice: the left held down is automatic fire and the right held down is aiming.
	 *
	 * @param button Which one: 0 is left, 1 is right, 2 is middle.
	 * @param down True when it went down, false when it came up.
	 * @param x Where, in the project's own canvas.
	 * @param y Where, in the project's own canvas.
	 */
	public function onMouseButton(button:Int, down:Bool, x:Float, y:Float):Void {}

	/**
	 * The pointer moved, in a project that asked for it to be captured.
	 *
	 * **How far it moved rather than where it is**, which is the only form a first person camera can
	 * use. While captured the pointer is hidden and held inside the window, so it has no position to
	 * report and `onMouseMove` never fires; let go of it and the reverse is true.
	 *
	 * Ask with `captureMouse(true)`. The host lets go on its own when the project stops, so a project
	 * that ends without tidying up cannot leave the cursor trapped.
	 *
	 * @param dx How far across, in window pixels.
	 * @param dy How far down, in window pixels.
	 */
	public function onMouseLook(dx:Float, dy:Float):Void {}
}
