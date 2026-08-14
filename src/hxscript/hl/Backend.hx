/*
 * Copyright (c) 2026 MeguminBOT (hxScript)
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 * DEALINGS IN THE SOFTWARE.
 */

package hxscript.hl;

import hxscript.compile.Unsupported;

import hxscript.Environment;
import hxscript.compile.Report;
import hxscript.compile.Skip;
import hxscript.Module;
#if hxscript_hl
import hxscript.hl.Binding;
import hxscript.hl.Binding.BindingKind;
import hxscript.hl.Loader;
import hxscript.syntax.Expr;
import hxscript.types.ScriptedClass;
#end

/**
 * Compiles hxscript modules to HashLink bytecode, which the VM loads and JIT-compiles at runtime.
 *
 * The counterpart of `Cppia` for the other target that can run a script as its own bytecode. What a
 * compiled function becomes is simpler here: a plain function value, which replaces the interpreted
 * one in the class that declared it. Nothing in the interpreter has to know, and nothing in its hot
 * path changes.
 */
class Backend {
	/**
	 * Types a script may name without importing them, as full paths.
	 *
	 * Declared because it is part of the configuration every backend takes, and a host should not
	 * have to know which one it got. Nothing reads it here, and nothing needs to: a name written the
	 * way a type is, that is not one of the batch's own, is already resolved against the world when
	 * the module loads, so an ambient type costs no configuration on this target.
	 */
	public static var ambient:Array<String> = [];

	/**
	 * Bare names the host answers with a static of its own, written `name=owner.path::field`.
	 *
	 * These do need saying, because a bare name that is neither a local, a field nor a type has
	 * nothing about it to resolve. `Emitter.ambientStatics` reads them the same way the cppia
	 * backend does, so a host configures both targets identically.
	 */
	public static var statics:Array<String> = [];

	/** Whether this build carries the emitter, which `-D hxscript_hl` decides. */
	public static var available(get, never):Bool;

	static function get_available():Bool {
		#if (hl && hxscript_hl)
		return Loader.available;
		#else
		return false;
		#end
	}

	/**
	 * @return One sentence naming why this build cannot compile, or null when it can.
	 *
	 * On HashLink this is not a build-time question the way it is on hxcpp. The define puts the
	 * emitter in; whether it can be used depends on the extension being there, matching, and having
	 * been built for an architecture HashLink can jit for, and those fail differently enough that a
	 * host reporting one of them should not have to guess which.
	 */
	public static function unavailable():Null<String> {
		#if (hl && hxscript_hl)
		return Loader.why();
		#elseif hl
		return 'this build carries no compiler; add -D hxscript_hl';
		#else
		return 'this is not a HashLink build';
		#end
	}

	/**
	 * Does this backend's share of compiling a world.
	 *
	 * `Compiler` owns the shape every backend follows, and calls this for the part only HashLink
	 * knows how to do.
	 *
	 * @param env The world.
	 * @param modules The modules being offered.
	 * @param report Filled with what happened.
	 */
	public static function run(env:Environment, modules:Array<Module>, report:Report):Void {
		#if (hl && hxscript_hl)
		for (module in modules) {
			if (module == null || module.decls == null)
				continue;
			one(module, env, report);
		}
		#end
	}

	/**
	 * @param env The world. Its `substituting` flag is set here.
	 * @param report What this run produced.
	 * @return Whether the world now reaches its scripted classes through their compiled form.
	 */
	public static function substituting(env:Environment, report:Report):Bool {
		#if (hl && hxscript_hl)
		for (path in built.keys()) {
			if (env.compiled.exists(path)) {
				env.substituting = true;
				return true;
			}
		}
		#end

		return report.compiled.length > 0;
	}

	/** HashLink jits everything it loads, so this reads true and setting it changes nothing. */
	public static var jit(get, set):Bool;

	static function get_jit():Bool {
		return true;
	}

	static function set_jit(v:Bool):Bool {
		return true;
	}

	/**
	 * @param path A scripted class path.
	 * @return Whether anything of it compiled.
	 */
	public static function isCompiled(path:String):Bool {
		return holders.exists(path);
	}

