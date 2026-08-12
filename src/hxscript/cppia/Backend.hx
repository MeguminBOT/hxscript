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

package hxscript.cppia;

import hxscript.compile.Report;
import hxscript.compile.Unsupported;
import hxscript.Environment;
import hxscript.Module;
import hxscript.error.Sink;
import haxe.ds.StringMap;

import hxscript.compile.Unit;
import hxscript.compile.Result;
import hxscript.compile.Skip;
import hxscript.syntax.Expr;

/**
 * Compiles hxscript modules to cppia bytecode, which hxcpp loads and JIT-compiles at runtime.
 */
class Backend {
	/** Names the helper compiled bodies call, so it is in the build. A name in bytecode is not a reference. */
	@:keep static var indexing:Class<Dynamic> = hxscript.runtime.Indexing;

	/** Whether this build can compile at all. */
	public static var available(get, never):Bool;

	/** @return Whether this build carries the emitter, which `-D hxscript_cppia` decides. */
	static function get_available():Bool {
		#if hxscript_cppia
		return true;
		#else
		return false;
		#end
	}

	/**
	 * @return One sentence naming why this build cannot compile, or null when it can.
	 *
	 * Only ever a build-time answer here, where the emitter and everything it needs are in the
	 * binary or are not. A host asks rather than assuming, because another backend's answer may be a
	 * runtime one.
	 */
	public static function unavailable():Null<String> {
		#if hxscript_cppia
		return null;
		#else
		return 'this build carries no compiler; add -D hxscript_cppia, -D scriptable and -dce no';
		#end
	}

	#if hxscript_cppia
	/** `Class.method` to record readably while emitting, for inspecting what a hot method became. */
	public static var echoTarget:Null<String> = null;

	/** What `echoTarget` emitted, filled by the last `compile`. */
	public static var echoed:Null<String> = null;

	/**
	 * Dotted paths of every type a module declares.
	 *
	 * @param decls The module's declarations.
	 * @return The class, interface and enum paths it defines.
	 */
	public static function declaredPaths(decls:Array<ModuleDecl>):Array<String> {
		var pack:String = '';
		var paths:Array<String> = [];

		for (decl in decls) {
			switch (decl.d) {
				case DPackage(path):
					pack = path.join('.');
				case DClass(c) | DInterface(c):
					paths.push(pack.length > 0 ? pack + '.' + c.name : c.name);
				case DAbstract(a):
					paths.push(pack.length > 0 ? pack + '.' + a.name : a.name);
				case DEnum(en):
					paths.push(pack.length > 0 ? pack + '.' + en.name : en.name);
				case _:
			}
		}

		return paths;
	}

	/**
	 * Members whose declared type is `Bool`, per class the module defines.
	 *
	 * @param decls The module's declarations.
	 * @return Class path to the set of its member names declared `Bool`, omitting classes with none.
	 */
	public static function booleans(decls:Array<ModuleDecl>):Map<String, Map<String, Bool>> {
		var pack:String = '';
		var found:Map<String, Map<String, Bool>> = [];

		for (decl in decls) {
			switch (decl.d) {
				case DPackage(path):
					pack = path.join('.');
				case DClass(c) | DInterface(c):
					var members:Map<String, Bool> = [];

					for (field in c.fields) {
						var declared:Null<CType> = switch (field.kind) {
							case KVar(v): v.type;
							case KFunction(fn): fn.ret;
						};

						if (isBool(declared))
							members.set(field.name, true);
					}

					if (members.keys().hasNext())
						found.set(pack.length > 0 ? pack + '.' + c.name : c.name, members);
				case _:
			}
		}

		return found;
	}

