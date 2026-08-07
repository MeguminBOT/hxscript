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

package hxscript.macro;

#if macro
import haxe.macro.Context;
import haxe.macro.Type;
import haxe.macro.TypeTools;
#end

/**
 * Compile-time builder of what the compiler needs to know about the host.
 *
 * The interpreter needs none of this: it resolves a name against the global `TypeCollection`, which
 * `TypeCollectionMacro` fills with everything in the build, and it reads whatever `Config` injected
 * into it. Compiled code has neither. It has no interpreter to be injected into, and it links
 * against real classes and real statics, so every bare name a script may use has to be written down
 * as a full path before a module is emitted.
 *
 * Written down by hand that is two lists to maintain, one of which -- the `name=owner::field` form
 * for host statics -- is easy to get subtly wrong and fails at compile time with a message about an
 * identifier rather than about the list. This collects both from the build instead, the same way the
 * interpreter's table is collected.
 *
 * Mark what scripts may reach:
 *
 * ```haxe
 * @:scriptAmbient
 * class Player {
 *     @:scriptStatic('player')       // a script writing `player` gets this
 *     public static var current:Player;
 * }
 * ```
 *
 * Then hand it all over once, at startup:
 *
 * ```haxe
 * ExposeMacro.apply();
 * ```
 *
 * That fills both sides from the same marks: `Config.globalVariables` so an interpreted script can
 * write `player`, and `Compiler.ambient`/`Compiler.statics` so a compiled one resolves the same name
 * to the same static. Marking a thing once and having it work either way is the point -- filling
 * only one side gives a script that runs until the day it is compiled, or the reverse.
 *
 * The two lists are also readable on their own, for a host that wants to add to them:
 *
 * ```haxe
 * Compiler.ambient = ExposeMacro.ambient().concat(['extra.Type']);
 * Compiler.statics = ExposeMacro.statics();
 * ```
 *
 * Whole packages can be exposed without touching their types, for a host whose API is already
 * grouped:
 *
 * ```
 * --macro hxscript.macro.ExposeMacro.expose(['game', 'engine.api'])
 * ```
 *
 * Neither list changes what a script is *allowed* to touch -- `Config` still decides that, and still
 * decides it for interpreted and compiled code alike. This only tells the emitter where the things
 * it already accepts actually live.
 */
class ExposeMacro {
	/** This macro class's own path, under which the collected lists are stashed. */
	static var _name:String = 'hxscript.macro.ExposeMacro';

	#if macro
	/** Packages named by `expose`, whose every type becomes ambient. */
	static var packages:Array<String> = [];

	/** Whether the after-typing pass has been registered. */
	static var hooked:Bool = false;
	#end

	/**
	 * Exposes every type in the given packages, on top of anything marked `@:scriptAmbient`.
	 *
	 * For a host whose scriptable API is already a package or two, so its types need no annotation.
	 * A sub-package counts as inside its parent, so `game` covers `game.combat` as well.
	 *
	 * @param packs Package paths. An empty string exposes the root package only.
	 */
	public static macro function expose(packs:Array<String>):Void {
		#if macro
		for (pack in packs) {
			if (packages.indexOf(pack) < 0)
				packages.push(pack);
		}

		collect();
		#end
	}

	/**
	 * Fills in both sides from what the build marked.
	 *
	 * Sets `Compiler.ambient` and `Compiler.statics` for compiled code, and adds every
	 * `@:scriptStatic` to `Config.globalVariables` for interpreted code, so a bare name means the
	 * same thing whichever way a script ends up running.
	 *
	 * Existing entries are kept: a name already in `globalVariables` is left as the host set it.
	 *
	 * @return The code that fills them in, run where the call appears.
	 */
	public static macro function apply():haxe.macro.Expr {
		#if macro
		collect();
		#end

		return macro {
			var exposedTypes:Array<String> = hxscript.macro.ExposeMacro.ambient();
			var exposedStatics:Array<String> = hxscript.macro.ExposeMacro.statics();

			#if hxscript_cppia
			hxscript.compile.Compiler.ambient = exposedTypes;
			hxscript.compile.Compiler.statics = exposedStatics;
			#end

			for (binding in exposedStatics) {
				var split:Int = binding.indexOf('=');
				var owner:Int = binding.indexOf('::');
				if (split < 0 || owner < split)
					continue;

				var name:String = binding.substr(0, split);
				if (hxscript.Config.globalVariables.exists(name))
					continue;

				var path:String = binding.substring(split + 1, owner);
				var field:String = binding.substr(owner + 2);
				var cls:Dynamic = Type.resolveClass(path);

				if (cls != null)
					hxscript.Config.globalVariables.set(name, Reflect.field(cls, field));
			}
		}
	}

