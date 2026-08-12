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
	 * `-D hxscript_keep=StringTools,haxe.Json` adds them without editing this list.
	 *
	 * `Lambda` is here rather than among the neighbours because leaving it out was not neutral: on
	 * hxcpp something else in an ordinary build referenced it and a script could call it, and on eval
	 * and HashLink nothing did and the same script could not. A default that changes what a script
	 * can reach depending on which target the host was built for is worse than either answer.
	 */
	public static var types:Array<String> = [
		'IntIterator',
		'Reflect',
		'Type',
		'haxe.ds.StringMap',
		'EReg',
		'List',
		'haxe.ds.List',
		'Lambda',
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

		var asked:Null<String> = Context.definedValue('hxscript_keep');

		if (asked != null) {
			for (raw in asked.split(',')) {
				var one:String = StringTools.trim(raw);
				if (one.length > 0 && types.indexOf(one) < 0)
					types.push(one);
			}
		}

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
