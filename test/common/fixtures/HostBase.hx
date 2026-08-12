/**
 * A compiled class for a script to extend, and nothing else.
 *
 * The conformance list has a case for extending something the host compiled, and that case needs a
 * base a bridge can be generated for on every target. Most of the standard library is not one:
 * `StringBuf` and `haxe.io.BytesBuffer` inline an abstract's constructor and are refused on
 * HashLink, and `haxe.Timer` starts a real timer, which ended the process it was measured in. This
 * is inert, has an ordinary constructor and one plain field and one plain method, so what the case
 * reports is about extending rather than about whichever class it happened to name.
 */
class HostBase {
	/** A plain field, so a subclass can be seen to reach one. */
	public var kept:Int = 0;

	/** An ordinary constructor, which is what a bridge reconstructs. */
	public function new() {}

	/** A plain method, so a subclass can be seen to inherit one. */
	public function tell():Int {
		return 7;
	}
}
