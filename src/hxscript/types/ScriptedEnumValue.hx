package hxscript.types;

import hxscript.proxy.TypeProxy;

using StringTools;
using hxscript.types.TypeCollection;

/** One value of a script-declared enum: its enum, constructor index/name, and any arguments. */
class ScriptedEnumValue implements ICustomEnumValueType {
	/** The enum this value belongs to. */
	var base:ScriptedEnum;

	/** The constructor index. */
	public var index:Int;

	/** The constructor name. */
	#if (js || lua) @:native("constructorName") #end public var constructor:String;

	/** The constructor arguments, or null for a parameterless constructor. */
	public var arguments:Array<Dynamic>;

	/**
	 * Creates an enum value.
	 *
	 * @param base The enum it belongs to.
	 * @param index The constructor index.
	 * @param arguments The constructor arguments, if any.
	 */
	public function new(base:ScriptedEnum, index:Int, ?arguments:Array<Dynamic>) {
		this.base = base;
		this.arguments = arguments;

		this.index = index;
		this.constructor = (base != null && base.values != null && index >= 0 && index < base.values.length) ? base.values[index] : null;
	}

	/** @return `Ctor` or `Ctor(arg,arg)` source-like text. */
	public function toString():String {
		if (arguments != null)
			return '$constructor(${arguments.join(',')})';

		return constructor;
	}

	/** @return The enum this value belongs to. */
	public function typeGetEnum():Dynamic {
		return base;
	}

	/**
	 * Structural equality: same constructor and equal arguments, matching values of the same enum
	 * even across a reload (compared by enum path).
	 *
	 * @param o The value to compare with.
	 * @return True if equal.
	 */
	public function eq(o:ICustomEnumValueType):Bool {
		if (!(o is ScriptedEnumValue))
			return false;

		var o:ScriptedEnumValue = cast o;
		if (o.base == base || (o.base != null && base != null && o.base.path == base.path)) {
			if (index != o.index)
				return false;
			if (o.arguments == null || arguments == null)
				return (o.arguments == arguments);

			if (arguments.length != o.arguments.length)
				return false;
			for (i => argument in arguments) {
				if (argument != o.arguments[i])
					return false;
			}

			return true;
		}

		return false;
	}
}
