/**
 * A bridged base whose constructor builds a string from a `UInt` field.
 *
 * The conversion is an inline abstract method. Its `this` is the underlying `Int`. Printed into
 * the bridge, `this` is the instance, and C++ tries to store the object in an `Int`.
 */
class HostUIntString {
	public var id:UInt;

	public function new() {
		id = 1;
		var label = "id=" + id;
	}
}
