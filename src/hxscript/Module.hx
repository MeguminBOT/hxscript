package hxscript;

import hxscript.runtime.ImportModule;

import hxscript.types.*;
import hxscript.syntax.Parser;
import hxscript.runtime.Interp;
import hxscript.syntax.Expr;
import hxscript.runtime.Reference;
import hxscript.syntax.ExprTools;
import hxscript.types.TypeTools;

/**
 * A single parsed source unit: one script string compiled into a set of scripted types (classes, interfaces,
 * enums, typedefs) plus its module-level fields, all sharing one `Interp`.
 */
class Module {
	/** Per-type-path saved statics, keyed by type path, used to restore `@:snapshot` fields on reload. */
	public static var snapshots:Map<String, Map<String, Dynamic>> = [];

	/** The module's short type name. */
	public var name:String;

	/** Source origin used for error positions (usually the file path). */
	public var origin:String;

	/** The package segments this module lives in. */
	public var pack:Array<String>;

	/** Fully-qualified module path (`pack.name`). */
	public var path(get, never):String;

	/** The parser that produced this module's declarations. */
	public var parser:Parser = new Parser();

	/** The interpreter that runs this module's program and hosts its variables/imports. */
	public var interp:Interp = null;

	/** The parsed declarations, in source order. */
	public var decls:Array<ModuleDecl> = [];

	/** Types declared by this module, keyed by their fully-qualified path. */
	public var types:Map<String, IScriptedType> = [];

	/** Synthetic host class holding the module's top-level fields, or null if it declares none. */
	public var moduleFields:ScriptedClass = null;

	/** Callbacks run once `startTypes` completes; returning false removes the callback. */
	public var onInitialized:Array<Map<String, IScriptedType>->Bool> = [];

	/** Other modules merged into this one at `start` (imports, and cross-file dependencies). */
	public var subModules:Array<Module> = [];

	/** True while `start` is running the module-level program (guards against re-entrant starts). */
	public var starting:Bool = false;

	/** True once the module-level program has finished running. */
	public var started:Bool = false;

	/** The interpreter's variable table (module-level values). */
	public var variables(get, never):Map<String, Dynamic>;

	/** @return The interpreter's variable table. */
	inline function get_variables():Map<String, Dynamic> {
		return interp.variables;
	}

	/**
	 * Creates a module and immediately parses its source.
	 *
	 * @param string The script source to parse.
	 * @param name The module's short type name.
	 * @param pack The package segments the module lives in.
	 * @param origin Source origin used for error positions (usually the file path).
	 */
	public function new(string:String, name:String = 'Module', pack:Array<String>, origin:String = 'hscript'):Void {
		hxscript.setup.Boot.ensure();

		parser.allowTypes = parser.allowJSON = true;
		interp = Type.createInstance(Config.interpClass, [null, this]);

		this.origin = origin;
		this.name = name;
		this.pack = pack;

		parse(string);
	}

	/**
	 * Parses `string` into `decls` and `types`, replacing any previous parse. Parse errors are routed
	 * to `onParsingError` and leave the declarations collected so far in place.
	 *
	 * @param string The script source to parse.
	 * @return The parsed declarations (also stored in `decls`).
	 */
	public function parse(string:String):Array<ModuleDecl> {
		decls.resize(0);
		types.clear();

		hxscript.error.Sources.remember(origin, string);

		try {
			var declList:Array<ModuleDecl> = parser.parseModule(string, origin, pack);
			for (decl in declList) {
				decls.push(decl);

				var type:IScriptedType = loadType(decl);

				if (type != null)
					types.set(TypeTools.pathToString(type.name, pack), type);
			}
		} catch (e:haxe.Exception) {
			hxscript.error.Sink.caught(e, PParse);
			onParsingError(e);
		}

		return decls;
	}

	/**
	 * Builds the runtime type for one declaration. Top-level `DField`s have no type of their own;
	 * they are collected onto a synthetic `<name>_Fields_` host class (created on first field).
	 *
	 * @param decl The module declaration to realize.
	 * @return The created type, or null for declarations that produce no standalone type (e.g. fields).
	 */
	public function loadType(decl):IScriptedType {
		return switch (decl.d) {
			default:
				null;
			case DClass(m):
				new ScriptedClass(m, this);
			case DInterface(m):
				new ScriptedInterface(m, this);
			case DEnum(m):
				new ScriptedEnum(m, this);
			case DTypedef(m):
				new ScriptedTypedef(m, this);
			case DAbstract(m):
				new ScriptedAbstract(m, this);
			case DField(m):
				var fieldsPath:String = TypeTools.pathToString('_$name.${name}_Fields_', pack);
				var t:ScriptedClass = cast types.get(fieldsPath);

				var d:FieldDecl = {
					name: m.name,
					meta: m.meta,
					kind: m.kind,
					access: (m.isPrivate ? [AStatic, APrivate] : [AStatic, APublic])
				};

				if (t == null) {
					var fieldsModule:ClassDecl = {
						name: '${name}_Fields_',
						params: [],
						meta: [],
						fields: [d],
						isExtern: false,
						isPrivate: false,
						implement: null,
						extend: null,
					};

					var cl = new ScriptedClass(fieldsModule, this);
					cl.pack = cl.pack.copy();
					cl.pack.push('_$name');
					cl.path = TypeTools.pathToString(cl.name, cl.pack);

					moduleFields = cl;

					types.set(fieldsPath, cl);
				} else {
					@:privateAccess t.decl.fields.push(d);
				}

				null;
		}
	}