	/** @return Nothing: a compiled function replaces the interpreted one inside the class it was in. */
	public static function substitute(path:String):Dynamic {
		return null;
	}

	/** Which classes have at least one compiled function in them. */
	static var holders:Map<String, Bool> = new Map();

	#if (hl && hxscript_hl)
	/**
	 * Compiles one module and binds whatever came out of it.
	 *
	 * A module is emitted whole or not at all, the way the cppia backend does it, because a refusal
	 * part-way through leaves signatures reserved for functions that were never written.
	 *
	 * @param module The module.
	 * @param env The world it belongs to.
	 * @param report Filled with what happened.
	 */
	static function one(module:Module, env:Environment, report:Report):Void {
		var emitter:Emitter = new Emitter();
		emitter.pack = module.pack == null ? '' : module.pack.join('.');
		emitter.ambientStatics(statics);
		emitter.world = function(name:String):Dynamic {
			return hostOwner(name, module, env);
		};

		try {
			emitter.declare(module.decls, module.name);
			emitter.emit(module.decls, module.name);
		} catch (e:Unsupported) {
			report.skipped.push(Skip.from(module.name, e));
			return;
		}

		/**
		 * Statics only. An instance method belongs to the class this module now holds, reached
		 * through its own method table, so there is nothing to hand the world for one; a static
		 * belongs to the class the world already has, which is where its storage still is.
		 */
		var exposed:Array<{path:String, field:String, findex:Int}> = [];

		for (decl in module.decls) {
			switch (decl.d) {
				case DClass(c):
					for (f in c.fields) {
						var findex:Null<Int> = emitter.expose(c.name + '.' + f.name);

						if (findex != null)
							exposed.push({path: pathOf(module, c.name), field: f.name, findex: findex});
					}
				case _:
			}
		}

		if (exposed.length == 0 && emitter.emitted.length == 0)
			return;

		/**
		 * A name nothing answers to refuses the module, rather than leaving a null in the global for
		 * compiled code to use without looking.
		 *
		 * This used to be the other way round, on the reasoning that a null is what an interpreted
		 * script gets for a name that is not there. It is not: the interpreter throws
		 * `Unknown identifier`, and answering `null` instead is a different program. `haxe.Json` on a
		 * host that never indexed it read as null and stringified to nothing, where every other mode
		 * reported that the name was unreachable.
		 *
		 * The owner and not the field, because a field of a resolved owner may legitimately hold
		 * null, and refusing on that would refuse any module naming a host static that starts empty.
		 */
		var unreachable:Null<String> = missingOwner(emitter.bindings, module, env);

		if (unreachable != null) {
			report.skipped.push({name: module.name, reason: 'names ' + unreachable + ', which nothing at runtime answers to'});
			return;
		}

		var built = emitter.finish();
		var bytes:haxe.io.Bytes = built.pack();
		report.bytes += bytes.length;

		/**
		 * The bases are resolved before the load and not after. Where a class's own first field sits
		 * and which entry of the method table an override takes are both read out of the whole chain
		 * while the module is being jitted, so a base that arrives afterwards is one that was never
		 * counted.
		 */
		var at:Array<Int> = [];
		var bases:Array<hl.Type> = [];

		for (link in emitter.links) {
			var found:Dynamic = hostOwner(link.host, module, env);

			if (found == null || !(found is Class)) {
				report.skipped.push({name: module.name, reason: 'extends ' + link.host + ', which nothing at runtime answers to'});
				return;
			}

			at.push(link.at);
			bases.push((cast found : hl.BaseType).__type__);
		}

		var loaded:Null<Loaded> = Loader.load(bytes, at, bases);
		if (loaded == null) {
			report.failed.push({name: module.name, reason: Loader.error() ?? 'the loader gave no reason'});
			return;
		}

		for (binding in emitter.bindings)
			Loader.set(loaded, binding.index, valueFor(binding, module, env));

		for (entry in exposed) {
			var owner:Dynamic = env.resolve(entry.path);
			if (!(owner is ScriptedClass))
				continue;

			var fn:Dynamic = Loader.bind(loaded, entry.findex);
			if (fn == null)
				continue;

			cast(owner, ScriptedClass).reflectSetField(entry.field, fn);

			holders.set(entry.path, true);
			report.compiled.push(entry.path + '.' + entry.field);
		}

		for (made in emitter.emitted)
			install(made, loaded, module, env, report);

		retained.push(loaded);
	}

