package host;

import hxscript.Config;
import hxscript.types.TypeCollection;

/**
 * Step 4, as a tool instead of an afternoon.
 *
 * [docs/advanced.md](../../../docs/advanced.md#a-library-not-covered-here) ends its recipe for a new
 * library with "write a script that touches the API you care about and run it", because the last two
 * failures only appear at runtime and only for the members somebody actually used. This asks the
 * same questions ahead of time, by the same route a script asks them, and prints a table.
 *
 * There are three separate ways a name can be unreachable and they need three different fixes, so
 * the table distinguishes them:
 *
 * | verdict | what it means | the fix |
 * | --- | --- | --- |
 * | `absent` | not in the type table at all | add the package to a library's `roots` |
 * | `uncompiled` | in the table, no runtime class | the module was ignored, or is macro-only |
 * | `no runtime form` | the class is there, the member is not | `inline`, or eliminated: `@:keep`, or a shim |
 * | `shimmed` | no runtime form, but `Config.callShims` covers it | nothing |
 *
 * A member is written `owner.path::field`, which is the same spelling the runtime compiler uses for
 * host statics, and a bare path asks only about the type.
 */
@:scriptAmbient
class Probe {
	/**
	 * Checks one type or member.
	 *
	 * @param entry A type path, or `owner.path::field`.
	 * @return A one-word verdict and, when it is bad, what to do about it.
	 */
	public static function check(entry:String):{entry:String, ok:Bool, verdict:String} {
		var split:Int = entry.indexOf('::');
		var path:String = split < 0 ? entry : entry.substr(0, split);
		var field:String = split < 0 ? null : entry.substr(split + 2);

		if (TypeCollection.main.fromCompilePath(path) == null && TypeCollection.main.fromPath(path) == null)
			return {entry: entry, ok: false, verdict: 'absent'};

		var cls:Class<Dynamic> = Type.resolveClass(path);
		if (cls == null) {
			if (Type.resolveEnum(path) != null)
				return {entry: entry, ok: field == null, verdict: field == null ? 'enum' : 'enum has no fields'};

			return {entry: entry, ok: false, verdict: 'uncompiled'};
		}

		if (field == null)
			return {entry: entry, ok: true, verdict: 'ok'};

		if (Reflect.field(cls, field) != null)
			return {entry: entry, ok: true, verdict: 'ok (static)'};

		if (Type.getInstanceFields(cls).indexOf(field) >= 0)
			return {entry: entry, ok: true, verdict: 'ok (instance)'};

		if (Config.callShims.exists('$path.$field'))
			return {entry: entry, ok: true, verdict: 'shimmed'};

		return {entry: entry, ok: false, verdict: 'no runtime form'};
	}

	/**
	 * Checks a list and formats it, worst first so a long run is readable from the top.
	 *
	 * @param title What this group of names is.
	 * @param entries The type paths and `owner::field` members to check.
	 * @return The table, ready to print.
	 */
	public static function report(title:String, entries:Array<String>):String {
		var results = [for (entry in entries) check(entry)];
		var failed:Int = 0;

		var width:Int = 0;
		for (r in results) {
			if (!r.ok)
				failed++;
			if (r.entry.length > width)
				width = r.entry.length;
		}

		results.sort(function(a, b):Int return (a.ok ? 1 : 0) - (b.ok ? 1 : 0));

		var out:Array<String> = ['$title: ${results.length - failed}/${results.length} reachable'];
		for (r in results)
			out.push('  ' + (r.ok ? ' ' : '!') + ' ' + StringTools.rpad(r.entry, ' ', width) + '  ' + r.verdict);

		return out.join('\n');
	}
}
