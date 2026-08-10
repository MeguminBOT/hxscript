package host;

#if openfl
import openfl.display.Sprite;
#end

/**
 * The base a project extends when it wants to own its own loop.
 *
 * Three ways of writing a project run in this app, and this is the one for the level below a game framework,
 * where a script reaches lime and openfl directly and draws for itself. The other two need nothing from
 * here: a project extending `flixel.FlxState` gets the whole of flixel's lifecycle, and one extending
 * `openfl.display.Sprite` is added to the display list.
 *
 * The host owns the `lime.app.Application`, because a script cannot subclass one: it would have had to exist
 * before the process did. So the host hands the same lifecycle back, calling `start` once, `update` per
 * frame, `stop` on the way out, and the input callbacks in between. Nothing is lost by the arrangement,
 * because `lime.ui`, `lime.system` and `lime.math` are all reachable by name from inside these methods.
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
	 * The display object to draw into, given by the host before `start`.
	 *
	 * Owned by the app, not by the project: the shell adds it, sizes it, and empties it when the
	 * project stops, so a project that forgets to clean up after itself cannot leak into the next
	 * one.
	 *
	 * Gated, so this class still compiles in the headless check, which has no openfl under it. A
	 * base that only compiles in one of the two builds is a base the other build cannot bridge, and
	 * then the check cannot answer the one question it exists to answer.
	 */
	#if openfl
	public var layer:Sprite = null;
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
	 * @param code The `lime.ui.KeyCode` value, which a script can compare against `KeyCode.SPACE`
	 *        and friends because lime's key codes are wrapped for scripting.
	 */
	public function onKeyDown(code:Int):Void {}

	/**
	 * A key came up.
	 *
	 * @param code The `lime.ui.KeyCode` value.
	 */
	public function onKeyUp(code:Int):Void {}

	/**
	 * The pointer moved.
	 *
	 * @param x Stage x.
	 * @param y Stage y.
	 */
	public function onMouseMove(x:Float, y:Float):Void {}

	/**
	 * The pointer went down.
	 *
	 * @param x Stage x.
	 * @param y Stage y.
	 */
	public function onMouseDown(x:Float, y:Float):Void {}
}
