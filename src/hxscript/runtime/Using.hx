package hxscript.runtime;

/**
 * What `o.f(args)` means when a `using` is in scope and nothing knew what `o` was.
 *
 * A static extension is resolved against the receiver's value, not its written type: the receiver's
 * own member wins, and only when there is none does each `using` type get tried in the order it was
 * declared. A compiled body cannot decide that where the receiver's type is unknown, so it defers
 * the same decision to run time and reaches the same answer the interpreter reaches.
 *
 * Shared rather than written per backend, so every backend resolves a static extension alike.
 */
@:keep
class Using {
	/**
	 * Calls the receiver's own member, or the first static extension that accepts it.
	 *
	 * @param receiver What the call was written on.
	 * @param owners The `using` types in scope that declare this name, in declaration order.
	 * @param name The method name.
	 * @param args The written arguments, without the receiver.
	 * @return What the call answered.
	 */
	public static function call(receiver:Dynamic, owners:Array<Dynamic>, name:String, args:Array<Dynamic>):Dynamic {
		var own:Dynamic = receiver == null ? null : Reflect.field(receiver, name);
		if (Reflect.isFunction(own))
			return Reflect.callMethod(receiver, own, args);

		for (path in owners) {
			var owner:Dynamic = hxscript.types.TypeTools.resolve(path);
			if (owner == null)
				continue;

			var ext:Dynamic = Reflect.field(owner, name);
			if (!Reflect.isFunction(ext))
				continue;

			var passed:Array<Dynamic> = [receiver].concat(args);

			try {
				return Reflect.callMethod(owner, ext, passed);
			} catch (e:Dynamic) {}
		}

		return Reflect.callMethod(receiver, own, args);
	}
}
