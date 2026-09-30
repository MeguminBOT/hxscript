/**
 * A bridged base whose constructor reads one of its own static fields.
 *
 * `getTypedExpr` prints the field as a bare name. A subclass does not inherit a static, so the
 * rebuilt constructor cannot see it unless the owner is put back.
 */
class HostScale {
	public var span:Float;

	public function new(span:Float) {
		this.span = span;
	}
}

class HostStaticRead {
	public static final melee:HostScale = new HostScale(8);

	public var chosen:HostScale;

	public function new() {
		chosen = melee;
	}
}
