package hxscript;

import hxscript.types.*;
import hxscript.types.TypeCollection;

/**
 * A world of modules that resolve against each other. It owns the module set, a combined
 * `TypeCollection` index of every type they declare, and the shared variables handed to each
 * interpreter, and it drives the staged startup (`init` -> `start` -> `startTypes`) across all
 * modules so cross-module references line up.
 */
class Environment {
	/** The modules in this world, keyed by their fully-qualified path. */
	public var modules:Map<String, Module> = [];

	/** The combined index of every type across all modules; rebuilt whenever the module set changes. */
	public var types:TypeCollection;

	/** Variables shared into every module's interpreter at `init`. */
	public var variables:Map<String, Dynamic> = [];

	/**
	 * Wildcard-import results for this world, keyed by package path, so each package resolves once
	 * rather than once per interpreter. Dropped whenever the type index is rebuilt.
	 */
	public var importCache:Map<String, Array<hxscript.runtime.ImportEntry>> = [];

	/** Callbacks run once `start` finishes; returning false removes the callback. */
	public var onInitialized:Array<Map<String, IScriptedType>->Bool> = [];

	#if hxscript_cppia
	/** Native classes the host compiled from this world's scripted ones, keyed by scripted path. */
	public var compiled:Map<String, Class<Dynamic>> = [];

	/** What `booleansOf` has answered so far, including the empty answers. */
	var booleans:Map<String, Map<String, Bool>> = [];

	/**
	 * Whether a compiled class may stand in for the scripted one it was built from.
	 */
	public var substituting:Bool = false;

	/**
	 * Which members of a class this world declares were written `Bool`.
	 *
	 * @param path The class path, as the runtime names it.
	 * @return Its `Bool` members, empty when this world does not declare that class.
	 */
	public function booleansOf(path:String):Map<String, Bool> {
		var known:Map<String, Bool> = booleans.get(path);
		if (known != null)
			return known;

		for (module in modules) {
			if (!module.types.exists(path))
				continue;

			for (declared => members in hxscript.compile.Cppia.booleans(module.decls))
				booleans.set(declared, members);

			break;
		}

		if (!booleans.exists(path))
			booleans.set(path, new Map());

		return booleans.get(path);
	}
	#end

	/**
	 * Creates a world, optionally seeded with modules, and builds the initial type index.
	 *
	 * @param modules Modules to add up front; may be null for an empty world.
	 */
	public function new(?modules:Array<Module>) {
		hxscript.setup.Boot.ensure();

		if (modules != null) {
			for (module in modules)
				this.modules.set(module.path, module);
		}

		rebuildTypes();
	}

	/**
	 * Adds a module and rebuilds the type index.
	 *
	 * @param module The module to add (replaces any existing one at the same path).
	 * @return The added module.
	 */
	public function addModule(module:Module):Module {
		modules.set(module.path, module);
		rebuildTypes();
		return module;
	}

	/**
	 * Removes a module and rebuilds the type index.
	 *
	 * @param module The module to remove.
	 * @return The removed module.
	 */
	public function removeModule(module:Module):Module {
		modules.remove(module.path);
		rebuildTypes();
		return module;
	}

	/**
	 * Looks up a type by its fully-qualified path across all modules.
	 *
	 * @param path The type path to resolve.
	 * @return The matching type, or null if no module declares it.
	 */
	public function resolve(path:String):IScriptedType {
		for (module in modules) {
			if (module.types.exists(path))
				return module.types.get(path);
		}

		return null;
	}

	/**
	 * Runs the full startup across every module in phases (`init` all, then `start` all, then
	 * `startTypes` all) so a module can reference another before either has finished, and finally
	 * fires the `onInitialized` callbacks with the combined type table.
	 */
	public function start():Void {
		var allTypes:Map<String, IScriptedType> = [];

		for (module in modules)
			module.init(this);

		for (module in modules)
			module.start(this);

		for (module in modules) {
			module.startTypes(this);

			for (n => t in module.types)
				allTypes.set(n, t);
		}

		var i:Int = onInitialized.length;
		while (--i >= 0) {
			if (!onInitialized[i](allTypes))
				onInitialized.remove(onInitialized[i]);
		}
	}

	/** Snapshots every module's `@:snapshot` statics so a later reload can restore them. */
	public function snapshot():Void {
		for (module in modules)
			module.snapshot();
	}

	/**
	 * Rebuilds the combined `TypeCollection` from every module's declared types, indexing each by
	 * package, module, path, and compile path.
	 *
	 * @return The freshly built collection (also stored in `types`).
	 */
	public function rebuildTypes():TypeCollection {
		importCache.clear();

		var map:TypeMap = {
			byPackage: [],
			byModule: [],
			byPath: [],
			byCompilePath: [],
			all: []
		};

		/**
		 * Records every type a module declares, so other modules in this environment can name them.
		 *
		 * @param module The module to index.
		 */
		function makeTypeInfo(module:Module) {
			var pack:String = module.pack.join('.');

			for (type in module.types) {
				var k:String = 'class';
				var isInterface:Bool = false;
				var structural:Bool = false;

				if (type is ScriptedEnum)
					k = 'enum';
				else if (type is ScriptedInterface)
					isInterface = true;
				else if (type is ScriptedTypedef) {
					k = 'typedef';
					structural = cast(type, ScriptedTypedef).structural;
				}

				var info:TypeInfo = {
					kind: k,
					module: module.path,
					pack: type.pack,
					name: type.name,
					isInterface: isInterface,
					structural: structural,
				};

				var tp:Array<String> = info.pack.copy();
				tp.push(info.name);

				map.all.push(info);

				map.byCompilePath[tp.join('.')] = [info];
				map.byPath[info.module + (info.module.length == 0 ? '' : '.') + info.name] = [info];

				map.byModule[info.module] ??= [];
				map.byModule[info.module].push(info);

				map.byPackage[pack] ??= [];
				map.byPackage[pack].push(info);
			}
		}

		for (module in modules)
			makeTypeInfo(module);

		return types = new TypeCollection(map);
	}
}