	/**
	 * Whether a written type annotation is a boolean.
	 *
	 * `Null<Bool>` counts. It is emitted as `Dynamic`, which keeps the null apart from the false, but
	 * what fills it is still an integer slot, so a `true` returned from one arrives boxed as `1`.
	 * Restoring it is the same job and the null passes through untouched.
	 *
	 * @param t The annotation, or null when there was none.
	 * @return Whether it names `Bool` or a nullable one.
	 */
	public static function isBool(t:Null<CType>):Bool {
		if (t == null)
			return false;

		return switch (t) {
			case CTPath(['Bool'], _): true;
			case CTPath(['Null'], params): params != null && params.length == 1 && isBool(params[0]);
			case CTParent(inner) | CTOpt(inner) | CTNamed(_, inner): isBool(inner);
			case _: false;
		}
	}

	/**
	 * Drops modules that name a class which is not going to be there.
	 *
	 * @param accepted The modules that compiled on their own.
	 * @param skipped Receives each module dropped here, with its reason.
	 * @param uses What each module referenced, by module name.
	 * @return The modules that can be emitted together.
	 */
	static function dropDanglingUsers(accepted:Array<Unit>, skipped:Array<Skip>,
			uses:Map<String, Array<String>>):Array<Unit> {
		while (true) {
			var present:Map<String, Bool> = new Map();
			for (input in accepted)
				for (path in declaredPaths(input.decls))
					present.set(path, true);

			var survivors:Array<Unit> = [];
			var dropped:Bool = false;

			for (input in accepted) {
				var missing:String = null;
				var referenced:Array<String> = uses.get(input.name);

				if (referenced != null) {
					for (path in referenced) {
						if (!present.exists(path)) {
							missing = path;
							break;
						}
					}
				}

				if (missing == null) {
					survivors.push(input);
				} else {
					skipped.push({name: input.name, reason: 'uses $missing, which is interpreted'});
					dropped = true;
				}
			}

			accepted = survivors;
			if (!dropped)
				return accepted;
		}
	}
	#end

	/**
	 * Compiles as many of the given modules as it can.
	 *
	 * @param inputs The modules to compile.
	 * @param ambient Types the host makes available without an import.
	 * @param external Scripted classes the host has elsewhere but that are NOT in this batch. A
	 *        module naming one is left interpreted: cppia resolves a class either inside the module
	 *        being loaded or as a host class, and a scripted class in another module is neither, so
	 *        the reference would fail to link and take the batch down with it.
	 * @param statics Bare names the host answers with a static of its own, each written
	 *        `name=owner.path::field`. Compiled code has no interpreter to have them injected into,
	 *        so it reaches them where they really live.
	 * @return The compiled module, and which inputs were compiled or skipped.
	 */
	public static function compile(inputs:Array<Unit>, ?ambient:Array<String>, ?external:Array<String>, ?statics:Array<String>):Result {
		#if hxscript_cppia
		var skipped:Array<Skip> = [];
		var accepted:Array<Unit> = [];

		var uses:Map<String, Array<String>> = new Map();

		for (input in inputs) {
			var trial:Emitter = new Emitter();
			if (ambient != null)
				trial.ambient(ambient);
			if (external != null)
				trial.externals(external);
			if (statics != null)
				trial.ambientStatics(statics);
			for (other in inputs)
				trial.declare(other.decls, other.name);

			try {
				trial.emit(input.decls, input.name);
				trial.finish();
				uses.set(input.name, trial.references());
				accepted.push(input);
			} catch (e:Unsupported) {
				skipped.push({
					name: input.name,
					reason: e.reason,
					origin: e.pos == null ? null : e.pos.origin,
					line: e.pos == null ? 0 : e.pos.line
				});
			}
		}

		accepted = dropDanglingUsers(accepted, skipped, uses);

		if (accepted.length == 0)
			return {bytes: null, compiled: [], skipped: skipped};

		var emitter:Emitter = new Emitter();
		if (ambient != null)
			emitter.ambient(ambient);
		if (external != null)
			emitter.externals(external);
		if (statics != null)
			emitter.ambientStatics(statics);
		for (input in inputs)
			emitter.declare(input.decls, input.name);

		emitter.echoTarget = echoTarget;

		var compiled:Array<String> = [];
		for (input in accepted) {
			emitter.emit(input.decls, input.name);
			compiled.push(input.name);
		}

		if (emitter.echoed != null)
			echoed = emitter.echoed;

		return {bytes: emitter.finish(), compiled: compiled, skipped: skipped};
		#else
		var skipped:Array<Skip> = [];
		for (input in inputs)
			skipped.push({name: input.name, reason: 'built without -D hxscript_cppia'});
		return {bytes: null, compiled: [], skipped: skipped};
		#end
	}

