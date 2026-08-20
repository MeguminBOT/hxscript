package hxscript.types;

import hxscript.types.TypeCollection;

using hxscript.types.TypeCollection;

/** Helpers for resolving and constructing the runtime representation of abstracts and enum abstracts. */
class AbstractTools {
	/**
	 * Resolves an abstract by path to its generated `AbstractValue_*` implementation class.
	 *
	 * @param path The abstract's path.
	 * @return The implementation class, or null if it isn't a (known) abstract.
	 */
	public static function resolve(path:String):Class<AbstractValue> {
		var t = (TypeCollection.main.fromPath(path) ?? TypeCollection.main.fromCompilePath(path));

		if (t != null) {
			var a = Type.resolveClass(t[0].pack.join('.') + (t[0].pack.length > 0 ? '.' : '') + 'AbstractValue_'
				+ StringTools.replace(t[0].compilePath(), '.', '_'));

			if (a != null)
				return cast a;
		}

		return null;
	}

	/**
	 * Builds an abstract the host compiled, whose constructor is not on the class a script names.
	 *
	 * An abstract's constructor assigns to `this`, which has no meaning as a method on a value, so
	 * Haxe emits it as a static `_new` on the implementation class. The wrapper standing in for the
	 * abstract has a constructor of its own that boxes one underlying value, so `new HostVec(3, 4)`
	 * reached that instead and was told it could not make a `HostVec` out of a `3`.
	 *
	 * This is the shape every geometry type in a framework has: `h3d.Vector`, `h3d.Matrix` and
	 * `h2d.col.Point` are all it, and between them they are what a project's positions, transforms and
	 * bounds tests are written in.
	 *
	 * Here rather than in either caller because both need it and neither owns it: the interpreter
	 * constructs through `Interp.cnew` and a compiled HashLink module through `Runtime.make`, and the
	 * two answering differently about what `new` means is the whole hazard.
	 *
	 * @param c The class the name resolved to.
	 * @param args The constructor's arguments.
	 * @return The wrapped value, or null when this is not a host abstract with a reachable
	 *         constructor, which leaves the ordinary path to answer.
	 */
	public static function construct(c:Dynamic, args:Array<Dynamic>):Dynamic {
		if (c == null || !(c is Class) || Type.getSuperClass(c) != AbstractValue)
			return null;

		var path:Dynamic = Reflect.field(c, 'implClass');
		if (path == null)
			return null;

		var impl:Class<Dynamic> = Type.resolveClass(path);
		if (impl == null)
			return null;

		/**
		 * A missing `_new` leaves this to the ordinary path rather than reporting anything. An
		 * abstract need not have a constructor at all, and one that is `inline` may have been left
		 * with no runtime form, which is a fact about the host's build rather than about the script.
		 */
		var make:Dynamic = Reflect.field(impl, '_new');
		if (make == null)
			return null;

		return Type.createInstance(c, [Reflect.callMethod(null, make, args)]);
	}

	/**
	 * Opens a boxed abstract toward a type it declares itself convertible to.
	 *
	 * An `@:to` method answers first. Failing that, a `to` on the declaration itself hands the
	 * underlying value over, which is what makes `abstract Metres(Float) to Float` usable as a
	 * `Float` at all: there is no method behind that conversion, only the box coming off.
	 *
	 * Kept out of `Interp` deliberately. That class is large enough that adding a method to it moved
	 * every hot path's code around and cost the whole benchmark a few percent, for a conversion no
	 * hot path performs.
	 *
	 * @param e The boxed value.
	 * @param path The target type's name.
	 * @return The opened value, or null when the abstract declares no route to that type.
	 */
	public static function openTo(e:AbstractValue, path:String):Dynamic {
		var direct:Dynamic = e.resolveTo(path);
		if (direct != null)
			return direct;

		if (!(e is ScriptedAbstractValue))
			return null;

		var box:ScriptedAbstractValue = cast e;
		if (box.owner == null)
			return null;

		for (target in box.owner.to) {
			switch (target) {
				case CTPath(p, _) if ((p.length == 1 ? p[0] : p.join('.')) == path):
					return box.boxed;
				case _:
			}
		}

		return null;
	}

	/**
	 * Names the type of a value, reporting an enum-abstract by its underlying implementation name.
	 *
	 * @param v The value to name.
	 * @return The type name, or `'unknown'` if it can't be determined.
	 */
	public static function resolveName(v:Dynamic):String {
		if (v is ScriptedAbstractValue) {
			var owner:ScriptedAbstract = (cast v : ScriptedAbstractValue).owner;
			if (owner != null)
				return owner.path;
		}

		var vv:Dynamic = v;
		switch (Type.typeof(v)) {
			case TInt:
				return 'Int';
			case TFloat:
				return 'Float';
			case TBool:
				return 'Bool';
			case TObject:
				if (v is Enum)
					return Type.getEnumName(v);
			case TClass(c):
				vv = c;
			case TEnum(e):
				return Type.getEnumName(e);
			default:
				return 'unknown';
		}

		if (vv != null) {
			var name:String = Type.getClassName(vv);

			if (name != null) {
				if (Type.getSuperClass(vv) == AbstractValue)
					return (Reflect.field(vv, 'impl') ?? 'unknown');

				return name;
			}
		}

		return 'unknown';
	}

	/**
	 * Lists an enum abstract's constructor names.
	 *
	 * @param a The enum-abstract implementation class.
	 * @return The constructor names.
	 * @throws String If `a` is not an enum abstract.
	 */
	public static function getEnumConstructs(a:Class<AbstractValue>):Array<String> {
		var a:Dynamic = a;

		if (a.isEnum)
			return a._enumConstructors.copy();

		throw '${a?.impl ?? a} is not an enum abstract';
		return null;
	}

