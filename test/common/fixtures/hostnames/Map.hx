package hostnames;

/** A host class named as a standard type is, as a game's own `collections.Map` can be. */
class Map {
	var keys:Array<String> = [];

	public function new() {}

	public function add(key:String):Void {
		keys.push(key);
	}

	public function size():Int {
		return keys.length;
	}
}
