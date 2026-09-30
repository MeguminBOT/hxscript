/**
 * A bridged base whose constructor writes its own field in a switch, beside another class's static
 * of the same name.
 *
 * The switch is reprinted from source, where `width` is `this.width`. Qualified by its name alone, the
 * write went to `SwitchFieldOther.width` and left the field at 0.
 */
class SwitchFieldOther {
	public static var width:Int = 99;
}

class HostSwitchField {
	public var width:Int = 0;

	public function new(mode:Int) {
		switch (mode) {
			case 0:
				width = 10;
			default:
				width = SwitchFieldOther.width;
		}
	}
}
