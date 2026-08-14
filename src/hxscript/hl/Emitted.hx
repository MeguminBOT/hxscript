package hxscript.hl;

/**
 * A class the emitter wrote a type for, and the pieces the world needs to make it real.
 *
 * The bytecode carries the layout; everything a loaded class still needs is done from Haxe, because
 * a class value is an ordinary object of the world's own `hl.BaseType.Class` and the world is what
 * knows how to make one.
 */
@:structInit
class Emitted {
	/** The class's name in the batch. */
	public var name:String;

	/** Its full path, which is what the world resolves it by. */
	public var path:String;

	/** Its entry in the module's type table. */
	public var type:Int;

	/** The global its class value goes in, as `Loader.set` numbers them. */
	public var global:Int;

	/** The function that allocates nothing and fills everything, taking the instance first. */
	public var construct:Int;

	/** The base the world already has, as the script wrote it, or null when the base is of the batch. */
	public var host:Null<String> = null;

	/** The base of the batch it extends, or null when it extends the world's or nothing. */
	public var base:Null<String> = null;

	/** Its own methods, by name, as function indices taking the instance first. */
	public var methods:Map<String, Int>;
}

/** One type that stands for a class the world already has, until the loader points it at the real one. */
@:structInit
class Link {
	/** The entry in the module's type table. */
	public var at:Int;

	/** The class it stands for, as the script wrote it. */
	public var host:String;
}
