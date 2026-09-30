/**
 * A bridged base whose constructor calls its own method in a switch, beside another class's static
 * of the same name.
 *
 * The switch is reprinted from source, where `make()` is `this.make()`. Qualified by its name alone,
 * it called `SwitchMethodOther.make()`.
 */
class SwitchMethodOther {
	public static function make():Int {
		return 2;
	}
}

class HostSwitchMethod {
	public var a:Int = -1;
	public var b:Int = -1;

	public function new(mode:Int) {
		switch (mode) {
			case 0:
				a = make();
			default:
		}
		b = SwitchMethodOther.make();
	}

	public function make():Int {
		return 1;
	}
}
