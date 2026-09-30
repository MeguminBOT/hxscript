/**
 * A bridged base whose constructor passes `null` to a required argument that has an optional after it.
 *
 * `getTypedExpr` prints the omitted optional as a second `null`. Dropping every trailing `null`
 * removes the required one too, and the call is left with no arguments.
 */
class HostKeptNull {
	public function new() {
		take(null);
		only(null);
		new Opt();
	}

	public function take(callback:String, extra:String = null):String {
		return callback;
	}

	public function only(data:String):String {
		return data;
	}
}

class Opt {
	public function new(a:Float = 0, b:Float = 0) {}
}