	/**
	 * Whether to turn hxcpp's JIT on before the first module loads.
	 */
	public static var jit:Bool = true;

	/**
	 * Whether to split a batch the loader rejected, instead of giving up on all of it.
	 *
	 * On by default. The cost is extra compiles on a path that is already failing; the benefit is
	 * that one bad class costs one class rather than the whole world's speedup.
	 */
	public static var narrowOnFailure:Bool = true;

	/** Types a script may name without importing them, as full paths. */
	public static var ambient:Array<String> = [];

	/**
	 * Bare names the host answers with a static of its own, each written `name=owner.path::field`.
	 *
	 * The direct replacement for a preset variable. Anything handed to scripts through `Config` is
	 * injected into an interpreter, and compiled code does not have one, so a name that resolved
	 * fine interpreted has to be told where it really lives.
	 */
	public static var statics:Array<String> = [];

	/** Every class compiled so far, by scripted path, across every world. */
	static var built:StringMap<Class<Dynamic>> = new StringMap();

	/** Why each module was left interpreted, by module name. */
	static var refused:StringMap<String> = new StringMap();

	/** Whether the JIT has been switched on. It is process-wide, so this happens at most once. */
	static var jitStarted:Bool = false;

	/** Whether the JIT has already been given up on, so the retry is attempted at most once. */
	static var jitDropped:Bool = false;

	/**
	 * Does this backend's share of compiling a world.
	 *
	 * `Compiler` owns the shape every backend follows, and calls this for the part only cppia knows
	 * how to do.
	 *
	 * Offering the modules together matters: they are declared before any is emitted, so they may
	 * refer to each other, and a class split into its own batch can no longer see the ones it was
	 * written beside.
	 *
	 * @param env The world. Its `compiled` map is set here.
	 * @param modules The modules being offered.
	 * @param report Filled with what happened.
	 */
	public static function run(env:Environment, modules:Array<Module>, report:Report):Void {
		var fresh:Array<Module> = [];

		for (module in modules) {
			if (module == null || module.decls == null)
				continue;

			if (bind(module, env)) {
				for (path in declaredPaths(module.decls))
					report.compiled.push(path);

				continue;
			}

			fresh.push(module);
		}

		if (fresh.length == 0)
			return;

		if (jit && !jitStarted) {
			jitStarted = true;
			cpp.cppia.Host.enableJit(true);
		}

		batch(fresh, env, report, true);
	}

	/**
	 * @param env The world. Its `substituting` flag is set here.
	 * @param report Unused: cppia answers from the world, because a class bound by an earlier call
	 *        still counts even when this one compiled nothing.
	 * @return Whether the world now reaches its scripted classes through their compiled form.
	 */
	public static function substituting(env:Environment, report:Report):Bool {
		env.substituting = anyBound(env);
		return env.substituting;
	}

