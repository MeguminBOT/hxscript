package hxscript.error;

#if !macro
import hxscript.types.TypeCollection;
#end

/**
 * What usually causes an error, as opposed to what the error says.
 */
class Hint {
	/** How many alternative spellings to offer for a misspelled name. */
	public static var suggestions:Int = 3;

	#if !macro
	/** Every type in the build, by short name, built on first use. */
	static var byName:Map<String, Array<String>> = null;
	#end

	/**
	 * The hint for one error kind.
	 *
	 * @param kind The error.
	 * @return What usually causes it, or null when there is nothing useful to add.
	 */
	public static function forKind(kind:ErrorKind):Null<String> {
		return switch (kind) {
			case EUnknownVariable(v):
				unknownName(v);

			case EUnknownType(t):
				missingType(t);

			case EUnknownField(o, f):
				unknownField(o, f);

			case EInvalidAccess(f):
				'`$f` exists but is not visible from a script. A `private` member is only reachable from\n' +
				'inside the type that declares it; expose a public accessor, or set Config.strictAccess\n' +
				'to false if this host wants scripts to reach private members.';

			case ECustom(message):
				custom(message);

			case EImportHx:
				'An `import.hx` prelude may only hold `import` and `using`. Move anything else into a\n' +
				'module of its own.';

			case _:
				null;
		}
	}

	/**
	 * The hint for a name nothing resolved.
	 *
	 * @param name The unresolved identifier.
	 * @return The hint.
	 */
	static function unknownName(name:String):String {
		#if macro
		return null;
		#else
		var paths:Array<String> = matching(name);

		if (paths.length > 0) {
			var lines:Array<String> = [
				'`$name` is in this build but is not in scope here. Either import it in the script:'
			];

			for (path in paths.slice(0, suggestions))
				lines.push('    import $path;');

			lines.push('or add it to the `globals` of a hxscript.setup.Library record so no script has to.');
			return lines.join('\n');
		}

		var near:Array<String> = nearest(name, [for (info in TypeCollection.main.types.all) info.name]);
		if (near.length > 0)
			return 'No type or variable named `$name`. Did you mean ' + quoted(near) + '?';

		return 'Nothing named `$name` is in this build.\n'
			+ 'If it should be, its package was never force-compiled: a script reaches library types by\n'
			+ 'name, so dead code elimination has no reason to keep what the host itself never touched.\n'
			+ 'Add the library to hxscript.setup.Presets, or name the module in a record\'s `types`.';
		#end
	}

	/**
	 * The hint for a type path that would not resolve.
	 *
	 * @param path The type path.
	 * @return The hint.
	 */
	static function missingType(path:String):String {
		#if macro
		return null;
		#else
		var name:String = path.split('.').pop();
		var paths:Array<String> = matching(name);

		if (paths.length > 0 && paths.indexOf(path) < 0)
			return '`$path` is not in this build, but '
				+ quoted(paths.slice(0, suggestions))
				+ ' is. Check the package.';

		return '`$path` is not in this build.\n'
			+ 'Either its package was never force-compiled, or an ignore list kept its module out.\n'
			+ 'Build with -D hxscript_verbose to see what the setup included.';
		#end
	}

	/**
	 * The hint for a field that is not on the object.
	 *
	 * Names the receiver's type, which the message does not: `Std.string(o)` of an instance is
	 * usually its class name and sometimes the whole object printed, and neither answers "what did I
	 * actually have there".
	 *
	 * @param o The receiver.
	 * @param field The field asked for.
	 * @return The hint.
	 */
	static function unknownField(o:Dynamic, field:String):String {
		if (o == null)
			return 'The value is null, so there is no `$field` on it. The error is wherever it was last assigned.';

		var owner:String = typeName(o);
		var near:Array<String> = nearest(field, membersOfValue(o));

		if (near.length > 0)
			return '`$owner` has no `$field`. Did you mean ' + quoted(near) + '?';

		return '`$owner` has no `$field`.\n'
			+ 'If the library does declare it, it is either `inline`, which leaves no runtime member to\n'
			+ 'find, or dead code elimination removed it. -dce no keeps it; a Config.callShims entry\n'
			+ 'keyed `$owner.$field` emulates it.';
	}

