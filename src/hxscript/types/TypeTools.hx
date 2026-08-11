package hxscript.types;

import hxscript.Environment;
import hxscript.proxy.TypeProxy;

using hxscript.types.TypeCollection;

/** Path and type-resolution helpers shared by the parser, interpreter and emitter. */
class TypeTools {
	/**
	 * Whether a value is a class, portably.
	 *
	 * `v is Class` is false for python's builtins, so dispatch leaning on it skips every branch meant
	 * for a class there. Only python widens the test: on neko `Type.getClassName` answers for
	 * instances too, and widening it there breaks every call that goes through this.
	 *
	 * @param v The value to test.
	 * @return True if it is a class.
	 */
	public static inline function isClass(v:Dynamic):Bool {
		#if python
		return v != null && ((v is Class) || Type.getClassName(cast v) != null);
		#else
		return v is Class;
		#end
	}

	/**
	 * Joins a package and name into a dotted path.
	 *
	 * @param name The type or field name.
	 * @param pack The package segments; may be null or empty.
	 * @return `pack.name`, or just `name` when the package is empty.
	 */
	public static inline function pathToString(name:String, ?pack:Array<String>):String {
		var pack:String = (pack?.join('.') ?? '');
		return (pack.length > 0 ? '$pack.$name' : name);
	}

	/**
	 * Heuristic for whether an identifier names a type (starts with an upper-case letter).
	 *
	 * @param id The identifier.
	 * @return True if it looks like a type name.
	 */
	public static inline function isTypeIdentifier(id:String):Bool {
		return (id.charAt(0) == id.charAt(0).toUpperCase());
	}

	/**
	 * Resolves a dotted path to a runtime type, trying (in order) a scripted type in the environment,
	 * an abstract, a class, then an enum. Rewrites the path to its compile path first if the
	 * collection knows it.
	 *
	 * @param path The type path to resolve.
	 * @param env An optional world to consult for scripted types.
	 * @return The resolved type, or null if unknown.
	 */
	public static function resolve(path:String, ?env:Environment):Dynamic {
		var hops:Int = 0;

		while (hops < TYPEDEF_DEPTH) {
			var info = (TypeCollection.main.fromPath(path) ?? TypeCollection.main.fromCompilePath(path) ?? env?.types.fromPath(path));
			if (info == null)
				break;

			var found:TypeInfo = info[0];
			var next:String = TypeCollection.compilePath(found.typedefType ?? found);
			if (found.typedefType == null || next == path) {
				path = next;
				break;
			}

			path = next;
			hops++;
		}

		var type:Dynamic = env?.resolve(path);
		type ??= AbstractTools.resolve(path);
		type ??= TypeProxy.resolveClass(path);
		type ??= TypeProxy.resolveEnum(path);

		return type;
	}

	/** How many typedef hops `resolve` follows before giving up, so a cycle cannot spin. */
	static inline var TYPEDEF_DEPTH:Int = 8;

	/**
	 * Lists the importable types at a path (a package's types, or a single module/type). Classes,
	 * enums, and abstracts pass through; supported typedefs are included, while unsupported ones warn
	 * (unless suppressed).
	 *
	 * @param path The package, module, or type path.
	 * @param fromPack Whether `path` names a package (list all its types) rather than a single module/type.
	 * @param canIgnoreWarnings Suppress the "unsupported import" warnings.
	 * @param collection The collection to search; defaults to the global one.
	 * @return The importable type infos, or null if the path is unknown.
	 */
	public static inline function listTypes(path:String, fromPack:Bool = false, canIgnoreWarnings:Bool = false, ?collection:TypeCollection):Array<TypeInfo> {
		var typeInfos:Array<TypeInfo> = [];

		collection ??= TypeCollection.main;
		if (fromPack) {
			typeInfos = collection.fromPackage(path);
		} else {
			typeInfos = (collection.fromModule(path) ?? collection.fromPath(path) ?? collection.fromCompilePath(path));
		}

		if (typeInfos == null)
			return null;

		var mainAttraction:Dynamic = (collection.fromPath(path) ?? collection.fromCompilePath(path));
		var types:Dynamic = [];
		for (type in typeInfos) {
			if (type.kind == 'class' || type.kind == 'enum' || type.kind == 'abstract') {
				types.push(type);
			} else if (mainAttraction != null && type == mainAttraction[0] && !canIgnoreWarnings) {
				if (type.kind == 'typedef') {
					if (type.typedefType != null) {
						types.push(type);
					} else if (!(type.structural == true)) {
						trace('(${type.fullPath()}) this typedef\'s target type is unsupported');
					}
					continue;
				}

				trace('(${type.fullPath()}) ${type.kind} import is currently unsupported');
			}
		}

		return types;
	}

	/**
	 * Like `listTypes`, but searches several collections and concatenates the results.
	 *
	 * @param path The package, module, or type path.
	 * @param fromPack Whether `path` names a package rather than a single module/type.
	 * @param canIgnoreWarnings Suppress the "unsupported import" warnings.
	 * @param collections The collections to search (nulls are skipped).
	 * @return The combined type infos, or null if none matched.
	 */
	public static inline function listTypesEx(path:String, fromPack:Bool = false, canIgnoreWarnings:Bool = false,
			collections:Array<TypeCollection>):Array<TypeInfo> {
		var types:Array<TypeInfo> = null;

		for (collection in collections) {
			if (collection == null)
				continue;

			var newTypes:Array<TypeInfo> = listTypes(path, fromPack, canIgnoreWarnings, collection);
			if (newTypes == null)
				continue;

			types = (types == null ? newTypes : types.concat(newTypes));
		}

		return types;
	}
}
