package hxscript.types;

import hxscript.proxy.ReflectProxy;
import hxscript.proxy.TypeProxy;
import hxscript.runtime.Interp;
import hxscript.runtime.Variable;
import hxscript.syntax.Expr;
import hxscript.Environment;
import hxscript.Module;

using StringTools;
using hxscript.types.TypeCollection;

/**
 * The runtime representation of a script-declared `class`. It holds the class's own interpreter
 * (for statics and shared state), resolves its base and interfaces, and implements the reflection
 * and type interfaces so `TypeProxy`/`ReflectProxy` treat it like a native class. Instances
 * are backed by a generated bridge that forwards native calls into this scripted definition.
 */
@:access(hxscript.runtime.Interp)
@:access(hxscript.types.IScriptedInstance)
class ScriptedClass implements IScriptedType implements ICustomReflection implements ICustomClassType {
	/** The class's fully-qualified path. */
	public var path:String;

	/** The class's short name. */
	public var name:String;

	/** The module that declares this class. */
	public var module:Module;

	/** The class's package segments. */
	public var pack:Array<String>;

	/** When true, instance-method errors are caught and reported instead of thrown (see `onInstanceError`). */
	public var safe:Bool = false;

	/** When true, all statics are snapshotted on reload (as if every one were `@:snapshot`). */
	public var snapshotAll:Bool = false;

	/** The class's own interpreter, hosting its statics and initializer. */
	public var interp:Interp;

	/** Instance methods a backend compiled, as binders taking an instance. Null until one fills it. */
	public var compiledMembers:Null<Map<String, Dynamic>> = null;

	/**
	 * Which position each of an instance's slots holds, shared by every instance of this class.
	 *
	 * Null until a backend that wants indexed storage asks for it. The order is whatever the first
	 * instance bound, which is the order the bridge binds fields in and is therefore the same for
	 * every instance of the class.
	 */
	public var slotIndex:Null<Map<String, Int>> = null;

	/** The names, in slot order. */
	public var slotNames:Null<Array<String>> = null;

	/**
	 * Binds one of this class's compiled instance methods to an instance.
	 *
	 * @param name The method.
	 * @param instance What to bind it to.
	 * @return The bound closure, or null when nothing compiled that method.
	 */
	public function boundMember(name:String, instance:Dynamic):Null<Dynamic> {
		if (compiledMembers == null)
			return null;

		var make:Null<Dynamic> = compiledMembers.get(name);
		return make == null ? null : make(instance);
	}

	/** The resolved base (a scripted class or a native class), resolved lazily and cached. */
	public var extending(get, never):Dynamic;

	/** The concrete class used to allocate instances (the base's instance class or the generated bridge). */
	public var instanceClass(get, never):Dynamic;

	/** Resolved `implements` entries: scripted interfaces and native interface classes. */
	public var interfaces(default, null):Array<Dynamic> = [];

	/** Members declared `private`, or null when the class declares none. */
	public var privateFields(default, null):Array<String> = null;

	/** The parsed class declaration. */
	var decl:ClassDecl;

	/** Static variable slots, keyed by name. */
	var __vars:Map<String, Variable> = [];

	/** Cached resolved base type. */
	var _extending:Dynamic = null;

	/** Whether `_extending` has been resolved yet. */
	var _extendingResolved:Bool = false;

	/** True if initialization failed. */
	public var failed:Bool = false;

	/** True once the class has finished initializing. */
	public var initialized:Bool = false;

	/** True while the class is initializing (guards re-entrancy). */
	public var initializing:Bool = false;

	/**
	 * Creates the runtime class from its declaration and gives it a deferring interpreter.
	 *
	 * @param decl The parsed class declaration.
	 * @param module The declaring module, if any.
	 */
	public function new(decl:ClassDecl, ?module:Module) {
		this.name = decl.name;
		this.pack = (module?.pack ?? []);
		this.module = module;
		this.decl = decl;

		path = TypeTools.pathToString(name, pack);

		interp = Type.createInstance(Config.interpClass, []);
		interp.canDefer = true;
	}

