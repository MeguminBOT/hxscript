/**
 * A bridged base with a field named `Reflect`.
 *
 * The bridge calls the standard library's `Reflect`. Written as a bare identifier inside those
 * instance methods, the call binds to this field, and the bridge does not compile.
 */
class HostNamedReflect {
	public var Reflect:String = "host";

	public function new() {}

	public function read():String {
		return Reflect;
	}
}
