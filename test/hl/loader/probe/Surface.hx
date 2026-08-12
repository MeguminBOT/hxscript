package probe;

/**
 * A host class a script may extend, standing in for the ones a real application offers.
 *
 * The point of it is the bridge. A scripted class with no native base is allocated from
 * `ScriptedObject` and keeps everything the interpreter gives it; one that extends a host class gets
 * a generated bridge instead, which overrides each inherited method and holds native fields beside
 * the scripted ones. That is what an application's scripts actually extend, and it is a different
 * object from the one the corpus exercises.
 */
@:scriptable
class Surface {
	/** A native field, so a script can be seen to reach one. */
	public var ticks:Int = 0;

	public function new() {}

	/** Overridden by the script, and called by it through `super`. */
	public function tick():Void {
		ticks++;
	}

	/** Overridden by the script, and never called by it, so the override has to win on its own. */
	public function label():String {
		return 'surface';
	}
}
