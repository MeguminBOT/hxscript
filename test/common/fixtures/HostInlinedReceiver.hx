/**
 * A bridged base whose constructor calls an inline abstract method on one of its statics, with one
 * of its own fields as the argument.
 *
 * Haxe inlines the call through a local named `this` holding the map, while the argument still reads
 * the instance. `getTypedExpr` prints both as `this`.
 */
class HostInlinedReceiver {
	static var byId:Map<Int, HostInlinedReceiver> = new Map();

	public var id:Int;
	public var registered:Bool;

	public function new(id:Int) {
		this.id = id;
		byId.set(this.id, this);
		registered = byId.get(this.id) == this;
	}
}
