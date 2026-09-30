/**
 * A bridged base whose constructor reaches `switchroot.Math` and then the root `Math` in a switch.
 *
 * Qualified by its short name alone, the switch's `Math` became `switchroot.Math`, the one met first.
 */
class HostSwitchRoot {
	public var a:Float = 0;
	public var b:Float = -1;

	public function new(mode:Int) {
		a = switchroot.Math.abs(-1);
		switch (mode) {
			case 0:
				b = Math.abs(-3);
			default:
		}
	}
}
