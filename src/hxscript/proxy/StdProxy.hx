package hxscript.proxy;

import hxscript.types.ScriptedClass;
import hxscript.types.ScriptedInterface;
import hxscript.types.ScriptedEnum;
import hxscript.types.ScriptedTypedef;
import hxscript.types.AbstractValue;
import hxscript.types.AbstractTools;
import hxscript.types.ScriptedAbstract;
import hxscript.types.ScriptedAbstractValue;
import hxscript.proxy.TypeProxy.ICustomEnumValueType;

/**
 * A drop-in replacement for `Std`, aliased as `Std` inside the interpreter. It adds scripted-type
 * awareness to `isOfType`/`downcast` (walking the scripted class/interface chain) and forwards the
 * rest to native `Std`.
 */
class StdProxy {
	/**
	 * Deprecated alias for `isOfType`.
	 *
	 * @param v The value to test.
	 * @param t The class or interface to test against.
	 * @return True if `v` is of type `t`.
	 */
	@:deprecated('Std.is is deprecated. Use Std.isOfType instead.')
	/**
	 * The old name for `isOfType`, kept because scripts written against older Haxe still use it.
	 *
	 * @param v The value.
	 * @param t The type to test against.
	 * @return Whether the value is of that type.
	 */
	public static inline function is(v:Dynamic, t:Dynamic):Bool {
		return isOfType(v, t);
	}

	/**
	 * Tests a scripted value against a scripted class or interface by walking its base chain
	 * (or checking implemented interfaces).
	 *
	 * @param v The value to test; must be a scripted instance to match.
	 * @param t The scripted class or interface to test against.
	 * @return True if `v`'s scripted type is, extends, or implements `t`.
	 */
	static function matchesScripted(v:Dynamic, t:Dynamic):Bool {
		if (!(v is IScripted))
			return false;

		var base:ScriptedClass = @:privateAccess v.__base;
		if (base == null)
			return false;

		if (t is ScriptedInterface)
			return base.implementsInterface(cast t);

		while (base != null) {
			if (base == t)
				return true;

			var extending:Dynamic = base.extending;
			base = (extending is ScriptedClass) ? cast extending : null;
		}

		return false;
	}

	/**
	 * Runtime type check that understands scripted classes/interfaces.
	 *
	 * @param v The value to test.
	 * @param t The class or interface to test against.
	 * @return True if `v` is of type `t`.
	 */
	public static inline function isOfType(v:Dynamic, t:Dynamic):Bool {
		if (t is CoreType) {
			return switch (cast(t, CoreType)) {
				case CTInt: Std.isOfType(v, Int);
				case CTFloat: Std.isOfType(v, Float);
				case CTBool: Std.isOfType(v, Bool);
			};
		}
		if (t is ScriptedClass || t is ScriptedInterface) {
			return matchesScripted(v, t);
		} else if (t is ScriptedEnum) {
			if (!(v is ICustomEnumValueType))
				return false;
			var e:Dynamic = cast(v, ICustomEnumValueType).typeGetEnum();
			return e == t || (e is ScriptedEnum && (cast(e, ScriptedEnum).path == cast(t, ScriptedEnum).path));
		} else if (t is ScriptedAbstract) {
			if (!(v is ScriptedAbstractValue))
				return false;
			var o:ScriptedAbstract = cast(v, ScriptedAbstractValue).owner;
			return o == t || (o != null && o.path == cast(t, ScriptedAbstract).path);
		} else if (t is ScriptedTypedef) {
			return cast(t, ScriptedTypedef).matchesStructure(v);
		} else {
			return Std.isOfType(v, t);
		}
	}

	/**
	 * Safe cast that understands scripted classes/interfaces.
	 *
	 * @param value The value to cast.
	 * @param c The target class or interface.
	 * @return `value` if it is of type `c`, otherwise null.
	 */
	public static inline function downcast(value:Dynamic, c:Dynamic):Dynamic {
		if (c is CoreType)
			return (isOfType(value, c) ? value : null);
		if (c is ScriptedClass || c is ScriptedInterface) {
			return (matchesScripted(value, c) ? value : null);
		} else if (c is ScriptedEnum || c is ScriptedTypedef) {
			return (isOfType(value, c) ? value : null);
		} else {
			return Std.downcast(value, c);
		}
	}

	/**
	 * Deprecated alias for `downcast`.
	 *
	 * @param value The value to cast.
	 * @param c The target class.
	 * @return `value` if it is of type `c`, otherwise null.
	 */
	@:deprecated('Std.instance() is deprecated. Use Std.downcast() instead.')
	/**
	 * The old name for `downcast`, kept for the same reason as `is`.
	 *
	 * @param value The value.
	 * @param c The class to cast to.
	 * @return The value as that class, or null when it is not one.
	 */
	public static inline function instance(value:Dynamic, c:Dynamic):Dynamic {
		return downcast(value, c);
	}

	/**
	 * Converts a value to its string representation.
	 *
	 * @param s The value.
	 * @return Its string form.
	 */
	public static function string(s:Dynamic):String {
		if (s is AbstractValue) {
			var custom:Dynamic = Reflect.field(s, 'toString');
			if (custom != null && Reflect.isFunction(custom))
				return Std.string(Reflect.callMethod(s, custom, []));

			return Std.string(AbstractTools.underlying(s));
		}

		return Std.string(s);
	}

	/**
	 * Truncates a float toward zero.
	 *
	 * @param x The float.
	 * @return The integer part.
	 */
	public static inline function int(x:Float):Int {
		return Std.int(x);
	}

	/**
	 * Parses an integer from a string.
	 *
	 * @param x The string.
	 * @return The parsed integer, or null if it isn't one.
	 */
	public static inline function parseInt(x:String):Null<Int> {
		return Std.parseInt(x);
	}

	/**
	 * Parses a float from a string.
	 *
	 * @param x The string.
	 * @return The parsed float, or `Math.NaN` if it isn't one.
	 */
	public static inline function parseFloat(x:String):Float {
		return Std.parseFloat(x);
	}

	/**
	 * Returns a random integer in `[0, x)`.
	 *
	 * @param x The exclusive upper bound.
	 * @return A random integer below `x`.
	 */
	public static inline function random(x:Int):Int {
		return Std.random(x);
	}
}