	/**
	 * Makes a loaded class real: gives it a class value, tells the world where to find it, and
	 * writes down what it replaced so a `super` in one of its bodies can be answered.
	 *
	 * @param made What the emitter wrote for it.
	 * @param loaded The module it came out of.
	 * @param module The scripted module that declared it.
	 * @param env The world to bind it into.
	 * @param report Filled with what happened.
	 */
	static function install(made:Emitted, loaded:Loaded, module:Module, env:Environment, report:Report):Void {
		var shape:Null<hl.Type> = Loader.typeAt(loaded, made.type);
		if (shape == null)
			return;

		var cls:hl.BaseType.Class = classValue(shape, made.path);
		if (cls == null)
			return;

		cls.__constructor__ = Loader.bind(loaded, made.construct);

		var methods:Map<String, Dynamic> = new Map();
		for (name => findex in made.methods) {
			var fn:Dynamic = Loader.bind(loaded, findex);
			if (fn != null)
				methods.set(name, fn);
		}

		var above:Dynamic = made.host == null ? null : hostOwner(made.host, module, env);

		Runtime.replaces(made.path, {
			path: made.path,
			value: cls,
			base: made.base == null ? null : (module.pack == null || module.pack.length == 0 ? made.base : module.pack.join('.') + '.' + made.base),
			host: above == null ? null : (cast above : hl.BaseType).__type__,
			hostClass: above,
			construct: cls.__constructor__,
			methods: methods
		});

		built.set(made.path, cls);
		env.compiled.set(made.path, cast cls);
		holders.set(made.path, true);
		report.compiled.push(made.path);
	}

	/**
	 * Makes the world's own class value for a type this module holds.
	 *
	 * `Type.initClass` is the world's, and using it rather than building one here is what makes
	 * `Type.getClass`, `Type.resolveClass` and `Std.isOfType` answer about a compiled class the same
	 * way they answer about any other.
	 *
	 * @param shape The loaded type.
	 * @param path What to call it.
	 * @return Its class value.
	 */
	@:access(Type)
	static function classValue(shape:hl.Type, path:String):hl.BaseType.Class {
		return Type.initClass(hl.Type.get((null : hl.BaseType.Class)), shape, @:privateAccess path.bytes);
	}

	/** Every class compiled so far, by scripted path, across every world. */
	static var built:Map<String, Dynamic> = new Map();

	/**
	 * Every module loaded so far, held so none of them is ever collected.
	 *
	 * A closure carries a raw pointer into its module's jitted code and no reference back to the
	 * module, so collecting one while a closure from it is still reachable leaves that closure
	 * pointing at freed memory. Nothing can tell when the last such closure is gone, so none of them
	 * is ever released.
	 */
	static var retained:Array<Loaded> = [];

	/**
	 * @param bindings What the emitter asked to have filled.
	 * @param env The world.
	 * @return The first host name whose owner resolves to nothing, or null when they all resolve.
	 */
	static function missingOwner(bindings:Array<Binding>, module:Module, env:Environment):Null<String> {
		for (binding in bindings) {
			if (binding.kind != BHost)
				continue;

			if (hostOwner(binding.owner, module, env) == null)
				return binding.field == '' ? binding.owner : binding.owner + '.' + binding.field;
		}

		return null;
	}