	/**
	 * Compiles one group of modules together, splitting it if the loader will not take the result.
	 *
	 * @param group The modules to offer together.
	 * @param env The world to bind into.
	 * @param report The report being filled.
	 * @param whole Whether this is the original batch, which is the only place the JIT is worth
	 *        blaming: a fault that survives to a single module is the module's.
	 */
	static function batch(group:Array<Module>, env:Environment, report:Report, whole:Bool):Void {
		if (group.length == 0)
			return;

		var inputs:Array<Unit> = [for (module in group) {name: module.name, decls: module.decls}];
		var result:Result = compile(inputs, ambient, outside(group, env), statics);

		if (result.bytes == null) {
			collect(result, report);
			return;
		}

		var fault:String = load(result, group, env, report);

		if (fault == null) {
			report.bytes += result.bytes.length;
			collect(result, report);
			return;
		}

		if (whole && retryWithoutJit(result, group, env, report))
			return;

		if (group.length == 1 || !narrowOnFailure) {
			for (module in group)
				rejected(module.name, fault, group.length > 1);

			for (module in group)
				report.failed.push({name: module.name, reason: fault});

			return;
		}

		var mid:Int = group.length >> 1;
		batch(group.slice(0, mid), env, report, false);
		batch(group.slice(mid), env, report, false);
	}

	/**
	 * Loads the same bytecode again with the JIT off, once per process.
	 *
	 * @param result The bytecode that was refused.
	 * @param group The modules it holds.
	 * @param env The world to bind into.
	 * @param report The report being filled.
	 * @return Whether the retry loaded.
	 */
	static function retryWithoutJit(result:Result, group:Array<Module>, env:Environment, report:Report):Bool {
		if (!jit || !jitStarted || jitDropped)
			return false;

		jitDropped = true;

		try {
			cpp.cppia.Host.enableJit(false);
		} catch (e:haxe.Exception) {
			return false;
		}

		if (load(result, group, env, report) != null) {
			jit = false;
			return false;
		}

		jit = false;
		collect(result, report);

		Sink.report({
			phase: PJit,
			message: 'this batch loads without the hxcpp JIT and is refused with it on; the JIT is off for the rest of this process',
			hint: 'A JIT fault is cumulative rather than caused by one construct, so there is no module to\n'
			+ 'blame and nothing to fix in a script. Compiled code without the JIT is still much faster\n'
			+ 'than interpreted. Set Compiler.jit to false at startup to skip this retry entirely.',
			fatal: false
		});

		return true;
	}

	/**
	 * Loads a compiled batch and records every class it produced.
	 *
	 * @param result The compiled bytecode and what went into it.
	 * @param offered The modules that went into it.
	 * @param env The world to bind them into.
	 * @param report The report being filled.
	 * @return Null when it loaded, or the loader's complaint.
	 */
	static function load(result:Result, offered:Array<Module>, env:Environment, report:Report):Null<String> {
		var loaded:cpp.cppia.Module;

		try {
			loaded = cpp.cppia.Module.fromData(result.bytes.getData());
			loaded.boot();
		} catch (e:haxe.Exception) {
			return e.message;
		} catch (e:Dynamic) {
			return Std.string(e);
		}

		for (module in offered) {
			if (result.compiled.indexOf(module.name) < 0)
				continue;

			for (path in declaredPaths(module.decls)) {
				var cls:Class<Dynamic> = loaded.resolveClass(path);
				if (cls == null)
					continue;

				built.set(path, cls);
				env.compiled.set(path, cls);
				report.compiled.push(path);
			}
		}

		return null;
	}

	/**
	 * Records why the loader would not take a module, and says so.
	 *
	 * @param name The module's name.
	 * @param fault The loader's complaint.
	 * @param shared Whether the fault was still shared by several modules when it was given up on,
	 *        in which case it names a group rather than a culprit.
	 */
	static function rejected(name:String, fault:String, shared:Bool):Void {
		refused.set(name, fault);

		Sink.report({
			phase: PLoad,
			message: 'the bytecode loader refused $name: $fault',
			hint: shared ? 'Reported against every module in the batch, because narrowing was off. Set\n'
				+ 'Compiler.narrowOnFailure to true to find which one it is.' : 'The module is left interpreted and everything else still runs. The loader names the fault\n'
				+ 'and nothing inside the module, so the construct has to be found by elimination: an\n'
				+ 'assignment or increment through a chain of fields is the usual cause of a Set or\n'
				+ 'increment complaint, and a link complaint means a class this module names is neither in\n'
				+ 'the batch nor a host class.',
			fatal: false
		});
	}

