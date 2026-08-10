package game;

import hxscript.error.ErrorKind;
import hxscript.runtime.Interp;

/**
 * The interpreter, subclassed so scripts can name the running battle's members directly: `log(...)`
 * and `round` rather than `battle.log(...)` and `battle.round`.
 *
 * `Config.interpClass` is the whole installation. `Module` and `Script` build their interpreter from
 * it, so setting it once in `Mods.setup` covers every script in the world, including ones loaded
 * later.
 *
 * Three methods are involved, and missing any one of them leaves a hole:
 *
 * - `resolve` is the read path, and the obvious one.
 * - `setVar` is the write path. Without it `round = 3` fails with `Unknown identifier: round`, since
 *   assigning to a name nothing declared is an error, which would leave the field readable but not
 *   writable.
 * - `isResolvable` is the gate in front of MEMBER access. `a.b` checks the base identifier through
 *   it and errors without ever calling `resolve`, so overriding only `resolve` makes the bare name
 *   work while `name.length` on the same name fails.
 *
 * The context is static here because the example fights one battle at a time. A host with several
 * script owners at once holds it per interpreter instead, set to whatever state or scene created
 * that script.
 */
@:access(hxscript.runtime.Interp)
class ModInterp extends Interp {
	/** The object whose fields scripts may name without qualifying. Null disables the whole feature. */
	public static var context(default, set):Dynamic = null;

	/**
	 * Field names of `context`, as a set.
	 *
	 * A `Map` rather than the `Array` `Type.getInstanceFields` returns: this is consulted for every
	 * identifier a script does not otherwise resolve, and for the base of every member access, so a
	 * linear scan would put a string comparison per field on a very hot path.
	 */
	static var fields:Map<String, Bool> = new Map();

	/**
	 * Rebuilds the field set whenever the context changes.
	 *
	 * @param v The new context, or null.
	 * @return The same value.
	 */
	static function set_context(v:Dynamic):Dynamic {
		context = v;
		fields = new Map();

		if (v != null) {
			var cls:Class<Dynamic> = Type.getClass(v);
			if (cls != null)
				for (f in Type.getInstanceFields(cls))
					fields.set(f, true);
		}

		return v;
	}

	/**
	 * Matches the base constructor, which is what `Config.interpClass` instantiates.
	 *
	 * @param environment The world this interpreter belongs to.
	 * @param parent The owning script, module or instance.
	 */
	public function new(?environment:hxscript.Environment, ?parent:Dynamic) {
		super(environment, parent);
	}

	/**
	 * Whether a name can be resolved, consulted before MEMBER access.
	 *
	 * @param id The identifier.
	 * @return Whether it resolves, now including context fields.
	 */
	override public function isResolvable(id:String):Bool {
		return super.isResolvable(id) || (context != null && fields.exists(id));
	}

	/**
	 * Reads an identifier, falling back to the context's fields.
	 *
	 * @param id The identifier.
	 * @return Its value.
	 */
	override public function resolve(id:String):Dynamic {
		if (imports.exists(id)) {
			var v:Dynamic = imports.get(id);
			if (v == null)
				error(ECustom('Module $id does not define type $id'));
			return resolveMirror(v);
		}

		if (variables.exists(id))
			return resolveMirror(variables.get(id));

		if (context != null && fields.exists(id))
			return Reflect.getProperty(context, id);

		error(EUnknownVariable(id));
		return null;
	}

	/**
	 * Writes an identifier, sending context fields to the real object.
	 *
	 * @param name The identifier.
	 * @param v The value to write.
	 * @return The written value.
	 */
	override function setVar(name:String, v:Dynamic):Dynamic {
		// Only a genuine context field that nothing else already binds. Everything else, including the
		// strict error for assigning to an undeclared name, stays with the base implementation.
		if (!imports.exists(name) && !variables.exists(name) && context != null && fields.exists(name)) {
			Reflect.setProperty(context, name, v);
			return v;
		}

		return super.setVar(name, v);
	}
}
