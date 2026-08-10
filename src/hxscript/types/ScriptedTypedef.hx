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
 * A script-declared `typedef`. An alias to a named type resolves to that type; a structural typedef
 * (anonymous structure or function) has no runtime class and erases to `Dynamic`.
 */
@:access(hxscript.runtime.Interp)
class ScriptedTypedef implements IScriptedType {
	/** The typedef's short name. */
	public var name:String;

	/** The module that declares this typedef. */
	public var module:Module;

	/** The typedef's package segments. */
	public var pack:Array<String>;

	/** The typedef's fully-qualified path. */
	public var path:String;

	/** The resolved aliased type, for a non-structural typedef. */
	public var alias:Dynamic;

	/** True for structural (anonymous-structure or function) typedefs, which have no runtime class;
		they are matched by shape (see `structFields`) rather than by identity. */
	public var structural:Bool = false;

	/**
	 * For an anonymous-structure typedef, the names of the fields it requires; null for a function
	 * typedef (which has no matchable shape). Used by `matchesStructure` for `is`/`cast`.
	 */
	public var structFields:Array<String> = null;

	/** The same fields with their annotations, so `matchesStructure` can check field types too. */
	public var structFieldTypes:Array<{name:String, t:CType, ?meta:Metadata}> = null;

	/** The interpreter that resolved this typedef, used to check field types against its imports. */
	var checker:Interp = null;

	/** The parsed typedef declaration. */
	var decl:TypeDecl;

	/** True if initialization failed. */
	public var failed:Bool = false;

	/** True once initialized. */
	public var initialized:Bool = false;

	/** True while initializing (guards re-entrancy). */
	public var initializing:Bool = false;

	/**
	 * Creates the runtime typedef from its declaration.
	 *
	 * @param decl The parsed typedef declaration.
	 * @param module The declaring module, if any.
	 */
	public function new(decl:TypeDecl, ?module:Module) {
		this.name = decl.name;
		this.pack = (module?.pack ?? []);
		this.module = module;
		this.decl = decl;

		path = TypeTools.pathToString(name, pack);
	}

	/**
	 * Resolves the alias: a named type becomes `alias`, a `Map<...>` is specialized to the right map
	 * implementation from its key type, and any other structural shape sets `structural`.
	 *
	 * @param env The world used to resolve the target, if any.
	 * @param baseInterp An interpreter whose imports help resolve the target.
	 * @param restore Unused; present for interface-uniform signatures.
	 * @throws String If the target type is unknown or an unsupported `Map` shape.
	 */
	public function init(?env:Environment, ?baseInterp:Interp, restore:Bool = true):Void {
		alias = null;
		structural = false;

		switch (decl.t) {
			case hxscript.syntax.Expr.CType.CTPath(path, params):
				var fullPath:String = path.join('.');

				if (fullPath == 'Map') {
					if (params == null || params.length < 2)
						throw 'Not enough type parameters for Map';
					else if (params.length > 2)
						throw 'Too many type parameters for Map';

					switch (params[0]) {
						case CTAnon(_):
							alias = haxe.ds.ObjectMap;
						case CTPath(path, _):
							var fullPath:String = path.join('.');

							if (fullPath == 'String') {
								alias = haxe.ds.StringMap;
							} else if (fullPath == 'Int') {
								alias = haxe.ds.IntMap;
							} else {
								var type:TypeInfo = null;
								var r = (TypeTools.resolve(fullPath, env) ?? baseInterp.imports.get(fullPath));
								if (r is Class) {
									type = TypeCollection.main.fromCompilePath(TypeProxy.getClassName(r))[0];
								} else if (r == null) {
									throw hxscript.error.Printer.errorToString(EUnknownType(fullPath));
								}

								if (type?.kind == 'class') {
									alias = haxe.ds.ObjectMap;
								}
							}
						default:
					}

					if (alias == null) {
						var p = new Printer();
						throw 'Map of type <${p.typeToString(params[0])}, ${p.typeToString(params[1])}> is not accepted';
					}
				} else {
					alias = baseInterp.resolve(fullPath);
				}

				if (alias == null)
					throw hxscript.error.Printer.errorToString(EUnknownType(fullPath));

			case CTAnon(fields):
				structural = true;
				structFields = [for (f in fields) f.name];
				structFieldTypes = fields;
				checker = baseInterp;

			default:
				structural = true;
		}
	}

	/**
	 * Whether a value satisfies this typedef's structure: it has every field the typedef requires, each one
	 * matching its annotation. Optional fields (`?x:Int` or `@:optional`) may be absent. Only meaningful for
	 * an anonymous-structure typedef (`structFields` non-null).
	 *
	 * @param value The value to test.
	 * @return True if `value` satisfies the structure.
	 */
	public function matchesStructure(value:Dynamic):Bool {
		if (value == null || structFields == null)
			return false;

		if (checker == null || structFieldTypes == null) {
			for (f in structFields)
				if (!ReflectProxy.hasField(value, f))
					return false;
			return true;
		}

		for (f in structFieldTypes) {
			if (!ReflectProxy.hasField(value, f.name)) {
				if (ExprTools.isOptionalField(f))
					continue;
				return false;
			}
			if (!checker.matchesType(ReflectProxy.field(value, f.name), f.t))
				return false;
		}
		return true;
	}

	/** No-op: a typedef has no state to snapshot. */
	public function snapshot():Void {}
}