	/**
	 * Initializes the class: reads its metadata, evaluates and installs its static fields (restoring
	 * snapshots and deferring initializers that aren't ready yet), and verifies that every `override`
	 * matches an inherited member (and that no non-overriding field shadows one).
	 *
	 * @param env The world the class initializes against, if any.
	 * @param baseInterp An interpreter whose imports/usings/variables are inherited, if any.
	 * @param restore Whether to restore `@:snapshot` statics from a previous run.
	 */
	public function init(?env:Environment, ?baseInterp:Interp, restore:Bool = true):Void {
		_extending = null;
		_extendingResolved = false;

		privateFields = null;
		for (field in decl.fields) {
			if (!field.access.contains(APrivate))
				continue;

			if (privateFields == null)
				privateFields = [];
			privateFields.push(field.name);
		}

		interp.environment = env;
		interp.ownerClass = this;
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

		interp.pushStack(hxscript.runtime.ScriptStack.StackItem.SModule(module?.path ?? name));

		safe = false;
		snapshotAll = false;
		for (meta in decl.meta) {
			safe = (safe || meta.name == ':safe');
			snapshotAll = (snapshotAll || meta.name == ':snapshot');
		}

		var overridingFields:Array<String> = [];
		var knownFields:Array<String> = [];

		for (field in decl.fields) {
			var f:String = field.name;

			if (f == 'new')
				continue;

			if (hxscript.macro.Scripted.ignoreFields.contains(f)) {
				throw 'Field $f reserved for internal use!!! - hxScript';
			} else if (knownFields.contains(f)) {
				throw 'Duplicate class field declaration: $name.$f';
			} else {
				knownFields.push(f);
				if (field.access.contains(AOverride))
					overridingFields.push(f);
			}

			if (!field.access.contains(AStatic))
				continue;

			var l:Variable = {ref: null, access: field.access};

			switch (field.kind) {
				default:
				case KVar(v):
					if (v.get != null) {
						l.get = v.get;
						Interp.noteAccessor(v.get);
					}
					if (v.set != null) {
						l.set = v.set;
						Interp.noteAccessor(v.set);
					}
					if (v.isFinal != null)
						l.isFinal = v.isFinal;
			}

			interp.locals.set(f, l);
		}

		for (field in decl.fields) {
			var f:String = field.name;

			if (f == 'new' || !field.access.contains(AStatic))
				continue;

			switch (field.kind) {
				case KFunction(fun):
					interp.locals.get(f).r = interp.buildFunction(f, fun.args, fun.expr, fun.ret, interp.locals);

				case KVar(v):
					if (restore) {
						var snapshot:Bool = snapshotAll;
						if (!snapshot)
							for (meta in field.meta)
								snapshot = (snapshot || meta.name == ':snapshot');

						if (snapshot && Module.snapshots.exists(path)) {
							var fields:Map<String, Dynamic> = Module.snapshots.get(path);
							if (fields.exists(f)) {
								interp.locals.get(f).r = fields.get(f);
								continue;
							}
						}
					}

					try {
						initField(f, v);
					} catch (d:Defer) {
						var signal = (env?.onInitialized ?? module.onInitialized);

						signal.push(function(_) {
							try {
								initField(f, v);
							} catch (e:haxe.Exception) {
								onExpressionError(e, f, v.expr);
							}

							return false;
						});
					} catch (e:haxe.Exception) {
						onExpressionError(e, f, v.expr);
					}
			}

			__vars.set(f, interp.locals.get(f));
		}

		var foundOverridingFields:Array<String> = [];
		var inheritedFields:Array<String> = [];
		/**
		 * Starts an ancestor's module if it has not run yet, so its field list is readable before this
		 * class's overrides are resolved against it.
		 *
		 * @param extending The class being extended.
		 */
		function overrideFieldCheck(extending:Dynamic) {
			if (extending is ScriptedClass) {
				var extend:ScriptedClass = cast extending;

				if (extend.module != null && !extend.initializing && !extend.initialized && !extend.failed) {
					if (!extend.module.starting && !extend.module.started)
						extend.module.start(env);

					extend.module.startType(env, extend);
				}

				for (field in extend.decl.fields) {
					var f:String = field.name;

					if (f == 'new' || field.access.contains(AStatic))
						continue;

					if (!inheritedFields.contains(f))
						inheritedFields.push(f);

					if (overridingFields.contains(f)) {
						if (!foundOverridingFields.contains(f))
							foundOverridingFields.push(f);
					} else if (knownFields.contains(f)) {
						throw 'Field $f should be declared with \'override\' since it is inherited from superclass ${extend.name}';
					}
				}

				if (extend.extending != null)
					overrideFieldCheck(extend.extending);
			} else {
				var cls = instanceClass;
				if (cls == null)
					return;

				var instanceFields:Array<String> = (cls.instanceFields ?? Type.getInstanceFields(cast cls));
				var inlinedFields:Array<String> = cls.inlinedFields;
				var unexposedFields:Array<String> = cls.unexposedFields;

				for (field in instanceFields) {
					if (hxscript.macro.Scripted.ignoreFields.contains(field))
						continue;

					if (!inheritedFields.contains(field))
						inheritedFields.push(field);

					if (overridingFields.contains(field)) {
						if (inlinedFields?.contains(field)) {
							throw 'Field $field is inlined and cannot be overridden';
						} else if (unexposedFields?.contains(field)) {
							throw 'Field $field is unexposed and cannot be overridden';
						}

						if (!foundOverridingFields.contains(field))
							foundOverridingFields.push(field);
					} else if (knownFields.contains(field)) {
						throw 'Field $field should be declared with \'override\' since it is inherited from superclass ${cls.getBaseClass()}';
					}
				}
			}
		}
		if (decl.extend != null && instanceClass != ScriptedObject) {
			for (field in decl.fields) {
				if (field.name != 'new')
					continue;

				switch (field.kind) {
					case KFunction(fun):
						if (!callsSuper(fun.expr))
							throw 'Missing super constructor call in $name.new';
					default:
				}
			}
		}

		overrideFieldCheck(extending);
		if (foundOverridingFields.length < overridingFields.length) {
			for (f in overridingFields) {
				if (!foundOverridingFields.contains(f))
					throw 'Field $f is declared \'override\' but doesn\'t override any field';
			}
		}

		interfaces = [];
		if (decl.implement != null) {
			for (t in decl.implement) {
				var i:Dynamic = ScriptedTools.resolveInterface(t, module, interp);
				if (i == null)
					continue;

				if (i is ScriptedInterface) {
					var scripted:ScriptedInterface = cast i;

					if (scripted.module != null && !scripted.initializing && !scripted.initialized && !scripted.failed)
						scripted.module.startType(env, scripted);

					for (f in scripted.requiredFields()) {
						if (!knownFields.contains(f) && !inheritedFields.contains(f))
							throw 'Field $f needed by ${scripted.name} is missing';
					}
				}

				interfaces.push(i);
			}
		}
	}