	/**
	 * Finds what a name a script wrote refers to.
	 *
	 * **The module's own imports come first, and leaving them out was a real bug.** A script that
	 * writes `import h2d.Object` names the class `Object` everywhere afterwards, which is what the
	 * interpreter resolves through its import table and what nothing at all answers to as a path. So
	 * every module of a real project bound null for it, and once unresolved names started refusing
	 * rather than binding null, every module of a real project was refused. The corpus never showed
	 * it because its cases import nothing.
	 *
	 * @param owner The name as the script wrote it.
	 * @param module The module that wrote it, whose imports decide what a short name means.
	 * @param env The world.
	 * @return What it refers to, or null when nothing does.
	 */
	static function hostOwner(owner:String, module:Module, env:Environment):Dynamic {
		if (module != null && module.interp != null && module.interp.imports.exists(owner)) {
			var imported:Dynamic = module.interp.imports.get(owner);
			if (imported != null)
				return imported;
		}

		if (env.variables.exists(owner)) {
			var held:Dynamic = env.variables.get(owner);
			if (held != null)
				return held;
		}

		return hxscript.types.TypeTools.resolve(owner, env);
	}

	/**
	 * Finds the value a bound global should be filled with.
	 *
	 * @param binding What the emitter asked for.
	 * @param module The module being compiled.
	 * @param env The world.
	 * @return The value, or null when nothing answers to it.
	 */
	static function valueFor(binding:Binding, module:Module, env:Environment):Dynamic {
		return switch (binding.kind) {
			case BHost: hostValue(binding.owner, binding.field, module, env);
			case BSupport: Emitter.support(binding.field);
			case BConst: binding.value;
			case BOwner: env.resolve(binding.owner);
			case BModule: module.moduleFields;
			case BSite: new hxscript.hl.Runtime.Slot();
		}
	}

	/**
	 * Finds what a script meant by a name the host owns.
	 *
	 * The world is asked first, so a name a host put in scope wins over a type that merely shares
	 * its name, and the type table answers otherwise. A name nothing answers to leaves null in the
	 * global rather than refusing the module, which is the same thing an interpreted script sees
	 * when it names something that is not there.
	 *
	 * @param owner The owner's name, as the script wrote it.
	 * @param field The field's name, or empty to ask for the owner itself, which is what a type used
	 *        as a value wants: `is` and a catch clause name a type rather than anything on one.
	 * @param env The world.
	 * @return The value, or null when nothing answers to it.
	 */
	static function hostValue(owner:String, field:String, module:Module, env:Environment):Dynamic {
		var holder:Dynamic = hostOwner(owner, module, env);
		if (holder == null)
			return null;

		if (field == '')
			return holder;

		var folded:Null<Dynamic> = constantOf(holder, field);
		if (folded != null)
			return folded;

		/**
		 * The property first, then the plain field. `Math.PI` is the case that needs it: it has no
		 * runtime field of that name on every target, and asking only for the field bound null into
		 * the global, so `Math.PI > 3` compiled to a comparison against nothing and answered false.
		 * A wrong answer with nothing said about it, which is the worst shape a gap can take.
		 */
		var read:Dynamic = hxscript.proxy.ReflectProxy.getProperty(holder, field);
		if (read == null)
			read = hxscript.proxy.ReflectProxy.field(holder, field);

		if (read == null)
			read = enumValue(holder, field);

		return read != null ? read : shimmed(owner, holder, field);
	}

	/**
	 * Builds a constructor of an enum the host compiled.
	 *
	 * `haxe.ds.Option.None` is written like a static and is not one, so reflection answers nothing for
	 * it and the global was filled with null. The interpreter builds it rather than reading it, and a
	 * name bound here has to mean the same thing.
	 *
	 * @param holder What the owner resolved to.
	 * @param field The constructor's name.
	 * @return The value, a var-args builder when it takes parameters, or null when this is not one.
	 */
	static function enumValue(holder:Dynamic, field:String):Dynamic {
		/**
		 * Asked inside a `try`, because `getEnumName` is not the same question on every target: hxcpp
		 * answers null for anything that is not an enum, and HashLink throws
		 * `Can't cast $StringTools to hl.Enum`. That took the process down on the first host class a
		 * script named after this was added.
		 */
		var named:Null<String> = try Type.getEnumName(holder) catch (e:Dynamic) null;
		if (named == null)
			return null;

		var names:Array<String> = Type.getEnumConstructs(holder);
		if (names == null)
			return null;

		var at:Int = names.indexOf(field);
		if (at < 0)
			return null;

		/**
		 * A constructor that takes parameters is bound as a builder rather than as a value, which is
		 * what the interpreter binds for the same name. Building one with no arguments is not a
		 * lesser answer, it is a throw at load time, and a throw while a module's globals are being
		 * filled ends the process.
		 *
		 * Whether it takes any is asked the way the interpreter asks: `allEnums` lists exactly the
		 * values that needed no arguments to exist, so a constructor missing from it is one that did.
		 */
		for (made in Type.allEnums(holder)) {
			if (Type.enumConstructor(made) == field)
				return made;
		}

		return Reflect.makeVarArgs(function(args:Array<Dynamic>):Dynamic {
			return Type.createEnumIndex(holder, at, args);
		});
	}

