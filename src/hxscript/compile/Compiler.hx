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

package hxscript.compile;

#if hxscript_cppia
import haxe.ds.StringMap;
import hxscript.Environment;
import hxscript.Module;
import hxscript.compile.Unit;
import hxscript.compile.Result;
import hxscript.error.Sink;
#end

/**
 * Compiles a whole world, and makes the result the thing that runs.
 */
class Compiler {
	/** Whether this build can compile at all, which `-D hxscript_cppia` decides. */
	public static var available(get, never):Bool;

	/** @return Whether the emitter is in this build, which `-D hxscript_cppia` decides. */
	static function get_available():Bool {
		return Cppia.available;
	}

	#if hxscript_cppia
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
	 * Compiles what it can of a world and binds the results into it.
	 *
	 * @param env The world. Its `compiled` map and `substituting` flag are set here.
	 * @param modules Which of its modules to offer, or null for all of them. Offering them together
	 *        matters: they are declared before any is emitted, so they may refer to each other, and
	 *        a class split into its own batch can no longer see the ones it was written beside.
	 * @return What compiled, what did not and why, and how long it took.
	 */
	public static function compile(env:Environment, ?modules:Array<Module>):Report {
		var report:Report = {compiled: [], skipped: [], failed: [], ms: 0, bytes: 0, substituting: false};

		if (env == null || !Cppia.available)
			return report;

		if (modules == null) {
			modules = [];
			for (module in env.modules)
				modules.push(module);
		}

		var fresh:Array<Module> = [];

		for (module in modules) {
			if (module == null || module.decls == null)
				continue;

			if (bind(module, env)) {
				for (path in Cppia.declaredPaths(module.decls))
					report.compiled.push(path);

				continue;
			}

			fresh.push(module);
		}

		if (fresh.length > 0) {
			if (jit && !jitStarted) {
				jitStarted = true;
				cpp.cppia.Host.enableJit(true);
			}

			var started:Float = haxe.Timer.stamp();
			batch(fresh, env, report, true);
			report.ms = (haxe.Timer.stamp() - started) * 1000;
		}

		env.substituting = anyBound(env);
		report.substituting = env.substituting;
		return report;
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
		var result:Result = Cppia.compile(inputs, ambient, outside(group, env), statics);

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

			for (path in Cppia.declaredPaths(module.decls)) {
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
			for (path in Cppia.declaredPaths(module.decls))
				mine.set(path, true);

		for (module in env.modules) {
			if (module == null || module.decls == null)
				continue;

			for (path in Cppia.declaredPaths(module.decls)) {
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
		var paths:Array<String> = Cppia.declaredPaths(module.decls);
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

			for (path in Cppia.declaredPaths(module.decls)) {
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
	#else
	/**
	 * Does nothing: this build has no compiler. Present so a host need not guard its own call.
	 *
	 * @param env Unused.
	 * @param modules Unused.
	 * @return An empty report.
	 */
	public static function compile(env:Dynamic, ?modules:Dynamic):Report {
		return {compiled: [], skipped: [], failed: [], ms: 0, bytes: 0, substituting: false};
	}
	#end
}
