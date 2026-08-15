package hxscript.hl;

#if hxscript_hl
/**
 * What a compiled class put in a scripted one's place.
 *
 * Only the parts a compiled body cannot work out for itself, which is all of `super`: the base's
 * constructor, the base's own version of a method, and where the chain leaves the batch.
 */
@:structInit
class Replacement {
	/** The scripted class's path. */
	public var path:String;

	/** The class value that stands in for it, which is what a type test has to be made against. */
	public var value:Dynamic = null;

	/** The scripted class it replaced, which is what still knows the interfaces it declared. */
	public var scripted:Dynamic = null;

	/** The base of the same batch it extends, by path, or null. */
	public var base:Null<String> = null;

	/** The base the world already had, or null when the base is of the batch or there is none. */
	public var host:Null<hl.Type> = null;

	/** That base as the world's own class value, which is where its constructor is. */
	public var hostClass:Dynamic = null;

	/** Its own constructor, taking the instance first. */
	public var construct:Dynamic = null;

	/** Its own methods by name, each taking the instance first. */
	public var methods:Map<String, Dynamic>;
}
#end
