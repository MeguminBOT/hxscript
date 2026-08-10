package hxscript.compile;

import haxe.io.Bytes;

/** What a compile produced. */
@:structInit
class Result {
	/** The module, or null when nothing could be compiled. */
	public var bytes:Null<Bytes>;

	/** Modules that compiled, by name. These may be loaded from the module. */
	public var compiled:Array<String>;

	/** Modules that did not, each with the reason and where it was. These must keep being interpreted. */
	public var skipped:Array<Skip>;
}