	/**
	 * The hint for a message the interpreter built itself.
	 *
	 * @param message The interpreter's message.
	 * @return The hint, or null.
	 */
	static function custom(message:String):Null<String> {
		if (!StringTools.startsWith(message, 'Cannot call '))
			return null;

		var target:String = StringTools.trim(message.substr('Cannot call '.length));

		var at:Int = target.lastIndexOf('.');
		if (at < 0)
			return null;

		var owner:String = target.substr(0, at);
		var field:String = target.substr(at + 1);

		var near:Array<String> = nearest(field, membersOf(owner));
		if (near.length > 0)
			return '`$owner` has no `$field`. Did you mean ' + quoted(near) + '?';

		return '`$target` reflected to nothing, which usually means it has no runtime form rather than\n'
			+ 'that it is missing. A method declared `inline` is substituted at every compiled call site\n'
			+ 'and never becomes a method, so there is nothing for a script to call.\n'
			+ 'Register an emulation with Config.callShims keyed `$target`, or build with -dce no if the\n'
			+ 'member only lost its body to dead code elimination.';
	}

	/**
	 * Every member a named type answers to, resolved by name.
	 *
	 * @param owner A fully-qualified type name.
	 * @return Its instance and static field names, empty when the type cannot be resolved.
	 */
	static function membersOf(owner:String):Array<String> {
		var cls:Class<Dynamic> = try Type.resolveClass(owner) catch (e:haxe.Exception) null;
		if (cls == null)
			return [];

		var out:Array<String> = [];

		try {
			for (name in Type.getInstanceFields(cls))
				out.push(name);
		} catch (e:haxe.Exception) {}

		try {
			for (name in Type.getClassFields(cls))
				if (out.indexOf(name) < 0)
					out.push(name);
		} catch (e:haxe.Exception) {}

		return out;
	}

	/**
	 * Every full path in the build whose short name matches.
	 *
	 * @param name The short type name.
	 * @return The matching paths, empty when there are none.
	 */
	public static function matching(name:String):Array<String> {
		#if macro
		return [];
		#else
		if (byName == null) {
			byName = new Map();

			for (info in TypeCollection.main.types.all) {
				var path:String = TypeCollection.compilePath(info);
				var known:Array<String> = byName.get(info.name);

				if (known == null)
					byName.set(info.name, [path]);
				else if (known.indexOf(path) < 0)
					known.push(path);
			}
		}

		var found:Array<String> = byName.get(name);
		return found == null ? [] : found;
		#end
	}

	/**
	 * The names closest to a misspelling, by edit distance.
	 *
	 * The threshold scales with length because a two-character difference is a typo in `clipToWorldRect`
	 * and a different word entirely in `add`.
	 *
	 * @param name What was asked for.
	 * @param candidates What was available.
	 * @return Up to `suggestions` names, nearest first; empty when nothing is close.
	 */
	public static function nearest(name:String, candidates:Array<String>):Array<String> {
		var limit:Int = Std.int(Math.max(1, Math.min(3, name.length / 3)));
		var scored:Array<{name:String, distance:Int}> = [];

		var lower:String = name.toLowerCase();

		for (candidate in candidates) {
			if (candidate == name)
				continue;

			var distance:Int = candidate.toLowerCase() == lower ? 1 : editDistance(lower, candidate.toLowerCase(),
				limit);

			if (distance <= limit)
				scored.push({name: candidate, distance: distance});
		}

		scored.sort(function(a, b):Int return a.distance - b.distance);

		var out:Array<String> = [];
		for (item in scored) {
			if (out.length >= suggestions)
				break;

			if (out.indexOf(item.name) < 0)
				out.push(item.name);
		}

		return out;
	}

