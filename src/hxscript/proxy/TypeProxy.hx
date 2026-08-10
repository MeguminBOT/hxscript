package hxscript.proxy;

import hxscript.types.*;
import hxscript.Config;
import Type.ValueType;

/**
 * A drop-in replacement for `haxe.Type`, aliased as `Type` inside the interpreter. Every method dispatches to
 * a scripted type's own implementation when the value implements the matching `ICustom*` interface, and falls
 * back to native `haxe.Type` (through the `Config.typeProxy` and the blacklist) otherwise.
 */
class TypeProxy {
	/** The world used to resolve scripted types by name; set before interpreting. */
	public static var environment:Environment = null;

	/**
	 * Returns the class of a value.
	 *
	 * @param o The value to inspect.
	 * @return The scripted class for a scripted instance, else the (proxied, blacklist-gated) native class.
	 */
	public static inline function getClass(o:Dynamic):Dynamic {
		if (o is ICustomClassType) {
			var o:ICustomClassType = cast o;
			return o.typeGetClass();
		} else {
			var t:Class<Dynamic> = Type.getClass(o);
			if (t == null)
				return null;

			return (ConfigUtil.assertBlacklisted(Config.typeProxy.get(Type.getClassName(t))));
		}
	}

	/**
	 * Returns the enum of an enum value.
	 *
	 * @param o The enum value to inspect.
	 * @return The scripted enum for a scripted value, else the (proxied, blacklist-gated) native enum.
	 */
	public static inline function getEnum(o:Dynamic):Dynamic {
		if (o is ICustomEnumValueType) {
			var o:ICustomEnumValueType = cast o;
			return o.typeGetEnum();
		} else {
			var t:Enum<Dynamic> = Type.getEnum(o);
			if (t == null)
				return null;

			return (ConfigUtil.assertBlacklisted(Config.typeProxy.get(Type.getEnumName(t))));
		}
	}

	/**
	 * Returns the super-class of a class.
	 *
	 * @param c The class to inspect.
	 * @return The scripted base for a scripted class (its `extending`), else the native super-class.
	 */
	public static inline function getSuperClass(c:Dynamic):Dynamic {
		if (c is ScriptedClass)
			return cast(c, ScriptedClass).extending;

		var c:Class<Dynamic> = Type.getSuperClass(c);
		if (c == null)
			return null;

		return (ConfigUtil.assertBlacklisted(Config.typeProxy.get(Type.getClassName(c)) ?? c));
	}

	/**
	 * Returns the fully-qualified name of a class.
	 *
	 * @param c The class to inspect.
	 * @return The scripted class's path, or the native class name.
	 */
	public static inline function getClassName(c:Dynamic):String {
		if (c is ScriptedClass)
			return cast(c, ScriptedClass).path;

		return Type.getClassName(c);
	}

	/**
	 * Returns the fully-qualified name of an enum.
	 *
	 * @param e The enum to inspect.
	 * @return The scripted enum's path, or the native enum name.
	 */
	public static inline function getEnumName(e:Dynamic):String {
		if (e is ScriptedEnum)
			return cast(e, ScriptedEnum).path;

		return Type.getEnumName(e);
	}

	/**
	 * Resolves a class by name, preferring a scripted class in the environment.
	 *
	 * @param name The fully-qualified class name.
	 * @return The scripted or native class, or null if unknown/blacklisted.
	 */
	public static inline function resolveClass(name:String):Dynamic {
		var t:Dynamic = environment?.resolve(name);
		if (t != null && t is ScriptedClass)
			return t;

		t = Type.resolveClass(name);
		if (t == null)
			return null;

		return (ConfigUtil.assertBlacklisted(Config.typeProxy.get(name) ?? t));
	}

	/**
	 * Resolves an enum by name, preferring a scripted enum in the environment.
	 *
	 * @param name The fully-qualified enum name.
	 * @return The scripted or native enum, or null if unknown/blacklisted.
	 */
	public static inline function resolveEnum(name:String):Dynamic {
		var t:Dynamic = environment?.resolve(name);
		if (t != null && t is ScriptedEnum)
			return t;

		t = Type.resolveEnum(name);
		if (t == null)
			return null;

		return (ConfigUtil.assertBlacklisted(Config.typeProxy.get(name) ?? t));
	}

