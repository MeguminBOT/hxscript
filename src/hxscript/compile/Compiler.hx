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
import hxscript.compile.CppiaInput;
import hxscript.compile.CppiaResult;
#end

/**
 * Compiles a whole world, and makes the result the thing that runs.
 *
 * `Cppia.compile` turns declarations into bytecode and stops there, which leaves an embedder holding
 * several steps that all have to be right: load the module, resolve every class it declared, record
 * each against the world it came from, and turn substitution on. Miss the recording and nothing
 * errors -- the compile succeeded, the module loaded, the class is real, and every script still runs
 * interpreted while the host reports otherwise. This does those steps.
 *
 * One call per world:
 *
 * ```haxe
 * Compiler.ambient = ['game.Player', 'game.World'];
 * Compiler.statics = ['player=game.Player::current'];
 *
 * var report = Compiler.compile(env);
 * trace('${report.compiled.length} compiled, ${report.skipped.length} interpreted');
 * ```
 *
 * Safe to call on a world with nothing left to do, and safe to call again after a reload: classes
 * compiled for an earlier world are handed to the new one rather than compiled a second time, which
 * they could not be anyway -- offered again in a batch of their own they can no longer see the
 * classes they were compiled beside, so they would be refused and reported as interpreted while
 * their compiled form sat right there.
 *
 * Nothing here happens on its own. The library never decides to compile something; a host calls
 * this when it wants it, on the worlds it wants it for.
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
	 *
	 * It is a process-wide switch rather than a per-module one, so it is set once and never unset.
	 * Leaving it on is the usual choice: it costs nothing measurable at load time and is worth
	 * several times again on a script's own logic.
	 */
	public static var jit:Bool = true;

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

	/**
	 * Compiles what it can of a world and binds the results into it.
	 *
	 * @param env The world. Its `compiled` map and `substituting` flag are set here.
	 * @param modules Which of its modules to offer, or null for all of them. Offering them together
	 *        matters: they are declared before any is emitted, so they may refer to each other, and
	 *        a class split into its own batch can no longer see the ones it was written beside.
	 * @return What compiled, what did not and why, and how long it took.
	 */
	public static function compile(env:Environment, ?modules:Array<Module>):CompileReport {
		var report:CompileReport = {compiled: [], skipped: [], ms: 0, substituting: false};

		if (env == null || !Cppia.available)
			return report;

		if (modules == null) {
			modules = [];
			for (module in env.modules)
				modules.push(module);
		}

		var fresh:Array<Module> = [];
		var inputs:Array<CppiaInput> = [];

		for (module in modules) {
			if (module == null || module.decls == null)
				continue;

			if (bind(module, env)) {
				for (path in Cppia.declaredPaths(module.decls))
					report.compiled.push(path);
				continue;
			}

			fresh.push(module);
			inputs.push({name: module.name, decls: module.decls});
		}

		if (inputs.length > 0) {
			if (jit && !jitStarted) {
				jitStarted = true;
				cpp.cppia.Host.enableJit(true);
			}

			var started:Float = haxe.Timer.stamp();

			// Anything scripted that this batch does not itself declare is outside it, and a module
			// naming one has to stay interpreted: cppia links a class either inside the module being
			// loaded or as a host class, and a scripted class elsewhere is neither.
			//
			// Two sources, and the second is easy to miss. Classes already compiled for another world
			// are obviously outside. So is every other module of *this* world when only a subset was
			// offered, which is the normal case: a state re-entered later brings its own batch, and
			// the classes it was written beside are not in it. Leaving those out does not make them
			// reachable, it only stops the compiler knowing they are not, so instead of refusing the
			// module it emits a direct link that resolves to nothing and rejects the whole batch at
			// load with a bad link naming a class that plainly exists.
			var outside:Array<String> = [];
			for (path in built.keys())
				outside.push(path);

			var mine:Map<String, Bool> = new Map();
			for (input in inputs)
				for (path in Cppia.declaredPaths(input.decls))
					mine.set(path, true);

			for (module in env.modules) {
				if (module == null || module.decls == null)
					continue;

				for (path in Cppia.declaredPaths(module.decls)) {
					if (!mine.exists(path) && outside.indexOf(path) < 0)
						outside.push(path);
				}
			}

			var result:CppiaResult = Cppia.compile(inputs, ambient, outside, statics);
			report.ms = (haxe.Timer.stamp() - started) * 1000;

			for (entry in result.skipped) {
				refused.set(entry.name, entry.reason);
				report.skipped.push(entry);
			}

			if (result.bytes != null)
				load(result.bytes, fresh, result, env, report);
		}

		env.substituting = anyBound(env);
		report.substituting = env.substituting;
		return report;
	}

	/**
	 * Loads a compiled batch and records every class it produced.
	 *
	 * @param bytes The compiled module.
	 * @param offered The modules that went into it.
	 * @param result What the compiler said about them.
	 * @param env The world to bind them into.
	 * @param report The report being filled.
	 */
	static function load(bytes:haxe.io.Bytes, offered:Array<Module>, result:CppiaResult, env:Environment, report:CompileReport):Void {
		var loaded:cpp.cppia.Module = cpp.cppia.Module.fromData(bytes.getData());
		loaded.boot();

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
	}

	/**
	 * Hands a world the classes of a module that was compiled for an earlier one.
	 *
	 * Skipping the work is not the same as skipping the binding. `built` outlives any one world, so a
	 * world made after a reload would otherwise find everything already compiled and be handed
	 * nothing: the classes exist, every report says so, and none of them is what runs, because the
	 * interpreter reads the world's own map and that map is empty.
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
	 * The hazard is a class existing both ways at once, the two halves disagreeing about statics and
	 * identity. What rules that out is not every class being compiled, it is every reference going
	 * the same way, including from the classes still interpreted. So this asks whether there is
	 * anything to substitute at all -- and a module left interpreted has nothing to substitute to,
	 * since the emitter refuses whatever names it.
	 *
	 * Read from the world's own map rather than from `built`. The two differ exactly when a world was
	 * handed nothing because the work was done for a previous one, and answering from `built` there
	 * announces a substitution that cannot happen.
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
	public static function compile(env:Dynamic, ?modules:Dynamic):CompileReport {
		return {compiled: [], skipped: [], ms: 0, substituting: false};
	}
	#end
}

/** What one call to `Compiler.compile` did. */
@:structInit
class CompileReport {
	/** Scripted paths that have a compiled form, including ones bound from an earlier world. */
	public var compiled:Array<String>;

	/** Modules left to the interpreter, each with the reason. */
	public var skipped:Array<{name:String, reason:String}>;

	/** How long compiling took, in milliseconds. Zero when there was nothing to do. */
	public var ms:Float;

	/** Whether the world now reaches its scripted classes through their compiled form. */
	public var substituting:Bool;
}