	/**
	 * Levenshtein distance, abandoned once it cannot come in under the limit.
	 *
	 * Two rows rather than a full matrix, and an early exit: this runs against every field of a class
	 * or every type in the build, and only the small distances are ever wanted.
	 *
	 * @param a The first string.
	 * @param b The second string.
	 * @param limit The largest distance worth computing exactly.
	 * @return The distance, or `limit + 1` when it is larger than that.
	 */
	static function editDistance(a:String, b:String, limit:Int):Int {
		var over:Int = limit + 1;

		if (a.length - b.length > limit || b.length - a.length > limit)
			return over;

		var previous:Array<Int> = [for (i in 0...b.length + 1) i];
		var current:Array<Int> = [for (i in 0...b.length + 1) 0];

		for (i in 0...a.length) {
			current[0] = i + 1;
			var best:Int = current[0];

			for (j in 0...b.length) {
				var cost:Int = a.charCodeAt(i) == b.charCodeAt(j) ? 0 : 1;

				var value:Int = previous[j] + cost;
				var up:Int = previous[j + 1] + 1;
				var left:Int = current[j] + 1;

				if (up < value)
					value = up;
				if (left < value)
					value = left;

				current[j + 1] = value;

				if (value < best)
					best = value;
			}

			if (best > limit)
				return over;

			var swap:Array<Int> = previous;
			previous = current;
			current = swap;
		}

		return previous[b.length] > limit ? over : previous[b.length];
	}

	/**
	 * What a value's type is called, as a reader would name it.
	 *
	 * @param o The value.
	 * @return The type name.
	 */
	public static function typeName(o:Dynamic):String {
		if (o == null)
			return 'null';

		var base:Dynamic = try Reflect.getProperty(o, '__base') catch (e:haxe.Exception) null;
		if (base != null && Std.isOfType(base, hxscript.types.ScriptedClass)) {
			var owner:hxscript.types.ScriptedClass = cast base;
			if (owner.path != null)
				return owner.path;
		}

		var cls:Class<Dynamic> = Type.getClass(o);
		if (cls != null)
			return Type.getClassName(cls);

		return switch (Type.typeof(o)) {
			case TInt: 'Int';
			case TFloat: 'Float';
			case TBool: 'Bool';
			case TFunction: 'a function';
			case TObject: 'an anonymous object';
			case TEnum(e): Type.getEnumName(e);
			case _: 'Dynamic';
		}
	}

	/**
	 * Every member name a value answers to, scripted and native alike.
	 *
	 * @param o The value.
	 * @return The names, empty when none can be read.
	 */
	public static function membersOfValue(o:Dynamic):Array<String> {
		var out:Array<String> = [];

		if (o == null)
			return out;

		try {
			for (name in hxscript.proxy.ReflectProxy.fields(o))
				if (out.indexOf(name) < 0)
					out.push(name);
		} catch (e:haxe.Exception) {}

		/**
		 * A scripted class's methods, which reflection does not list because a method is not a
		 * field. What is being suggested here is a name the script wrote, and most of the names a
		 * script gets wrong are methods.
		 */
		try {
			var declared:Dynamic = hxscript.proxy.TypeProxy.getClass(o);

			if (declared is hxscript.types.ScriptedClass) {
				for (name in cast(declared, hxscript.types.ScriptedClass).typeGetInstanceFields())
					if (out.indexOf(name) < 0)
						out.push(name);
			}
		} catch (e:haxe.Exception) {}

		try {
			var cls:Class<Dynamic> = Type.getClass(o);
			if (cls != null)
				for (name in Type.getInstanceFields(cls))
					if (out.indexOf(name) < 0)
						out.push(name);
		} catch (e:haxe.Exception) {}

		return out;
	}

	/**
	 * @param names The names to list.
	 * @return Them, back-quoted and comma-separated, with `or` before the last.
	 */
	static function quoted(names:Array<String>):String {
		var marked:Array<String> = [for (name in names) '`$name`'];

		if (marked.length <= 1)
			return marked.length == 0 ? '' : marked[0];

		return marked.slice(0, marked.length - 1).join(', ') + ' or ' + marked[marked.length - 1];
	}
}
