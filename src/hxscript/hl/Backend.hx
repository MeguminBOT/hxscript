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
	 * have to know which one it got. Nothing reads it yet: a compiled function cannot reach out of
	 * its own batch here until host calls land.
	 */
	public static var ambient:Array<String> = [];

	/** Bare names the host answers with a static of its own, written `name=owner.path::field`. */
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
	 * @param env Unused: nothing about a HashLink world is substituted, only the functions in it.
	 * @param report What this run produced.
	 * @return Whether anything now runs compiled.
	 */
	public static function substituting(env:Environment, report:Report):Bool {
		return report.compiled.length > 0;
	}

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

		try {
			emitter.declare(module.decls, module.name);
			emitter.emit(module.decls, module.name);
		} catch (e:Unsupported) {
			report.skipped.push(Skip.from(module.name, e));
			return;
		}

		var exposed:Array<{path:String, field:String, findex:Int}> = [];

		for (decl in module.decls) {
			switch (decl.d) {
				case DClass(c):
					for (f in c.fields) {
						var findex:Null<Int> = emitter.expose(c.name + '.' + f.name);
						if (findex == null)
							continue;

						exposed.push({
							path: pathOf(module, c.name),
							field: f.name,
							findex: findex
						});
					}
				case _:
			}
		}

		if (exposed.length == 0)
			return;

		var built = emitter.finish();
		var bytes:haxe.io.Bytes = built.pack();
		report.bytes += bytes.length;

		var loaded:Null<Loaded> = Loader.load(bytes);
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

			(cast owner : ScriptedClass).reflectSetField(entry.field, fn);
			report.compiled.push(entry.path + '.' + entry.field);
		}

		retained.push(loaded);
	}

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
	 * Finds the value a bound global should be filled with.
	 *
	 * @param binding What the emitter asked for.
	 * @param module The module being compiled.
	 * @param env The world.
	 * @return The value, or null when nothing answers to it.
	 */
	static function valueFor(binding:Binding, module:Module, env:Environment):Dynamic {
		return switch (binding.kind) {
			case BHost: hostValue(binding.owner, binding.field, env);
			case BSupport: Emitter.support(binding.field);
			case BConst: binding.value;
			case BOwner: env.resolve(binding.owner);
			case BModule: module.moduleFields;
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
	static function hostValue(owner:String, field:String, env:Environment):Dynamic {
		var holder:Dynamic = env.variables.exists(owner) ? env.variables.get(owner) : null;
		if (holder == null)
			holder = hxscript.types.TypeTools.resolve(owner, env);
		if (holder == null)
			return null;

		if (field == '')
			return holder;

		return hxscript.proxy.ReflectProxy.field(holder, field);
	}

	/** @return The path a class in a module is resolved by. */
	static function pathOf(module:Module, name:String):String {
		var pack:String = module.pack == null ? '' : module.pack.join('.');
		return pack.length > 0 ? pack + '.' + name : name;
	}
	#end
}
