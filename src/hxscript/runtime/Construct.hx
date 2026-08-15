package hxscript.runtime;

import hxscript.types.AbstractTools;
import hxscript.types.ArgumentTools;

/**
 * What `new` means when an instruction cannot say it.
 *
 * cppia builds an object with a `NEW` opcode naming a type and an arity, and both halves of that are
 * written when the module is emitted. Two ordinary constructions have no such spelling.
 *
 * **A host abstract has no class to make.** Its constructor assigns to `this`, which has no meaning
 * as a method on a value, so Haxe emits it as a static `_new` on the implementation class and the
 * abstract itself is left with no runtime class at all. `NEW` naming one resolved to null and the
 * hxcpp process ended part way through, silently and with a success code, so the emitter refused
 * every module that constructed one instead: safe, and `h3d.Vector`, `h3d.Matrix` and `h2d.col.Point`
 * are all that shape, which is most of what a 3D script does.
 *
 * **An arity cannot place an argument.** Haxe lets a call leave out an optional parameter that is
 * not the last one and decides which by type, so `new Mesh(prim, parent)` against `(primitive,
 * ?material, ?parent)` means the first and the third. `NEW` is arity-linked and pads from the right,
 * which writes the parent into the material, and the emitter cannot ask what an argument is because
 * it holds an expression rather than a value.
 *
 * Both are questions about the arguments in hand, so both are answered here, where the arguments are
 * in hand. The same two helpers the interpreter and the HashLink backend construct through, in the
 * same order, so the three cannot disagree about what one `new` meant.
 *
 * Only where `NEW` will not do. An ordinary construction is still an opcode and costs nothing extra;
 * this is reached for a host abstract and for a call short of a middle optional, and for nothing
 * else.
 */
@:keep
class Construct {
	/** Types by the path emitted for them, misses included, so a repeated `new` costs a map read. */
	static var types:Map<String, Dynamic> = new Map();

	/**
	 * Builds a host type from the arguments a call wrote.
	 *
	 * @param path The type's compile path, as the emitter resolved it.
	 * @param args The arguments as the call wrote them.
	 * @return The constructed value.
	 * @throws String If nothing at runtime answers to that path.
	 */
	public static function make(path:String, args:Array<Dynamic>):Dynamic {
		var type:Dynamic = resolve(path);

		if (type == null)
			throw 'Cannot construct $path, which nothing at runtime answers to';

		/**
		 * The abstract question first, because its answer is `null` for everything else and the
		 * ordinary path is what follows. Reaching the static its constructor became is the whole of
		 * what a wrapper cannot do for itself: building one directly boxes the first argument, and a
		 * script that wrote `new HostVec(3, 4)` was told it could not make a `HostVec` out of a `3`.
		 */
		var boxed:Dynamic = AbstractTools.construct(type, args);
		if (boxed != null)
			return boxed;

		return hxscript.proxy.TypeProxy.createInstance(type, ArgumentTools.forConstructor(type, args));
	}

	/**
	 * @param path A type's compile path.
	 * @return The class to construct, an abstract's wrapper included, or null when there is none.
	 */
	static function resolve(path:String):Dynamic {
		if (types.exists(path))
			return types.get(path);

		var type:Dynamic = AbstractTools.resolve(path);

		if (type == null)
			type = Type.resolveClass(path);

		types.set(path, type);
		return type;
	}
}