	/**
	 * Whether a name is one of this class's methods rather than one of its variables.
	 *
	 * An instance keeps both in the same slots, so nothing about a slot says which it is. Reflection
	 * has to know: `Reflect.fields` answers with what an instance stores, and a method is not that.
	 *
	 * @param field The name.
	 * @return Whether this class or one it extends declares it as a function.
	 */
	public function declaresMethod(field:String):Bool {
		for (f in decl.fields) {
			if (f.name != field || f.access.contains(AStatic))
				continue;

			return f.kind.match(KFunction(_));
		}

		var ext:Dynamic = extending;
		return (ext is ScriptedClass) ? cast(ext, ScriptedClass).declaresMethod(field) : false;
	}

	/**
	 * The class that declares `field` as private, or null if no class in the chain does.
	 *
	 * @param field The field name.
	 * @return The declaring class, or null.
	 */
	public function privateOwnerOf(field:String):ScriptedClass {
		if (privateFields != null && privateFields.indexOf(field) >= 0)
			return this;

		var ext:Dynamic = extending;
		if (ext is ScriptedClass)
			return cast(ext, ScriptedClass).privateOwnerOf(field);

		return null;
	}

	/**
	 * Whether this class is `other`, or extends it.
	 *
	 * @param other The class to test against.
	 * @return True if this class is or descends from `other`.
	 */
	public function isOrExtends(other:ScriptedClass):Bool {
		var c:ScriptedClass = this;

		while (c != null) {
			if (c == other)
				return true;

			var ext:Dynamic = c.extending;
			c = (ext is ScriptedClass) ? cast ext : null;
		}

		return false;
	}

