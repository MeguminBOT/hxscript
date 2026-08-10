package hxscript.types;

import hxscript.proxy.ReflectProxy;
import hxscript.runtime.Interp;
import hxscript.syntax.Expr;
import hxscript.Environment;
import hxscript.Module;

using StringTools;
using hxscript.types.TypeCollection;

/**
 * A script-declared `interface`. Carries no implementation: it exists so classes can
 * be checked against a contract, and so `x is IFoo` answers for scripted types the way
 * a native interface does for compiled ones.
 */
@:access(hxscript.runtime.Interp)
@:access(hxscript.types.ScriptedClass)
class ScriptedInterface implements IScriptedType implements ICustomReflection {
	/** The interface's fully-qualified path. */
	public var path:String;

	/** The interface's short name. */
	public var name:String;

	/** The module that declares this interface. */
	public var module:Module;

	/** The interface's package segments. */
	public var pack:Array<String>;

	/** The interface's own interpreter (used to resolve its parents). */
	public var interp:Interp;

	/** Resolved parent interfaces (scripted or native). */
	public var parents(default, null):Array<Dynamic> = [];

	/** The parsed interface declaration. */
	var decl:ClassDecl;

	/** True if initialization failed. */
	public var failed:Bool = false;

	/** True once initialized. */
	public var initialized:Bool = false;

	/** True while initializing (guards re-entrancy). */
	public var initializing:Bool = false;

	/**
	 * Creates the runtime interface from its declaration.
	 *
	 * @param decl The parsed interface declaration.
	 * @param module The declaring module, if any.
	 */
	public function new(decl:ClassDecl, ?module:Module) {
		this.name = decl.name;
		this.pack = (module?.pack ?? []);
		this.module = module;
		this.decl = decl;

		path = TypeTools.pathToString(name, pack);

		interp = Type.createInstance(Config.interpClass, []);
	}

	/**
	 * Resolves the interface's parents.
	 *
	 * @param env The world it initializes against, if any.
	 * @param baseInterp An interpreter whose imports/usings/variables are inherited, if any.
	 * @param restore Unused; present for interface-uniform signatures.
	 */
	public function init(?env:Environment, ?baseInterp:Interp, restore:Bool = true):Void {
		interp.environment = env;
		interp.setDefaults(true, baseInterp == null);

		if (baseInterp != null) {
			for (u in baseInterp.usings)
				interp.usings.push(u);
			for (k => i in baseInterp.imports)
				interp.imports.set(k, i);
			for (k => v in baseInterp.variables)
				if (!interp.variables.exists(k))
					interp.variables.set(k, v);
		}

		parents = [];
		if (decl.implement == null)
			return;

		for (t in decl.implement) {
			var parent:Dynamic = ScriptedTools.resolveType(t, module, interp);

			if (parent is ScriptedInterface) {
				var scripted:ScriptedInterface = cast parent;

				if (scripted.module != null && !scripted.initializing && !scripted.initialized && !scripted.failed)
					scripted.module.startType(env, scripted);
			}

			parents.push(parent);
		}
	}

	/**
	 * Member names this interface requires, including everything inherited from parents.
	 *
	 * @return The required (non-static) member names.
	 */
	public function requiredFields():Array<String> {
		var fields:Array<String> = [];

		for (field in decl.fields) {
			if (field.access.contains(AStatic))
				continue;
			if (!fields.contains(field.name))
				fields.push(field.name);
		}

		for (parent in parents) {
			if (!(parent is ScriptedInterface))
				continue;

			for (f in cast(parent, ScriptedInterface).requiredFields())
				if (!fields.contains(f))
					fields.push(f);
		}

		return fields;
	}

	/**
	 * Whether this interface is, or inherits from, `i`.
	 *
	 * @param i The interface to test against.
	 * @return True if this interface is or extends `i`.
	 */
	public function extendsInterface(i:ScriptedInterface):Bool {
		if (i == this)
			return true;

		for (parent in parents) {
			if (parent == i)
				return true;
			if (parent is ScriptedInterface && cast(parent, ScriptedInterface).extendsInterface(i))
				return true;
		}

		return false;
	}

	/** @return A debug string identifying this interface. */
	public function toString():String {
		return 'ScriptedInterface<$path>';
	}

	/** An interface carries no fields. @param field Unused. @return Always false. */
	public function reflectHasField(field:String):Bool {
		return false;
	}

	/** An interface carries no fields. @param field Unused. @return Always null. */
	public function reflectGetField(field:String):Dynamic {
		return null;
	}

	/** An interface carries no fields. @param field Unused. @param value Unused. @return Always null. */
	public function reflectSetField(field:String, value:Dynamic):Dynamic {
		return null;
	}

	/** An interface carries no properties. @param property Unused. @return Always null. */
	public function reflectGetProperty(property:String):Dynamic {
		return null;
	}

	/** An interface carries no properties. @param property Unused. @param value Unused. @return Always null. */
	public function reflectSetProperty(property:String, value:Dynamic):Dynamic {
		return null;
	}

	/** @return The interface's required member names. */
	public function reflectListFields():Array<String> {
		return requiredFields();
	}

	/** No-op: an interface has no state to snapshot. */
	public function snapshot():Void {}
}
