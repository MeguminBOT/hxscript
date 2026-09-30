/**
 * A bridged base with a field named `Type`.
 *
 * The bridge constructor calls the standard library's `Type`. Written as a bare identifier inside
 * that instance method, the call binds to this field, and the bridge does not compile.
 */
class HostNamedType {
	public var Type:String = "host";

	public function new() {}

	public function read():String {
		return Type;
	}
}