	/**
	 * Seeds the interpreter from `environment` and imports every declared type by name. Enum
	 * constructors (and enum-abstract constants) are additionally imported unqualified, so
	 * same-module code refers to `Foo` rather than `MyEnum.Foo`, matching Haxe.
	 *
	 * @param environment The world whose variables are copied in and against which types resolve; may be null for a standalone module.
	 */
	public function init(?environment:Environment):Void {
		interp.environment = environment;
		setDefaults();

		if (environment != null) {
			for (k => v in environment.variables)
				if (!variables.exists(k))
					variables.set(k, v);
		}

		for (type in types) {
			interp.imports.set(type.name, type);

			if (type is ScriptedEnum) {
				var e:ScriptedEnum = cast type;

				for (i => v in e.constructNames())
					interp.imports.set(v, Reference.REnumValue(e, i));
			} else if (type is ScriptedClass) {
				var c:ScriptedClass = cast type;
				var enumAbstract:Bool = false;
				for (m in @:privateAccess c.decl.meta)
					if (m.name == ':enumAbstract')
						enumAbstract = true;

				if (enumAbstract) {
					for (field in @:privateAccess c.decl.fields)
						if (field.access.contains(AStatic))
							interp.imports.set(field.name, Reference.RProperty(c, field.name));
				}
			}
		}
	}

	/**
	 * Merges each submodule (imports contribute their usings/imports; other dependencies contribute
	 * their main type) and runs the module-level program. Runtime errors are routed to `onProgramError`.
	 *
	 * @param environment The world used to start imported submodules; may be null.
	 */
	public function start(?environment:Environment):Void {
		try {
			if (decls.length == 0) {
				started = true;
				return;
			}

			starting = true;

			for (module in subModules) {
				if (module is ImportModule) {
					module.start(environment);

					for (u in module.interp.usings)
						interp.usings.push(u);
					for (n => i in module.interp.imports)
						interp.imports.set(n, i);
				} else {
					var mainType:IScriptedType = module.types.get(module.path);

					if (mainType != null)
						module.interp.imports.set(mainType.name, mainType);
				}
			}

			interp.canInit = true;
			interp.executeModule(decls, path);

			starting = false;
			started = true;
		} catch (e:haxe.Exception) {
			hxscript.error.Sink.caught(e, PRun, 'module $path');
			onProgramError(e);
		}
	}

	/**
	 * Initializes one type, starting the module first if needed. Re-entrant and idempotent: a type
	 * already initializing, initialized, or failed is returned untouched, and errors mark it failed
	 * (routed to `onTypeError`) rather than propagating.
	 *
	 * @param environment The world the type initializes against; may be null.
	 * @param type The type to initialize.
	 * @return The same `type`, for chaining.
	 */
	public function startType(?environment:Environment, type:IScriptedType):IScriptedType {
		if (type.initializing || type.initialized || type.failed)
			return type;

		if (starting)
			return type;
		if (!started)
			start(environment);

		try {
			type.initializing = true;

			type.init(environment, interp);

			type.initializing = false;
			type.initialized = true;
		} catch (e:haxe.Exception) {
			type.failed = true;
			type.initialized = false;
			type.initializing = false;

			hxscript.error.Sink.caught(e, PType, 'type ${type.name} of module $path');
			onTypeError(e, type);
		}

		return type;
	}

	/**
	 * Initializes the module-level fields (exposing them unqualified) and every declared type, then
	 * fires the `onInitialized` callbacks.
	 *
	 * @param environment The world the types initialize against; may be null.
	 * @return The module's type table.
	 */
	public function startTypes(?environment:Environment):Map<String, IScriptedType> {
		if (moduleFields != null) {
			startType(environment, moduleFields);

			for (field in hxscript.proxy.ReflectProxy.fields(moduleFields))
				interp.imports.set(field, RProperty(moduleFields, field));
		}

		for (type in types)
			startType(environment, type);

		var i:Int = onInitialized.length;
		while (--i >= 0) {
			if (!onInitialized[i](types))
				onInitialized.remove(onInitialized[i]);
		}

		return types;
	}

	/** Saves each type's `@:snapshot` statics into `Module.snapshots` so a later reload can restore them. */
	public function snapshot():Void {
		for (type in types)
			type.snapshot();
	}

	/** Resets the interpreter to its default variables/imports and re-binds `module` to this instance. */
	public function setDefaults():Void {
		interp.setDefaults();

		variables.set('module', this);
	}

	/**
	 * Overridable hook invoked when parsing fails.
	 *
	 * @param e The parse exception.
	 */
	public dynamic function onParsingError(e:haxe.Exception):Void {}

	/**
	 * Overridable hook invoked when the module-level program throws. See `onParsingError` for why it
	 * is empty.
	 *
	 * @param e The runtime exception.
	 */
	public dynamic function onProgramError(e:haxe.Exception):Void {}

	/**
	 * Overridable hook invoked when a type fails to initialize. See `onParsingError` for why it is
	 * empty.
	 *
	 * @param e The exception thrown during initialization.
	 * @param type The type that failed.
	 */
	public dynamic function onTypeError(e:haxe.Exception, type:IScriptedType):Void {}

	/** @return The fully-qualified module path (`pack.name`), or just `name` when the package is empty. */
	function get_path():String {
		var path:String = pack.join('.');

		if (path.length > 0) {
			return ('$path.$name');
		} else {
			return name;
		}
	}
}