	/**
	 * Constructs an instance of a class.
	 *
	 * @param cl The scripted or native class.
	 * @param args Constructor arguments.
	 * @return The new instance.
	 */
	public static inline function createInstance(cl:Dynamic, args:Array<Dynamic>):Dynamic {
		if (cl is ICustomClassType) {
			var cl:ICustomClassType = cast cl;
			return cl.typeCreateInstance(args);
		} else {
			return Type.createInstance(cl, args);
		}
	}

	/**
	 * Constructs an instance without running its constructor.
	 *
	 * @param cl The scripted or native class.
	 * @return The uninitialized instance.
	 */
	public static inline function createEmptyInstance(cl:Dynamic):Dynamic {
		if (cl is ICustomClassType) {
			var cl:ICustomClassType = cast cl;
			return cl.typeCreateEmptyInstance();
		} else {
			return Type.createEmptyInstance(cl);
		}
	}

	/**
	 * Constructs an enum value by constructor name.
	 *
	 * @param e The scripted or native enum.
	 * @param constr The constructor name.
	 * @param params Constructor arguments, if any.
	 * @return The enum value.
	 */
	public static inline function createEnum(e:Dynamic, constr:String, ?params:Array<Dynamic>):Dynamic {
		if (e is ICustomEnumType) {
			var e:ICustomEnumType = cast e;
			return e.typeCreateEnum(constr, params);
		} else {
			return Type.createEnum(e, constr, params);
		}
	}

	/**
	 * Constructs an enum value by constructor index.
	 *
	 * @param e The scripted or native enum.
	 * @param index The constructor index.
	 * @param params Constructor arguments, if any.
	 * @return The enum value.
	 */
	public static inline function createEnumIndex(e:Dynamic, index:Int, ?params:Array<Dynamic>):Dynamic {
		if (e is ICustomEnumType) {
			var e:ICustomEnumType = cast e;
			return e.typeCreateEnumIndex(index, params);
		} else {
			return Type.createEnumIndex(e, index, params);
		}
	}

	/**
	 * Lists a class's instance field names.
	 *
	 * @param c The scripted or native class.
	 * @return The instance field names.
	 */
	public static inline function getInstanceFields(c:Dynamic):Array<String> {
		if (c is ICustomClassType) {
			var c:ICustomClassType = cast c;
			return c.typeGetInstanceFields();
		} else {
			return Type.getInstanceFields(c);
		}
	}

	/**
	 * Lists a class's static field names.
	 *
	 * @param c The scripted or native class.
	 * @return The static field names.
	 */
	public static inline function getClassFields(c:Dynamic):Array<String> {
		if (c is ICustomClassType) {
			var c:ICustomClassType = cast c;
			return c.typeGetClassFields();
		} else {
			return Type.getClassFields(c);
		}
	}

	/**
	 * Lists an enum's constructor names.
	 *
	 * @param e The scripted or native enum.
	 * @return The constructor names.
	 */
	public static inline function getEnumConstructs(e:Dynamic):Array<String> {
		if (e is ICustomEnumType) {
			var e:ICustomEnumType = cast e;
			return e.typeGetEnumConstructs();
		} else {
			return Type.getEnumConstructs(e);
		}
	}

	/**
	 * Returns the runtime value-type tag of a value (always via native `Type`).
	 *
	 * @param v The value to inspect.
	 * @return Its `ValueType`.
	 */
	public static inline function typeof(v:Dynamic):ValueType {
		return Type.typeof(v);
	}

	/**
	 * Structural equality of two enum values.
	 *
	 * @param a The first value.
	 * @param b The second value.
	 * @return True if both are equal; a scripted value only equals another scripted value.
	 */
	public static inline function enumEq(a:Dynamic, b:Dynamic):Bool {
		if (a is ICustomEnumValueType) {
			if (b is ICustomEnumValueType)
				return cast(a, ICustomEnumValueType).eq(b);
			return false;
		} else {
			return Type.enumEq(a, b);
		}
	}