	/**
	 * The full paths of every exposed type, for `Compiler.ambient`.
	 *
	 * @return An array of dotted paths, built at compile time.
	 */
	public static macro function ambient():haxe.macro.Expr {
		#if macro
		collect();
		#end

		return macro cast haxe.Unserializer.run(haxe.rtti.Meta.getType($p{_name.split('.')}).exposedTypes[0]);
	}

	/**
	 * Every `@:scriptStatic` binding, for `Compiler.statics`.
	 *
	 * Each entry is `name=owner.path::field`, which is the form the emitter reads: the bare name a
	 * script writes, and the static it really means.
	 *
	 * @return An array of bindings, built at compile time.
	 */
	public static macro function statics():haxe.macro.Expr {
		#if macro
		collect();
		#end

		return macro cast haxe.Unserializer.run(haxe.rtti.Meta.getType($p{_name.split('.')}).exposedStatics[0]);
	}

	#if macro
	/**
	 * Registers the after-typing pass that walks the build and records what it finds.
	 *
	 * After typing rather than during it, because a type marked in a module nothing has referenced
	 * yet is not in the build when a macro call is typed, and would be missed.
	 */
	static function collect():Void {
		if (hooked)
			return;

		hooked = true;

		Context.onAfterTyping(function(types:Array<ModuleType>):Void {
			var self:ClassType = TypeTools.getClass(Context.getType(_name));
			if (self.meta.has('exposedTypes'))
				return;

			var exposedTypes:Array<String> = [];
			var exposedStatics:Array<String> = [];

			for (type in types) {
				switch (type) {
					case TClassDecl(ref):
						var cls:ClassType = ref.get();
						var path:String = fullPath(cls.pack, cls.name);

						if (cls.meta.has(':scriptAmbient') || inExposedPackage(cls.pack)) {
							if (exposedTypes.indexOf(path) < 0)
								exposedTypes.push(path);
						}

						for (field in cls.statics.get()) {
							var meta = field.meta.extract(':scriptStatic');
							if (meta.length == 0)
								continue;

							switch (field.kind) {
								case FVar(AccCall, _) if (!field.meta.has(':isVar')):
									Context.warning(':scriptStatic on ${field.name} exposes a property with no backing field, so scripts read null. Expose a function instead, or add @:isVar.',
										field.pos);
								case FVar(AccNever | AccNo, _):
									Context.warning(':scriptStatic on ${field.name} exposes a static that cannot be read, so scripts read null.', field.pos);
								default:
							}

							var name:String = field.name;
							if (meta[0].params != null && meta[0].params.length > 0) {
								switch (meta[0].params[0].expr) {
									case EConst(CString(s, _)): name = s;
									case _:
										Context.warning(':scriptStatic wants a string name, or nothing', meta[0].pos);
								}
							}

							exposedStatics.push(name + '=' + path + '::' + field.name);
						}

					case TEnumDecl(ref):
						var en:EnumType = ref.get();
						if (en.meta.has(':scriptAmbient') || inExposedPackage(en.pack)) {
							var path:String = fullPath(en.pack, en.name);
							if (exposedTypes.indexOf(path) < 0)
								exposedTypes.push(path);
						}

					case TAbstract(ref):
						var ab:AbstractType = ref.get();
						if (ab.meta.has(':scriptAmbient') || inExposedPackage(ab.pack)) {
							var path:String = fullPath(ab.pack, ab.name);
							if (exposedTypes.indexOf(path) < 0)
								exposedTypes.push(path);
						}

					case _:
				}
			}

			self.meta.add('exposedTypes', [macro $v{haxe.Serializer.run(exposedTypes)}], Context.currentPos());
			self.meta.add('exposedStatics', [macro $v{haxe.Serializer.run(exposedStatics)}], Context.currentPos());
		});
	}

	/**
	 * @param pack A type's package.
	 * @param name Its name.
	 * @return The dotted path the emitter links against.
	 */
	static function fullPath(pack:Array<String>, name:String):String {
		return pack.length > 0 ? pack.join('.') + '.' + name : name;
	}

	/**
	 * Whether a package was named by `expose`, or sits inside one that was.
	 *
	 * @param pack The type's package.
	 * @return Whether its types are exposed wholesale.
	 */
	static function inExposedPackage(pack:Array<String>):Bool {
		if (packages.length == 0)
			return false;

		var path:String = pack.join('.');

		for (exposed in packages) {
			if (path == exposed)
				return true;
			if (exposed.length > 0 && path.length > exposed.length && path.substr(0, exposed.length + 1) == exposed + '.')
				return true;
		}

		return false;
	}
	#end
}
