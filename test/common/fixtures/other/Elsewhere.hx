package other;

import other.AudioKind;

class Ctx {
	public var type:AudioKind;
	public var openal:Int;

	public function new() {
		type = OPENAL;
		openal = 0;
	}
}

class Elsewhere {
	public static var context:Ctx;
}
