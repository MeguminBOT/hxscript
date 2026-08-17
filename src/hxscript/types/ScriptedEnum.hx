package hxscript.types;

import hxscript.proxy.ReflectProxy;
import hxscript.proxy.TypeProxy;
import hxscript.runtime.Interp;
import hxscript.syntax.Expr;
import hxscript.Environment;
import hxscript.Module;

using StringTools;
using hxscript.types.TypeCollection;

/**
 * The runtime representation of a script-declared `enum`. It knows its constructor names and, for
 * parameterized constructors, the builder functions that produce `ScriptedEnumValue`s, and
 * implements the reflection/type interfaces so `TypeProxy` treats it like a native enum.
 */
@:access(hxscript.Module)
class ScriptedEnum implements IScriptedType implements ICustomReflection implements ICustomEnumType {
	/** The enum's short name. */
	public var name:String;

	/** The module that declares this enum. */
	public var module:Module;

	/** The enum's package segments. */
	public var pack:Array<String>;

	/** The enum's fully-qualified path. */
	public var path:String;

	/** Constructor names in declaration order (populated by `init`). */
	public var values:Array<String>;

	/** Constructor declarations keyed by name (populated by `init`). */
	public var constructs:Map<String, EnumFieldDecl>;

	/** Builder functions for parameterized constructors, keyed by name. */
	var constructFunctions:Map<String, Array<Dynamic>->ScriptedEnumValue>;

	/** The parsed enum declaration. */
	var decl:EnumDecl;

	/** True if initialization failed. */
	public var failed:Bool = false;

	/** True once initialized. */
	public var initialized:Bool = false;

	/** True while initializing (guards re-entrancy). */
	public var initializing:Bool = false;

	/**
	 * Creates the runtime enum from its declaration.
	 *
	 * @param decl The parsed enum declaration.
	 * @param module The declaring module, if any.
	 */
	public function new(decl:EnumDecl, ?module:Module) {
		this.name = decl.name;
		this.pack = (module?.pack ?? []);
		this.module = module;
		this.decl = decl;

		path = TypeTools.pathToString(name, pack);
	}

	/**
	 * Populates the constructor names/declarations and builds a validating var-args builder for each
	 * parameterized constructor.
	 *
	 * @param env Unused; present for interface-uniform signatures.
	 * @param baseInterp Unused; present for interface-uniform signatures.
	 * @param restore Unused; present for interface-uniform signatures.
	 */
	public function init(?env:Environment, ?baseInterp:Interp, restore:Bool = true):Void {
		values = decl.names.copy();
		constructs = decl.constructs.copy();
		constructFunctions = new Map();

		for (name => construct in constructs) {
			var params = construct.arguments;
			if (params != null) {
				var minParams:Int = 0;
				for (i => p in params) {
					if (!p.opt)
						minParams = (i + 1);
				}

				constructFunctions.set(name, Reflect.makeVarArgs(function(args:Array<Dynamic>) {
					if (args.length < minParams) {
						var arg = params[args.length];
						var argType:String = arg.name;
						if (arg.t != null)
							argType += (':' + new Printer().typeToString(arg.t));

						throw 'Not enough arguments, expected $argType';
					}
					if (args.length > params.length && params.length > 0) {
						throw 'Too many arguments';
					}

					return new ScriptedEnumValue(this, values.indexOf(name), args);
				}));
			}
		}
	}

	/**
	 * Constructor names, readable before `init` has run (falls back to the declaration).
	 *
	 * @return The constructor names, or null if unavailable.
	 */
	public function constructNames():Array<String> {
		return (values ?? (decl != null ? decl.names : null));
	}

	/**
	 * Whether the constructor at index `i` takes parameters.
	 *
	 * @param i The constructor index.
	 * @return True if that constructor is parameterized.
	 */
	public function constructorHasArgs(i:Int):Bool {
		if (constructFunctions == null && decl != null)
			init();

		var names:Array<String> = constructNames();
		if (names == null || i < 0 || i >= names.length)
			return false;

		var name:String = names[i];
		var c:EnumFieldDecl = (constructs != null ? constructs.get(name) : (decl != null
			&& decl.constructs != null ? decl.constructs.get(name) : null));
		return c != null && c.arguments != null;
	}

	/** @return A debug string identifying this enum. */
	public function toString():String {
		return 'ScriptedEnum<$path>';
	}

	/** @return The enum's fully-qualified path. */
	public function typeGetEnumName():String {
		return path;
	}

	/**
	 * Constructs a value by constructor name (calling its builder for a parameterized constructor).
	 *
	 * @param constr The constructor name.
	 * @param arguments Constructor arguments, if any.
	 * @return The enum value, or null if the constructor is unknown.
	 */
	public function typeCreateEnum(constr:String, ?arguments:Array<Dynamic>):Dynamic {
		var construct:EnumFieldDecl = constructs.get(constr);
		if (construct != null) {
			if (constructFunctions.exists(constr)) {
				return Reflect.callMethod(this, constructFunctions.get(constr), arguments ?? []);
			} else {
				return new ScriptedEnumValue(this, values.indexOf(constr));
			}
		}
		return null;
	}

	/**
	 * Constructs a value by constructor index.
	 *
	 * @param index The constructor index.
	 * @param arguments Constructor arguments, if any.
	 * @return The enum value, or null if the index is out of range.
	 */
	public function typeCreateEnumIndex(index:Int, ?arguments:Array<Dynamic>):Dynamic {
		return typeCreateEnum(values[index], arguments);
	}

	/** @return A copy of the constructor names. */
	public function typeGetEnumConstructs():Array<String> {
		return (values?.copy() ?? []);
	}

	/** @return A value for every parameterless constructor. */
	public function typeAllEnums():Array<Dynamic> {
		var enums:Array<ScriptedEnumValue> = [];

		for (index => constr in values) {
			if (constructs.get(constr).arguments == null)
				enums.push(new ScriptedEnumValue(this, index));
		}

		return enums;
	}

	/**
	 * An enum has no reflectable fields.
	 *
	 * @param field Unused.
	 * @return Always false.
	 */
	public function reflectHasField(field:String):Bool {
		return false;
	}

	/**
	 * Resolves a constructor name to its value or builder (this is how `Enum.Ctor` reads).
	 *
	 * @param field The constructor name.
	 * @return The value (or builder for a parameterized constructor), or null if unknown.
	 */
	public function reflectGetField(field:String):Dynamic {
		var construct:EnumFieldDecl = constructs.get(field);
		if (construct != null) {
			if (constructFunctions.exists(field)) {
				return constructFunctions.get(field);
			} else {
				return new ScriptedEnumValue(this, values.indexOf(field));
			}
		}
		return null;
	}

	/**
	 * An enum's constructors are read-only.
	 *
	 * @param field Unused.
	 * @param value Unused.
	 * @return Always null.
	 */
	public function reflectSetField(field:String, value:Dynamic):Dynamic {
		return null;
	}

	/**
	 * Alias of `reflectGetField`.
	 *
	 * @param property The constructor name.
	 * @return The value or builder.
	 */
	public function reflectGetProperty(property:String):Dynamic {
		return reflectGetField(property);
	}

	/**
	 * An enum's constructors are read-only.
	 *
	 * @param property Unused.
	 * @param value Unused.
	 * @return Always null.
	 */
	public function reflectSetProperty(property:String, value:Dynamic):Dynamic {
		return null;
	}

	/** @return Null; an enum exposes constructors, not fields. */
	public function reflectListFields():Array<String> {
		return null;
	}

	/** No-op: an enum has no state to snapshot. */
	public function snapshot():Void {}
}
