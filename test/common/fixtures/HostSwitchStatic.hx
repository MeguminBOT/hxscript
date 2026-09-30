/**
 * A bridged base whose constructor reads its own static in a switch, beside another class's static
 * of the same name.
 *
 * The switch prints the static without its class, which a subclass cannot see. The typed switch says
 * which `count` it is.
 */
class SwitchStaticOther {
	public static var count:Int = 100;
}

class HostSwitchStatic {
	static var count:Int = 5;

	public var mine:Int = -1;
	public var theirs:Int = -1;

	public function new(mode:Int) {
		switch (mode) {
			case 0:
				mine = count;
			default:
		}
		theirs = SwitchStaticOther.count;
	}
}
