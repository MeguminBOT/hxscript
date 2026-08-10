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

import hxscript.compile.Unit;
import hxscript.compile.Result;
import hxscript.syntax.Expr;

/**
 * Compiles hxscript modules to cppia bytecode, which hxcpp loads and JIT-compiles at runtime.
 */
class Cppia {
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
	static function isBool(t:Null<CType>):Bool {
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
}
