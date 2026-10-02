/** What a `HostBare` holds. */
class HostBareImpl {
	public var n:Int;

	public function new(n:Int) {
		this.n = n;
	}
}

/**
 * A host abstract nothing wraps for scripts: no `@:build`, in no preset.
 *
 * Its name is in the type table all the same, which is what let `new HostBare(3)` reach a plain
 * `NEW` naming a class nothing answers to. Most of a framework's abstracts are this, since a host
 * wraps only the handful it names: lime's typed arrays, openfl's `ByteArray`, `Dictionary` and
 * `Vector`.
 */
abstract HostBare(HostBareImpl) {
	public inline function new(n:Int) {
		this = new HostBareImpl(n);
	}
}