	/**
	 * Whether this class, or anything it extends, implements `i` (directly or through a parent interface).
	 *
	 * @param i The scripted interface to test for.
	 * @return True if this class satisfies `i`.
	 */
	public function implementsInterface(i:ScriptedInterface):Bool {
		for (own in interfaces) {
			if (own == i)
				return true;
			if (own is ScriptedInterface && cast(own, ScriptedInterface).extendsInterface(i))
				return true;
		}

		var ext:Dynamic = extending;
		if (ext is ScriptedClass)
			return cast(ext, ScriptedClass).implementsInterface(i);

		return false;
	}

	/**
	 * Whether an expression tree contains a `super(...)` call.
	 *
	 * @param e The expression to scan.
	 * @return True if a super-constructor call is present.
	 */
	static function callsSuper(e:Expr):Bool {
		if (e == null)
			return false;

		var found:Bool = false;
		/**
		 * Searches a constructor body for a `super(...)` call.
		 *
		 * @param e The expression to search.
		 */
		function walk(e:Expr):Void {
			if (found || e == null)
				return;

			switch (e.e) {
				case ECall({e: EIdent('super')}, _):
					found = true;
				default:
					ExprTools.iter(e, walk);
			}
		}
		walk(e);

		return found;
	}

	/** Saves this class's `@:snapshot` (or all, if `@:snapshot` on the class) statics into `Module.snapshots`. */
	public function snapshot():Void {
		for (field in decl.fields) {
			if (field.name == 'new' || !field.access.contains(AStatic))
				continue;

			var snapshot:Bool = snapshotAll;
			if (!snapshot)
				for (meta in field.meta)
					snapshot = (snapshot || meta.name == ':snapshot');
			if (!snapshot)
				continue;

			switch (field.kind) {
				case KFunction(_):
				case KVar(_):
					var fields:Map<String, Dynamic> = (Module.snapshots.get(path) ?? []);
					fields.set(field.name, interp.getLocal(field.name));
					Module.snapshots.set(path, fields);
			}
		}
	}

	/** @return The resolved base (scripted class or native class), resolving and caching it on first access. */
	function get_extending():Dynamic {
		if (_extendingResolved)
			return _extending;

		_extendingResolved = true;

		var type:Dynamic = ScriptedTools.resolveType(decl.extend, module, interp);
		return _extending = (type == null ? null : ScriptedTools.resolve(type));
	}

	/** @return The concrete class used to allocate instances: the base's instance class, or the dummy host when there is no base. */
	function get_instanceClass():Dynamic {
		if (extending is ScriptedClass) {
			return cast(extending, ScriptedClass).instanceClass;
		} else if (extending == null) {
			return ScriptedObject;
		} else {
			return extending;
		}
	}

	/** @return The script's own `toString` result if it defines one, else a debug string. */
	public function toString():String {
		if (interp.locals?.exists('toString'))
			return interp.locals.get('toString').r();

		return 'ScriptedClass<$path>';
	}

	/**
	 * Allocates an instance and runs its scripted constructor.
	 *
	 * @param arguments Constructor arguments.
	 * @return The new instance.
	 * @throws String If the class is not initialized.
	 */
	public function typeCreateInstance(arguments:Array<Dynamic>):Dynamic {
		if (!initialized)
			throw 'Type $path is not initialized';

		if (hxscript.debug.Metrics.on)
			hxscript.debug.Metrics.instances++;

		/**
		 * A base Haxe has to construct is constructed in two phases.
		 *
		 * Most bases are rebuilt: the bridge carries a copy of the base's constructor as an ordinary
		 * method, so an empty instance can be allocated and that method run on it whenever the script
		 * says `super(...)`. Some constructors cannot be rebuilt, and those bases get a real Haxe
		 * constructor instead, which can only run as the instance is made.
		 *
		 * So the arguments have to be known first. The script's own `super(...)` arguments are
		 * evaluated with its constructor's parameters bound and no instance in scope, which is legal
		 * because Haxe forbids reaching `this` before `super` anyway; the instance is made with them;
		 * and the rest of the script's constructor runs afterwards with the `super` call dropped, so
		 * those arguments are evaluated once rather than twice.
		 */
		if (Reflect.field(instanceClass, '__nativeSuper') == true) {
			var inst:IScriptedInstance = Type.createInstance(instanceClass, superArguments(arguments));
			inst.__scriptConstruct(this, arguments);
			return inst;
		}

		var inst:IScriptedInstance = Type.createEmptyInstance(instanceClass);
		inst.__scriptConstruct(this, arguments);
		return inst;
	}

