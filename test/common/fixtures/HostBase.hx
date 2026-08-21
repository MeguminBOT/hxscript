/**
 * A compiled class for a script to extend, and nothing else.
 *
 * The conformance list has a case for extending something the host compiled, and that case needs a
 * base a bridge can be generated for on every target. Most of the standard library is not one:
 * `StringBuf` and `haxe.io.BytesBuffer` inline an abstract's constructor, and `haxe.Timer` starts a
 * real timer, which ended the process it was measured in. This is inert, has an ordinary constructor
 * and one plain field and one plain method, so what the case reports is about extending rather than
 * about whichever class it happened to name.
 */
class HostBase {
	/** A plain field, so a subclass can be seen to reach one. */
	public var kept:Int = 0;

	/**
	 * A running total, declared `Float`, for accumulating past what an `Int` holds.
	 *
	 * hxcpp cannot tell a whole `Float` from an `Int` inside a `Dynamic`, and Haxe keeps no field
	 * types at runtime, so a script adding into this has nothing to say which it is. It is here
	 * because getting that wrong is silent: the total simply wraps and reads as a plausible negative.
	 */
	public var tally:Float = 0;

	/**
	 * A property whose setter does more than store.
	 *
	 * A property of a compiled class has storage of its own name, so a write that reaches the storage
	 * directly leaves the field holding the right value and the accessor never run. Reading the field
	 * back says nothing about which of the two happened, and that is the whole hazard: it is what a
	 * framework recalculating on `set_x` sees, and what it sees is nothing. The doubling is here so
	 * the difference has a value, and `writes` so it has a count.
	 */
	public var scaled(default, set):Int = 0;

	/** How many times `set_scaled` ran, which a write that went past it leaves at zero. */
	public var writes:Int = 0;

	function set_scaled(v:Int):Int {
		writes++;
		scaled = v * 2;
		return scaled;
	}

	/** The same on the reading side: storage of the property's own name, behind a getter. */
	@:isVar public var shown(get, set):Int = 0;

	function get_shown():Int {
		return shown + 1;
	}

	function set_shown(v:Int):Int {
		shown = v;
		return v;
	}

	/** An ordinary constructor, which is what a bridge reconstructs. */
	public function new() {}

	/** A plain method, so a subclass can be seen to inherit one. */
	public function tell():Int {
		return 7;
	}
}
