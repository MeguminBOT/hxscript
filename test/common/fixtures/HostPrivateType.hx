/**
 * A bridged base whose constructor mentions a private type.
 *
 * The typed body carries `PrivateToken` as a type parameter and as a cast. Neither is a `TNew`
 * of that type, so a check that only looks at constructed classes still reprints the name, and
 * the bridge module cannot see a private type. The rebuild has to be refused.
 *
 * `PrivateBox` lives in its own file. A generic declaration anywhere in this one makes the
 * scanner treat the whole module as parameterized and skip it, so the bridge is never built.
 */
class HostPrivateType {
	public function new() {
		var box = new PrivateBox<PrivateToken>();
		var token:PrivateToken = cast box;
		token.n = 1;
	}
}

private class PrivateToken {
	public var n:Int = 0;

	public function new() {}
}
