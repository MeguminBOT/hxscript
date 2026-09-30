/**
 * A bridged base whose constructor has an untyped argument with a default.
 *
 * The argument is a `String`: it is passed to `EReg`, and `indexOf` is called on it.
 * Rebuilding the constructor without its type infers a structure from that call, and
 * `String` is not that structure because `indexOf` has an optional second argument.
 */
class HostIndexOf {
	var regex:EReg;
	var global:Bool;

	public function new(pattern:String, options = "") {
		global = options.indexOf("g") >= 0;
		regex = new EReg(pattern, options);
	}
}
