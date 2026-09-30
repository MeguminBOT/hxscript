/**
 * A bridged base whose constructor builds a root-package class after naming a same-named one.
 *
 * `getTypedExpr` prints the root class's `new` without a package. Putting one back from every type
 * the constructor mentions picked `twin.TwinKind`, the one named first.
 */
class HostTwinNew {
	public var made:String;

	public function new() {
		var spare:twin.TwinKind = null;
		made = new TwinKind().kind;
	}
}