	/**
	 * Moves an attempt's emitter refusals into the report and reports them once.
	 *
	 * Only called for an attempt that got as far as loading, or that produced nothing at all. A batch
	 * that was split has its refusals recounted by its halves, and keeping the parent's would report
	 * each of them twice.
	 *
	 * @param result The attempt.
	 * @param report The report being filled.
	 */
	static function collect(result:Result, report:Report):Void {
		for (entry in result.skipped) {
			refused.set(entry.name, entry.reason);
			report.skipped.push(entry);

			Sink.report({
				phase: PEmit,
				message: 'left interpreted: ' + entry.reason,
				origin: entry.origin,
				line: entry.line,
				excerpt: entry.origin == null || entry.line <= 0 ? null : hxscript.error.Sources.line(entry.origin, entry.line),
				hint: 'A construct with no bytecode spelling is a normal outcome, not a failure: the module\n'
				+ 'keeps running interpreted and everything else still compiles.',
				fatal: false
			});
		}
	}

	/**
	 * The scripted classes a batch must not link directly to.
	 *
	 * @param group The modules being offered.
	 * @param env The world they belong to.
	 * @return The paths to treat as external.
	 */
	static function outside(group:Array<Module>, env:Environment):Array<String> {
		var out:Array<String> = [];
		for (path in built.keys())
			out.push(path);

		var mine:Map<String, Bool> = new Map();
		for (module in group)
			for (path in declaredPaths(module.decls))
				mine.set(path, true);

		for (module in env.modules) {
			if (module == null || module.decls == null)
				continue;

			for (path in declaredPaths(module.decls)) {
				if (!mine.exists(path) && out.indexOf(path) < 0)
					out.push(path);
			}
		}

		return out;
	}

	/**
	 * Hands a world the classes of a module that was compiled for an earlier one.
	 *
	 * @param module The module to check.
	 * @param env The world to bind into.
	 * @return Whether every class it declares was already compiled, and so needs no second pass.
	 */
	static function bind(module:Module, env:Environment):Bool {
		var paths:Array<String> = declaredPaths(module.decls);
		if (paths.length == 0)
			return false;

		for (path in paths) {
			if (!built.exists(path))
				return false;
		}

		for (path in paths)
			env.compiled.set(path, built.get(path));

		return true;
	}

	/**
	 * Whether anything in a world has a compiled form, which is when substitution has to be on.
	 *
	 * @param env The world to weigh.
	 * @return Whether any of its classes has a compiled form.
	 */
	static function anyBound(env:Environment):Bool {
		for (module in env.modules) {
			if (module.decls == null)
				continue;

			for (path in declaredPaths(module.decls)) {
				if (env.compiled.exists(path))
					return true;
			}
		}

		return false;
	}

	/**
	 * @param path A scripted class path.
	 * @return Whether it has a compiled form.
	 */
	public static function isCompiled(path:String):Bool {
		return built.exists(path);
	}

	/**
	 * @param path A scripted class path.
	 * @return Its compiled class, or null when it is interpreted.
	 */
	public static function resolve(path:String):Class<Dynamic> {
		return built.get(path);
	}

	/**
	 * @param name A module name.
	 * @return Why it was left interpreted, or null when it compiled or was never offered.
	 */
	public static function reasonFor(name:String):Null<String> {
		return refused.get(name);
	}

	/**
	 * Forgets every class compiled so far, so the next call compiles from source again.
	 *
	 * For a host that reloads scripts from changed files. A world already holding these classes keeps
	 * them; this only decides what the next compile is offered.
	 */
	public static function reset():Void {
		built = new StringMap();
		refused = new StringMap();
	}
}
