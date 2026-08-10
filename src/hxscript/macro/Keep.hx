package hxscript.macro;

#if macro
import haxe.macro.Compiler;
import haxe.macro.Context;
#end

/**
 * Keeps the standard-library types scripts reach by reflection from being eliminated.
 */
class Keep {
	/**
	 * The types kept, chosen by what scripts actually reach for.
	 *
	 * Neighbours worth adding for a host whose scripts use them, none of which are kept by default
	 * because each costs binary size for a program that does not: `haxe.ds.IntMap`,
	 * `haxe.ds.ObjectMap`, `haxe.ds.EnumValueMap`, `StringTools`, `haxe.Json`, `haxe.Timer`.
	 */
	public static var types:Array<String> = [
		'IntIterator',
		'Reflect',
		'Type',
		'haxe.ds.StringMap',
		'EReg',
		'List',
		'haxe.ds.List',
		'Date',
		'Sys'
	];

	/**
	 * Pulls every type in `types` into the build and marks it, along with its fields, as kept.
	 */
	public static function run():Void {
		#if macro
		if (Context.defined('hxscript_no_keep'))
			return;

		for (path in types) {
			// Not recursive: these are exact type paths, and a recursive filter on a name like `Type`
			Compiler.addGlobalMetadata(path, '@:keep', false, true, true);
		}

		// Typing a path is what puts it in the build. Deferred, because a type asked for too early is
		Context.onAfterInitMacros(function():Void {
			for (path in types) {
				try {
					Context.getType(path);
				} catch (e:Dynamic) {}
			}
		});
		#end
	}
}
