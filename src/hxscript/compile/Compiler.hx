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

import hxscript.Environment;
import hxscript.Module;
#if hxscript_cppia
import hxscript.cppia.Backend;
#elseif hxscript_hl
import hxscript.hl.Backend;
#end

/**
 * Compiles a whole world, and makes the result the thing that runs.
 *
 * Which backend does it is decided by what the build carries, and `Backend` above names whichever it
 * is, so everything here is written once rather than once per target.
 *
 * The shape of compiling a world lives here: refuse when there is no backend, offer every module
 * unless told otherwise, time the work, and report. What differs per target is one call in the
 * middle.
 */
class Compiler {
	/** Whether this build can compile at all. */
	public static var available(get, never):Bool;

	/** @return Whether a backend for this target is in this build. */
	static function get_available():Bool {
		#if (hxscript_cppia || hxscript_hl)
		return Backend.available;
		#else
		return false;
		#end
	}

	/**
	 * Why nothing can be compiled, for a host that wants to say so rather than only act on it.
	 *
	 * Everything here is knowable from `available` plus which target this is; the point is that a
	 * host should not have to know which target this is.
	 *
	 * @return One sentence naming what is wrong and what would fix it, or null when nothing is.
	 */
	public static function unavailable():Null<String> {
		#if (hxscript_cppia || hxscript_hl)
		return Backend.unavailable();
		#elseif hl
		return 'this build carries no compiler; add -D hxscript_hl on HashLink';
		#else
		return 'this build carries no compiler; add -D hxscript_cppia on hxcpp';
		#end
	}

	#if (hxscript_cppia || hxscript_hl)
	/**
	 * Types a script may name without importing them, as full paths.
	 *
	 * Configuration lives here rather than on a backend so a host sets it the same way whichever
	 * one it was built with.
	 */
	public static var ambient(get, set):Array<String>;

	static function get_ambient():Array<String> {
		return Backend.ambient;
	}

	static function set_ambient(v:Array<String>):Array<String> {
		return Backend.ambient = v;
	}

	/** Bare names the host answers with a static of its own, written `name=owner.path::field`. */
	public static var statics(get, set):Array<String>;

	static function get_statics():Array<String> {
		return Backend.statics;
	}

	static function set_statics(v:Array<String>):Array<String> {
		return Backend.statics = v;
	}

	#if hxscript_cppia
	/** Whether to turn the target's JIT on before the first module loads. Cppia only: HashLink always jits. */
	public static var jit(get, set):Bool;

	static function get_jit():Bool {
		return Backend.jit;
	}

	static function set_jit(v:Bool):Bool {
		return Backend.jit = v;
	}

	/**
	 * @param path A scripted class path.
	 * @return Whether it has a compiled form.
	 */
	public static function isCompiled(path:String):Bool {
		return Backend.isCompiled(path);
	}
	#end

	/**
	 * Compiles what it can of a world and binds the results into it.
	 *
	 * @param env The world. Its `compiled` map and `substituting` flag are set by the backend.
	 * @param modules Which of its modules to offer, or null for all of them. Offering them together
	 *        matters: they are declared before any is emitted, so they may refer to each other.
	 * @return What compiled, what did not and why, and how long it took.
	 */
	public static function compile(env:Environment, ?modules:Array<Module>):Report {
		var report:Report = Report.empty();

		if (env == null || !Backend.available)
			return report;

		if (modules == null) {
			modules = [];
			for (module in env.modules)
				modules.push(module);
		}

		var started:Float = haxe.Timer.stamp();
		Backend.run(env, modules, report);
		report.ms = (haxe.Timer.stamp() - started) * 1000;

		report.substituting = Backend.substituting(env, report);
		return report;
	}
	#else
	/**
	 * Does nothing: this build has no compiler. Present so a host need not guard its own call.
	 *
	 * @param env Unused.
	 * @param modules Unused.
	 * @return An empty report.
	 */
	public static function compile(env:Environment, ?modules:Array<Module>):Report {
		return Report.empty();
	}
	#end
}
