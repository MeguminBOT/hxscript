package hxscript.lib.openfl;

#if macro
import haxe.macro.Compiler;
import haxe.macro.Context;

/**
 * Lets a script index an `openfl.Vector` it was handed, at native speed.
 *
 * `openfl.Vector` is a `@:multiType` abstract, and what a script holds is one of the classes behind
 * it, `IntVector`, `ObjectVector` and the rest, private to `openfl.Vector`. A script indexes it as a
 * `Dynamic`, which on hxcpp is `__GetItem` / `__SetItem`, and a class answers those with null and
 * nothing, so `v[i]` read null in every mode and `v[i] = x` wrote nowhere.
 *
 * Each class is given the two, calling its own `get` and `set`. Nothing else pays for it: an array
 * is still indexed the way it was, and these are virtual calls the interpreter, the cppia loader and
 * its JIT already make.
 */
class VectorItems {
	/** The classes behind `openfl.Vector`, by the element kind each holds. */
	static final KINDS:Array<String> = ['Bool', 'Float', 'Function', 'Int', 'Object'];

	public static function run():Void {
		if (!Context.defined('openfl') || !Context.defined('cpp') || Context.defined('hxscript_no_vector_items'))
			return;

		for (kind in KINDS) {
			var cls:String = kind + 'Vector_obj';
			var code:String = '\n\t::Dynamic __GetItem(int inIndex) const { return const_cast<' + cls + ' *>(this)->get(inIndex); }'
				+ '\n\t::Dynamic __SetItem(int inIndex, ::Dynamic inValue) { return set(inIndex, inValue); }\n';
			Compiler.addMetadata('@:headerClassCode(' + haxe.Json.stringify(code) + ')', 'openfl._Vector.' + kind + 'Vector');
		}
	}
}
#end
