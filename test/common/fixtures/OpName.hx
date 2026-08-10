/** Fixture for `@:forward` on a compiled abstract: the boxed `String`'s own fields, through it. */
@:forward(length, toUpperCase)
@:build(hxscript.macro.Abstract.build())
abstract OpName(String) from String to String {
	public function new(v:String) {
		this = v;
	}

	/** Something of its own, so forwarding is not the only way to reach a member. */
	public function shout():String {
		return this + '!';
	}
}
