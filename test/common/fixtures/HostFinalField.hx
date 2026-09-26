/**
 * A bridged base whose constructor writes a `final` field.
 *
 * That write is legal in this constructor. The rebuilt constructor is a method of the subclass,
 * and a `final` field can only be written by the class that declares it, so the bridge does not
 * compile. The rebuild has to be refused.
 */
class HostFinalField {
	final kept:Int;

	public function new() {
		kept = 1;
	}

	public function read():Int {
		return kept;
	}
}
