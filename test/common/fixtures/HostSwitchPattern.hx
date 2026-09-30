/**
 * A bridged base whose switch captures into a name its case also reads as another class's static.
 *
 * A pattern is left as written: `count` binds the subject, and `SwitchPatternOther.count` is the
 * static. Rewriting the pattern to the static does not compile.
 */
class SwitchPatternOther {
	public static var count:Int = 1000;
}

class HostSwitchPattern {
	public var x:Int = -1;

	public function new(mode:Int) {
		switch (mode) {
			case 0:
				x = 0;
			case count:
				x = count + SwitchPatternOther.count;
		}
	}
}
