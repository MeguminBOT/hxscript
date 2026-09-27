/**
 * A bridged base whose method takes an abstract with a string default.
 *
 * The default is a string constant in the typed tree. Annotating the argument `String` makes the
 * bridge override a different signature from the base, and the build stops.
 */
abstract HostMark(String) from String to String {
	public inline function new(s:String) {
		this = s;
	}
}

class HostMarked {
	public function new() {}

	public function report(mark:HostMark = "none"):HostMark {
		return mark;
	}
}
