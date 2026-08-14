package hxscript.hl;

#if hxscript_hl
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

	/**
	 * The entry holding its statics, which is what the class value itself is.
	 *
	 * The world lays a class value out this way too: a type per class extending `hl.BaseType.Class`,
	 * carrying that class's statics as ordinary fields. Following it is what lets a static be an
	 * offset off a global rather than a name looked up in the class the interpreter holds.
	 */
	public var holder:Int;

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

	/** The statics it lays out, by name, so the world can fill each one. */
	public var stored:Array<String>;
}

/** One type that stands for a class the world already has, until the loader points it at the real one. */
@:structInit
class Link {
	/** The entry in the module's type table. */
	public var at:Int;

	/** The class it stands for, as the script wrote it, or null when the emitter had it already. */
	public var host:Null<String> = null;

	/** The class it stands for, when nothing has to be resolved to find it. */
	public var type:Null<hl.Type> = null;
}
#end