	/**
	 * Works out what to hand the base's real constructor.
	 *
	 * The script's constructor is read for the `super(...)` it opens with, and everything up to and
	 * including that call's arguments is evaluated with the constructor's own parameters bound and
	 * nothing else. There is no instance yet, and there cannot be: this is what decides how to make
	 * one.
	 *
	 * @param arguments What the script's constructor was called with.
	 * @return What the base's constructor should be called with.
	 */
	function superArguments(arguments:Array<Dynamic>):Array<Dynamic> {
		var found:Null<FunctionDecl> = null;

		for (field in decl.fields)
			if (field.name == 'new')
				switch (field.kind) {
					case KFunction(fun): found = fun;
					case _:
				}

		/**
		 * A class declaring no constructor of its own, or one that never calls `super`, gets the base
		 * built with no arguments. That is what Haxe does with an omitted `super()` too, and a base
		 * whose constructor needs arguments will say so itself.
		 */
		if (found == null)
			return [];

		var opening:Null<{before:Array<Expr>, args:Array<Expr>}> = ScriptedTools.opensWithSuper(found.expr);
		if (opening == null)
			return [];

		var body:Array<Expr> = opening.before.copy();
		body.push(({e: EArrayDecl(opening.args), pos: found.expr.pos} : Expr));

		var evaluate:Dynamic = interp.buildFunction('__superArguments', found.args, ({e: EBlock(body), pos: found.expr.pos} : Expr), null,
			interp.locals);

		var given:Dynamic = Reflect.callMethod(null, evaluate, arguments);
		return (given is Array) ? (given : Array<Dynamic>) : [];
	}

	/**
	 * Allocates an instance without running any constructor.
	 *
	 * @return The uninitialized instance.
	 * @throws String If the class is not initialized.
	 */
	public function typeCreateEmptyInstance():Dynamic {
		if (!initialized)
			throw 'Type $path is not initialized';

		return Type.createEmptyInstance(instanceClass);
	}

	/** @return Null; a scripted class has no separate native class object. */
	public function typeGetClass():Dynamic {
		return null;
	}

	/** @return The static field names (this class's own statics). */
	public function typeGetClassFields():Array<String> {
		var fields:Array<String> = [for (loc => _ in interp.locals) loc];
		return fields;
	}

	/** @return The instance field names, gathered up the whole class/base chain. */
	public function typeGetInstanceFields():Array<String> {
		var fields:Array<String> = [];

		/**
		 * Collects a class's instance field names, walking up through its ancestors.
		 *
		 * @param c The class or instance to collect from.
		 */
		function getFields(c:Dynamic) {
			if (c is ScriptedClass) {
				for (field in cast(c, ScriptedClass).decl.fields) {
					var f:String = field.name;
					if (f == 'new' || field.access.contains(AStatic))
						continue;
					if (!fields.contains(f))
						fields.push(f);
				}

				var instance = c.instanceClass;
				if (instance != ScriptedClass)
					getFields(instance);

				if (c.extending != null) {
					getFields(c.extending);
				}
			} else if (c is Class) {
				for (f in Type.getInstanceFields(c)) {
					if (!fields.contains(f) && !hxscript.macro.Scripted.ignoreFields.contains(f))
						fields.push(f);
				}
			}
		}

		getFields(this);

		return fields;
	}

	/** Reflection over statics: whether a static field exists. @param field The field name. @return True if present. */
	public function reflectHasField(field:String):Bool {
		return (__vars.exists(field));
	}

