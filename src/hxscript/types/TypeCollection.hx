package hxscript.types;

#if (!macro)
import hxscript.macro.Index;
import hxscript.Environment;
#end

/** Compile-time metadata about one type, used to resolve imports and names without runtime reflection. */
typedef TypeInfo = {
	/** The type kind (`class`, `enum`, `abstract`, `typedef`). */
	var kind:String;

	/** The type's short name. */
	var name:String;

	/** The module the type lives in. */
	var module:String;

	/** The package segments. */
	var pack:Array<String>;

	/** For an abstract, the info of its `_Impl_` class. */
	var ?abstractImpl:TypeInfo;

	/** For a typedef, the info of its aliased type. */
	var ?typedefType:TypeInfo;

	/** Whether the type is an interface. */
	var ?isInterface:Bool;

	/** Whether the type is a structural (anonymous-shape) typedef that erases to `Dynamic`. */
	var ?structural:Bool;

	/**
	 * How many arguments the constructor declares, and how many of those are required.
	 */
	var ?ctorArgs:Int;

	var ?ctorRequired:Int;
}

/** The type index, keyed several ways so lookups by path, module, package, or compile path are direct. */
typedef TypeMap = {
	/** Types keyed by compile path (`pack.Name`). */
	var byCompilePath:Map<String, Array<TypeInfo>>;

	/** Types keyed by package. */
	var byPackage:Map<String, Array<TypeInfo>>;

	/** Types keyed by module path. */
	var byModule:Map<String, Array<TypeInfo>>;

	/** Types keyed by full path (`module.Name`). */
	var byPath:Map<String, Array<TypeInfo>>;

	/** Every type, flat. */
	var all:Array<TypeInfo>;
}

/**
 * An index of known types. The compile-time-built `main` collection covers every type in the host
 * build (so scripts can name them without extra reflection cost); an `Environment` builds additional
 * collections for its scripted types.
 */
class TypeCollection {
	#if (!macro)
	/** The collection of every type in the host build, generated at compile time. */
	public static var main(default, never):TypeCollection = new TypeCollection(Index.build());

	/** The backing index. */
	public var types:TypeMap;

	/**
	 * Wraps a prebuilt type map.
	 *
	 * @param map The index to wrap; may be null.
	 */
	public function new(?map:TypeMap) {
		this.types = map;
	}

	/**
	 * Looks up a type by full path (`module.Name`), optionally retrying as a same-named type inside a
	 * module of that path.
	 *
	 * @param path The full path.
	 * @param moduleCheck Whether to retry treating `path` as a module holding a same-named type.
	 * @return The matching infos, or null.
	 */
	public inline function fromPath(path:String, moduleCheck:Bool = true):Array<TypeInfo> {
		var t = types.byPath.get(path);

		if (t == null && moduleCheck) {
			var at:Int = path.lastIndexOf('.');
			var name:String = at < 0 ? '.$path' : path.substring(at);

			return fromPath(path + name, false);
		}

		return t;
	}

	/**
	 * Looks up every type in a module.
	 *
	 * @param path The module path.
	 * @return The module's types, or null.
	 */
	public inline function fromModule(path:String):Array<TypeInfo> {
		return types.byModule.get(path);
	}

	/**
	 * Looks up every type in a package.
	 *
	 * @param path The package.
	 * @return The package's types, or null.
	 */
	public inline function fromPackage(path:String):Array<TypeInfo> {
		return types.byPackage.get(path);
	}

	/**
	 * Looks up a type by compile path (`pack.Name`).
	 *
	 * @param path The compile path.
	 * @return The matching infos, or null.
	 */
	public inline function fromCompilePath(path:String):Array<TypeInfo> {
		return types.byCompilePath.get(path);
	}

	/**
	 * Builds a type's compile path.
	 *
	 * @param info The type info.
	 * @return The `pack.Name` compile path.
	 */
	public static function compilePath(info:TypeInfo):String {
		var typePath:Array<String> = info.pack.copy();
		typePath.push(info.name);
		return typePath.join('.');
	}

	/**
	 * Builds a type's full path.
	 *
	 * @param info The type info.
	 * @return The `module.Name` full path.
	 */
	public static function fullPath(info:TypeInfo):String {
		return (info.module + (info.module.length > 0 ? '.' : '') + info.name);
	}

	/**
	 * Resolves a type info to its runtime type, following a typedef to its target.
	 *
	 * @param info The type info to resolve.
	 * @param env An optional world to consult for scripted types.
	 * @return The runtime type, or null.
	 */
	public static function resolve(info:TypeInfo, ?env:Environment):Dynamic {
		if (info.typedefType != null)
			return TypeTools.resolve(compilePath(info.typedefType), env);

		/**
		 * An enum is asked for as an enum, because the index knows it is one and the runtime does not
		 * answer consistently: on HashLink `Type.resolveClass` hands back something for an enum path
		 * that is neither null nor the enum, so `haxe.ds.Option.Some` became a field of an object with
		 * no fields. Nothing else can tell the two apart at that point; this can, and it is free.
		 */
		if (info.kind == 'enum') {
			var found:Dynamic = hxscript.proxy.TypeProxy.resolveEnum(compilePath(info));
			if (found != null)
				return found;
		}

		return TypeTools.resolve(compilePath(info), env);
	}
	#end
}
