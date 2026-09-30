/**
 * A public box, so `new PrivateBox<PrivateToken>()` is not a `new` of the private type.
 */
class PrivateBox<T> {
	public function new() {}
}
