package hxscript.types;

import hxscript.runtime.Interp;
import hxscript.runtime.Variable;
import hxscript.syntax.Expr;
import hxscript.Module;

using StringTools;
using hxscript.types.TypeCollection;

/** Helpers for resolving the types a scripted class extends or implements. */
class ScriptedTools {
	/**
	 * Whether an instance should carry its slots by position as well as by name.
	 *
	 * Off unless a backend that reaches one without asking turns it on, since it costs an allocation
	 * per instance and nothing else reads it.
	 */
	public static var wantsSlots:Bool = false;

	/**
	 * Finds the `super(...)` call a scripted constructor opens with.
	 *
	 * Only at the top level of the body, and only before anything that could touch the instance.
	 * That is not a restriction this invents: Haxe forbids reaching `this` before `super`, so a
	 * constructor whose `super` is anywhere else is one Haxe would not have compiled either.
	 *
	 * @param body The constructor's body.
	 * @return The statements before it and the arguments it passes, or null when there is no `super`
	 *         call to be found and the base must be constructed with none.
	 */
	public static function opensWithSuper(body:Expr):Null<{before:Array<Expr>, args:Array<Expr>}> {
		var statements:Array<Expr> = switch (ExprTools.expr(body)) {
			case EBlock(list): list;
			case _: [body];
		}

		var before:Array<Expr> = [];

		for (statement in statements) {
			switch (ExprTools.expr(statement)) {
				case ECall(callee, args):
					switch (ExprTools.expr(callee)) {
						case EIdent('super'):
							return {before: before, args: args};
						case _:
					}

				case _:
			}

			before.push(statement);
		}

		return null;
	}

	/**
	 * @param body A constructor's body.
	 * @return It without the `super(...)` call, for a base that has already been constructed.
	 *
	 * The call is dropped rather than made a no-op so that its arguments are evaluated once. They
	 * were already evaluated to construct the base, and evaluating them again would run whatever
	 * they do a second time.
	 */
	public static function withoutSuper(body:Expr):Expr {
		var statements:Array<Expr> = switch (ExprTools.expr(body)) {
			case EBlock(list): list;
			case _: [body];
		}

		var kept:Array<Expr> = [];

		for (statement in statements) {
			var isSuper:Bool = switch (ExprTools.expr(statement)) {
				case ECall(callee, _):
					switch (ExprTools.expr(callee)) {
						case EIdent('super'): true;
						case _: false;
					}
				case _: false;
			}

			if (!isSuper)
				kept.push(statement);
		}

		return ({e: EBlock(kept), pos: body.pos} : Expr);
	}

	/**
	 * Lays an instance's variables out in the order its class holds them.
	 *
	 * The first instance of a class decides the order, which is the order the bridge bound the
	 * fields in and is therefore the same for every instance of it. A name the class does not know
	 * has no slot, and a slot a later instance has no variable for stays empty; both are answered by
	 * whoever asks rather than being errors here.
	 *
	 * @param base The class.
	 * @param vars The instance's variables by name.
	 * @return The variables by position.
	 */
	public static function slotsFor(base:ScriptedClass, vars:Map<String, Variable>):haxe.ds.Vector<Variable> {
		if (base.slotNames == null) {
			var names:Array<String> = [];
			var index:Map<String, Int> = new Map();

			for (name in vars.keys()) {
				index.set(name, names.length);
				names.push(name);
			}

			base.slotNames = names;
			base.slotIndex = index;
		}

		var names:Array<String> = base.slotNames;
		var slots:haxe.ds.Vector<Variable> = new haxe.ds.Vector<Variable>(names.length);

		for (i in 0...names.length)
			slots[i] = vars.get(names[i]);

		return slots;
	}

	/** Every native class that has a generated scripting bridge, keyed by class name. */
	public static var scriptedClasses(get, never):Map<String, Class<IScriptedInstance>>;

	static var bridgesByBase:Map<String, Class<IScriptedInstance>> = null;

	/**
	 * Builds the bridge table on first use rather than in a static initializer.
	 *
	 * The table is read out of `haxe.rtti.Meta`, and on python a static initializer runs before
	 * `python.Boot` has its own statics, so building it eagerly returned null for every lookup and
	 * left the library installed and inert.
	 *
	 * @return Bridge classes keyed by the base class each one extends.
	 */
	static function get_scriptedClasses():Map<String, Class<IScriptedInstance>> {
		if (bridgesByBase == null)
			bridgesByBase = hxscript.macro.Scripted.listScriptedClasses();

		return bridgesByBase;
	}

	/**
	 * Resolves an `extends`/`implements` type reference against the declaring module's
	 * imports first, then the interpreter's, then the compiled type collection.
	 *
	 * @param t The type reference to resolve.
	 * @param module The declaring module whose imports take priority, if any.
	 * @param interp The interpreter whose imports/environment are consulted next, if any.
	 * @return The resolved type.
	 * @throws String If the type cannot be found or the reference is not a path.
	 */
	public static function resolveType(t:CType, ?module:Module, ?interp:Interp):Dynamic {
		return switch (t) {
			case CTPath(path, _):
				var p:String = path.join('.');

				var type = (module?.interp.imports.get(p) ?? interp?.imports.get(p) ?? TypeTools.resolve(p, interp?.environment));
				if (type == null)
					throw 'Type not found: $p';

				type;
			case null:
				null;
			default:
				throw 'Invalid type $t';
				null;
		}
	}

	/**
	 * Like `resolveType`, but for `implements` entries. A native interface the runtime cannot hand
	 * back as a value still names a valid contract, and the generated bridge is what satisfies it, so
	 * a known-but-unresolvable interface returns null instead of throwing. An outright unknown name
	 * still throws.
	 *
	 * @param t The interface reference to resolve.
	 * @param module The declaring module whose imports take priority, if any.
	 * @param interp The interpreter whose imports/environment are consulted next, if any.
	 * @return The resolved interface, or null for a known-but-unresolvable native interface.
	 * @throws String If the name is outright unknown or the reference is not a path.
	 */
	public static function resolveInterface(t:CType, ?module:Module, ?interp:Interp):Dynamic {
		var p:String = switch (t) {
			case CTPath(path, _): path.join('.');
			default: throw 'Invalid interface $t';
		}

		var type = (module?.interp.imports.get(p) ?? interp?.imports.get(p) ?? TypeTools.resolve(p, interp?.environment));
		if (type != null)
			return type;

		if (TypeCollection.main.fromPath(p) == null && interp?.environment?.types.fromPath(p) == null)
			throw 'Type not found: $p';

		return null;
	}

	/**
	 * Resolves a base type to something a scripted class can extend: either an already-scripted
	 * class, or a native class that has a generated bridge.
	 *
	 * @param t The base type (a scripted class or a native class).
	 * @return The scripted class, or the bridge class for a native base.
	 * @throws String If the native class has no scripting bridge.
	 */
	public static function resolve(t:Dynamic):Dynamic {
		if (t is ScriptedClass)
			return cast t;

		var cls:String = Type.getClassName(t);
		if (scriptedClasses.exists(cls))
			return scriptedClasses.get(cls);

		throw 'Class $cls can\'t be extended for scripting';
		return null;
	}
}