	/**
	 * Returns an enum value's constructor name.
	 *
	 * @param e The enum value.
	 * @return The constructor name.
	 */
	public static inline function enumConstructor(e:Dynamic):String {
		if (e is ICustomEnumValueType)
			return cast(e, ICustomEnumValueType).constructor;

		return Type.enumConstructor(e);
	}

	/**
	 * Returns an enum value's constructor arguments.
	 *
	 * @param e The enum value.
	 * @return The arguments, or an empty array for a parameterless constructor.
	 */
	public static inline function enumParameters(e:Dynamic):Array<Dynamic> {
		if (e is ICustomEnumValueType)
			return (cast(e, ICustomEnumValueType).arguments ?? []);

		return Type.enumParameters(e);
	}

	/**
	 * Returns an enum value's constructor index.
	 *
	 * @param e The enum value.
	 * @return The constructor index.
	 */
	public static inline function enumIndex(e:EnumValue):Int {
		if (e is ICustomEnumValueType)
			return cast(e, ICustomEnumValueType).index;

		return Type.enumIndex(e);
	}

	/**
	 * Returns every parameterless value of an enum.
	 *
	 * @param e The scripted or native enum.
	 * @return The parameterless enum values.
	 */
	public static inline function allEnums(e:Dynamic):Array<Dynamic> {
		if (e is ICustomEnumType) {
			var e:ICustomEnumType = cast e;
			return e.typeAllEnums();
		} else {
			return Type.allEnums(e);
		}
	}
}

/** Implemented by a scripted class so `TypeProxy` can reflect on it like a native `Class`. */
interface ICustomClassType extends ICustomType {
	/** @return A new instance with no constructor run. */
	public function typeCreateEmptyInstance():Dynamic;

	/**
	 * @param args Constructor arguments.
	 * @return A new instance.
	 */
	public function typeCreateInstance(args:Array<Dynamic>):Dynamic;

	/** @return The instance field names. */
	public function typeGetInstanceFields():Array<String>;

	/** @return The static field names. */
	public function typeGetClassFields():Array<String>;

	/** @return The class object standing in for this scripted class. */
	public function typeGetClass():Dynamic;
}

/** Implemented by a scripted enum so `TypeProxy` can reflect on it like a native `Enum`. */
interface ICustomEnumType extends ICustomType {
	/**
	 * @param index The constructor index.
	 * @param params Constructor arguments, if any.
	 * @return The enum value.
	 */
	public function typeCreateEnumIndex(index:Int, ?params:Array<Dynamic>):Dynamic;

	/**
	 * @param constr The constructor name.
	 * @param params Constructor arguments, if any.
	 * @return The enum value.
	 */
	public function typeCreateEnum(constr:String, ?params:Array<Dynamic>):Dynamic;

	/** @return The constructor names. */
	public function typeGetEnumConstructs():Array<String>;

	/** @return The enum's fully-qualified name. */
	public function typeGetEnumName():String;

	/** @return Every parameterless value of the enum. */
	public function typeAllEnums():Array<Dynamic>;
}

/** Implemented by a scripted enum value so `TypeProxy` can reflect on it like a native `EnumValue`. */
interface ICustomEnumValueType extends ICustomType {
	/** The value's constructor index. */
	public var index:Int;

	/** The value's constructor name. */
	#if (js || lua) @:native("constructorName") #end public var constructor:String;

	/** The value's constructor arguments. */
	public var arguments:Array<Dynamic>;

	/** @return The enum this value belongs to. */
	public function typeGetEnum():Dynamic;

	/**
	 * Structural equality against another scripted enum value.
	 *
	 * @param e The value to compare with.
	 * @return True if equal.
	 */
	public function eq(e:ICustomEnumValueType):Bool;
}

/** Base marker for the reflection interfaces a scripted type may implement. */
interface ICustomType {}