	/**
	 * Finds an emulation for a member the target does not carry.
	 *
	 * `Config.callShims` exists because dead code elimination and `extern inline` leave members with
	 * no runtime form, and the interpreter has consulted it for a long time. Compiled code did not,
	 * so a script calling `StringTools.hex` answered interpreted and threw compiled, which is the
	 * divergence this whole exercise is against: the same source, two answers, decided by a flag.
	 *
	 * Wrapped as a var-args closure because that is what a call site expects. A shim takes its
	 * receiver and an array; a compiled call passes its arguments positionally and knows nothing
	 * about either.
	 *
	 * @param owner The owner's name as the script wrote it.
	 * @param holder What that name resolved to, passed to the shim as its receiver.
	 * @param field The member's name.
	 * @return A callable, or null when nothing emulates it.
	 */
	static function shimmed(owner:String, holder:Dynamic, field:String):Dynamic {
		var shim:Null<(o:Dynamic, args:Array<Dynamic>) -> Dynamic> = hxscript.Config.callShims.get(owner + '.' + field);

		if (shim == null) {
			var named:Null<String> = try Type.getClassName(holder) catch (e:Dynamic) null;
			if (named != null)
				shim = hxscript.Config.callShims.get(named + '.' + field);
		}

		if (shim == null)
			return null;

		return Reflect.makeVarArgs(function(args:Array<Dynamic>):Dynamic {
			return shim(holder, args);
		});
	}

	/**
	 * Reads a constant of a native `enum abstract`.
	 *
	 * **An enum abstract IS its underlying value once compiled**, so `OpBlend.ADD` is a `String` at
	 * every call site and a field of nothing anywhere. Asking the wrapper for a field of that name
	 * therefore answers with nothing, which is how these read as null. The wrapper exists to give the
	 * interpreter something to read them from, and it offers a getter per constant.
	 *
	 * Read once, into the global the name is bound to, which is the same thing the cppia backend
	 * achieves by folding the value into its bytecode: a constant does not change, so resolving it
	 * when the module loads costs nothing afterwards.
	 *
	 * @param holder The type the script named.
	 * @param field The constant's name.
	 * @return Its underlying value, or null when this is not a foldable constant.
	 */
	static function constantOf(holder:Dynamic, field:String):Null<Dynamic> {
		if (Reflect.field(holder, 'isEnum') != true)
			return null;

		var getter:Dynamic = Reflect.field(holder, 'get_' + field);
		if (!Reflect.isFunction(getter))
			return null;

		var boxed:Dynamic = null;

		try {
			boxed = Reflect.callMethod(holder, getter, []);
		} catch (e:haxe.Exception) {
			return null;
		}

		if (boxed == null)
			return null;

		var value:Dynamic = hxscript.types.AbstractTools.isAbstract(boxed) ? boxed.__a : boxed;

		return switch (Type.typeof(value)) {
			case TInt | TFloat | TBool: value;
			case TClass(cls) if (cls == String): value;
			case _: null;
		}
	}

	/** @return The path a class in a module is resolved by. */
	static function pathOf(module:Module, name:String):String {
		var pack:String = module.pack == null ? '' : module.pack.join('.');
		return pack.length > 0 ? pack + '.' + name : name;
	}
	#end
}