	/**
	 * Constructs an enum-abstract value by constructor name.
	 *
	 * @param a The enum-abstract implementation class.
	 * @param n The constructor name.
	 * @return The wrapped value.
	 * @throws String If `a` is not an enum abstract.
	 */
	public static function createEnum(a:Class<AbstractValue>, n:String):AbstractValue {
		var a:Dynamic = a;

		if (a.isEnum)
			return Type.createInstance(a, [a._enumValues[a._enumMap.get(n) ?? -1]]);

		throw '${a?.impl ?? a} is not an enum abstract';
		return null;
	}

	/**
	 * Constructs an enum-abstract value by constructor index.
	 *
	 * @param a The enum-abstract implementation class.
	 * @param i The constructor index.
	 * @return The wrapped value.
	 * @throws String If `a` is not an enum abstract.
	 */
	public static function createEnumIndex(a:Class<AbstractValue>, i:Int):AbstractValue {
		var a:Dynamic = a;

		if (a.isEnum)
			return Type.createInstance(a, [a._enumValues[i]]);

		throw '${a?.impl ?? a} is not an enum abstract';
		return null;
	}

	/**
	 * The method implementing `op` for a wrapped abstract, as recorded from its `@:op` metadata.
	 *
	 * @param v The value, which may or may not be an abstract.
	 * @param op The operator symbol, for example `+`.
	 * @return The method name to call on `v`, or null if `v` is not an abstract or declares no such operator.
	 */
	public static function opMethod(v:Dynamic, op:String):String {
		if (!(v is AbstractValue))
			return null;

		if (v is ScriptedAbstractValue)
			return (cast v : ScriptedAbstractValue).owner.ops.get(op);

		var cls:Dynamic = Type.getClass(v);
		if (cls == null)
			return null;

		var ops:Map<String, String> = Reflect.field(cls, '_ops');
		return (ops == null) ? null : ops.get(op);
	}

	/**
	 * Whether an abstract forwards a field to the value it boxes, per its `@:forward` metadata.
	 *
	 * @param v The value, which may or may not be an abstract.
	 * @param field The field name.
	 * @return True if reading `field` should fall through to the boxed value.
	 */
	public static function forwards(v:Dynamic, field:String):Bool {
		if (!(v is AbstractValue))
			return false;

		if (v is ScriptedAbstractValue)
			return (cast v : ScriptedAbstractValue).owner.forwards(field);

		var cls:Dynamic = Type.getClass(v);
		if (cls == null)
			return false;

		if (Reflect.field(cls, '_forwardAll') == true)
			return true;

		var list:Array<String> = Reflect.field(cls, '_forwards');
		return list != null && list.indexOf(field) >= 0;
	}

	/**
	 * Folds a native abstract's constant into the value it really is.
	 *
	 * A constant of an abstract IS its underlying value once the host is compiled: `FlxColor.RED` is
	 * an `Int` at every call site and a field of nothing anywhere, which is the whole reason a wrapper
	 * exists to give the interpreter something to read it from. A backend that COMPILES a script has
	 * to write that value into the bytecode itself, so it asks here.
	 *
	 * Only a static the abstract declared `inline` or `final` is answered for. Those are the two
	 * spellings Haxe folds itself, so what is written matches what the host's own compiler wrote for
	 * the same field, and an ordinary `static var`, which a script may assign to, is left to be read at
	 * run time. `_constants` is the wrapper's record of which its statics those are; a wrapper without
	 * that table falls back to the older test, which was to accept every field of an enum abstract.
	 *
	 * A wrapper offers a constant in one of two shapes: a lazy `get_NAME`, or, when the name collides
	 * with an accessor of the abstract, a plain static already holding the boxed value. Reading only
	 * the getter answered null for exactly the abstracts scripts name most, since `FlxColor.RED`
	 * collides with `get_red` and `FlxAxes.X` with `get_x`.
	 *
	 * @param wrapper The abstract's generated wrapper class.
	 * @param name The field's name.
	 * @return Its underlying value, or null when the field is not a foldable constant.
	 */
	public static function constantOf(wrapper:Dynamic, name:String):Null<Dynamic> {
		if (wrapper == null)
			return null;

		var listed:Array<String> = Reflect.field(wrapper, '_constants');

		if (listed != null) {
			if (listed.indexOf(name) < 0)
				return null;
		} else if (Reflect.field(wrapper, 'isEnum') != true) {
			return null;
		}

		var boxed:Dynamic = null;

		try {
			var getter:Dynamic = Reflect.field(wrapper, 'get_' + name);
			boxed = Reflect.isFunction(getter) ? Reflect.callMethod(wrapper, getter, []) : Reflect.field(wrapper, name);
		} catch (e:haxe.Exception) {
			return null;
		}

		if (boxed == null)
			return null;

		var value:Dynamic = (boxed is AbstractValue) ? boxed.__a : boxed;

		return switch (Type.typeof(value)) {
			case TInt | TFloat | TBool: value;
			case TClass(cls) if (cls == String): value;
			case _: null;
		}
	}

	/**
	 * Unwraps a wrapped abstract to the value it boxes; anything else passes through.
	 *
	 * @param v The value.
	 * @return The underlying value.
	 */
	public static inline function underlying(v:Dynamic):Dynamic {
		return (v is AbstractValue) ? v.__a : v;
	}

	/**
	 * Tests whether a value is a wrapped abstract.
	 *
	 * @param o The value.
	 * @return True if `o` is an `AbstractValue`.
	 */
	public static function isAbstract(o:Dynamic):Bool {
		return (o is AbstractValue);
	}
}
