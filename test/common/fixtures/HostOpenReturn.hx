/**
 * A bridged base whose method returns the result of calling a `Dynamic`.
 *
 * That return has no concrete type yet. Printing it as `Dynamic` makes the override disagree
 * with the parent (`Dynamic should be Unknown`).
 */
class HostOpenReturn {
	var raw:Dynamic;

	public function new() {}

	public function kind(handle:Int) {
		return raw(handle);
	}
}
