/**
 * A bridged base whose field initializer constructs a private type.
 *
 * The field's type is public, and the constructor body does not mention the private type. The
 * initializer is still lifted into the bridge, which cannot name it.
 */
class HostPrivateInit {
	var box:InitBox = new InitBox(new Hidden());

	public function new() {}
}

class InitBox {
	public function new(item:Dynamic) {}
}

private class Hidden {
	public function new() {}
}