	/** Reflection over statics: read a static field. @param field The field name. @return Its value, or null. */
	public function reflectGetField(field:String):Dynamic {
		return (__vars.exists(field) ? __vars.get(field).r : null);
	}

	/**
	 * Reflection over statics: write a static field.
	 *
	 * @param field The field name.
	 * @param value The value to store.
	 * @return The stored value, or null if the field doesn't exist.
	 */
	public function reflectSetField(field:String, value:Dynamic):Dynamic {
		return (__vars.exists(field) ? __vars.get(field).r = value : null);
	}

	/** Reflection over statics: read a static property via its getter. @param property The property name. @return Its value, or null. */
	public function reflectGetProperty(property:String):Dynamic {
		return (__vars.exists(property) ? interp.getLocal(property, __vars) : null);
	}

	/**
	 * Reflection over statics: write a static property via its setter.
	 *
	 * @param property The property name.
	 * @param value The value to store.
	 * @return The stored value, or null if the property doesn't exist.
	 */
	public function reflectSetProperty(property:String, value:Dynamic):Dynamic {
		return (__vars.exists(property) ? interp.setLocal(property, value, __vars) : null);
	}

	/**
	 * Evaluates a field's initializer and binds it the way a local `var` is bound.
	 *
	 * Goes through `Interp.bindDeclared` so a field declared with an abstract type boxes and records
	 * its type, exactly as the identical local does. Assigning straight into `r` skipped both, which
	 * is why an abstract-typed field's methods and operators were unreachable while a local's worked.
	 *
	 * @param f The field name.
	 * @param v The field's declaration.
	 */
	function initField(f:String, v:VarDecl):Void {
		var value:Dynamic = (v.expr == null) ? null : interp.exprReturn(v.expr, v.type);
		var slot:Variable = interp.locals.get(f);
		var bound:Variable = interp.bindDeclared(value, v.type);

		slot.r = bound.r;
		slot.a = bound.a;
		if (bound.t != null)
			slot.t = bound.t;
	}

	/**
	 * The declared type of a static method's first parameter, for static-extension resolution.
	 *
	 * @param name The static method's name.
	 * @return The first parameter's declared type, or null when it is absent, unannotated, or not a
	 *         static function at all.
	 */
	public function staticArgType(name:String):Null<CType> {
		for (field in decl.fields) {
			if (field.name != name || !field.access.contains(AStatic))
				continue;
			switch (field.kind) {
				case KFunction(fun):
					return (fun.args.length > 0) ? fun.args[0].t : null;
				case KVar(_):
					return null;
			}
		}
		return null;
	}

	/** @return Every field name reflection can see on this instance. */
	public function reflectListFields():Array<String> {
		return [for (field in __vars.keys()) field];
	}

	/**
	 * Overridable hook: a static field's initializer threw. Defaults to tracing.
	 *
	 * @param error The thrown value.
	 * @param field The field being initialized.
	 * @param expr The initializer expression, if available.
	 */
	public dynamic function onExpressionError(error:Dynamic, field:String, ?expr:Expr):Void {
		trace('Error on field $field of $path:
' + describeError(error));
	}

	/**
	 * Overridable hook: an instance method threw while the class is in `safe` mode. Defaults to tracing.
	 *
	 * @param error The thrown value.
	 * @param fun The method that threw.
	 * @param instance The instance it ran on, if available.
	 */
	public dynamic function onInstanceError(error:Dynamic, fun:String, ?instance:IScriptedInstance):Void {
		trace('Error on function $fun of $path:
' + describeError(error));
	}

	/**
	 * Renders a thrown value with its call stack when it has one.
	 *
	 * `Script` and `Module` report program failures with `haxe.Exception.details()`, which includes
	 * the frames; these two hooks interpolated the value instead, so an error inside a field
	 * initializer or a method arrived with no stack at all, the least debuggable place to lose it.
	 *
	 * @param error The thrown value.
	 * @return The rendered error, with frames when available.
	 */
	public static function describeError(error:Dynamic):String {
		var ex:haxe.Exception = (error is haxe.Exception) ? cast error : null;
		return (ex != null) ? ex.details() : Std.string(error);
	}
}
