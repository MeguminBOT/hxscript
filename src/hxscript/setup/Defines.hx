package hxscript.setup;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;
#end

/** Exposes the host build's compiler defines to runtime code so scripts can read them. */
class Defines {
	/** The compiler defines captured at build time, baked in by `getDefines`. */
	public static var compilerDefines(default, never):Map<String, Dynamic> #if (!macro) = getDefines() #end;

	/**
	 * Merges the compiler defines into a map without overwriting existing keys.
	 *
	 * @param map The map to fill in.
	 * @return The same map, with any missing defines added.
	 */
	public static function appendCompilerDefines(map:Map<String, Dynamic>):Map<String, Dynamic> {
		for (k => v in compilerDefines) {
			if (!map.exists(k))
				map.set(k, v);
		}

		return map;
	}

	/**
	 * Macro that inlines the current compiler defines as a runtime map.
	 *
	 * @return An expression evaluating to the build's defines.
	 */
	public static macro function getDefines():Expr #if macro {
		return macro $v{haxe.macro.Context.getDefines()};
	} #end;
}
