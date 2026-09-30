/**
 * A bridged base whose constructor takes an enum abstract with a constant default.
 *
 * The constant inlines to its underlying string. Annotating the argument `String` makes the
 * bridge constructor a different signature from the base.
 */
enum abstract HostKind(String) to String {
	var Common = "common";
}

class HostKinded {
	public var kind:HostKind;

	public function new(kind:HostKind = Common) {
		this.kind = kind;
	}
}
