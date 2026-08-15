package hxscript.types;

import hxscript.types.TypeCollection.TypeInfo;

/**
 * Hands a constructor what the call meant, which is not always the array the call built.
 *
 * **Haxe lets a call leave out an optional parameter in the middle, and decides which one by type.**
 * `new Mesh(prim, parent)` against `(primitive, ?material, ?parent)` is a two-argument call to a
 * three-parameter constructor: the compiler asks whether the second argument is a `Material`, finds
 * it is not, drops a `null` into that place and puts it in `parent` instead. Every 3D script writes
 * calls like that one, because a mesh with a default material is the ordinary case.
 *
 * A script's arguments arrive as an array with nothing said about them, so a runtime binding them in
 * order gives `parent` to `material` and the constructor throws a cast error naming two types the
 * script never mentioned. What is missing is the question the compiler asked, and its inputs: the
 * parameter types. `Index` records those for the constructors a call can be short in the middle of,
 * and this asks them.
 *
 * **It answers with the arguments unchanged whenever it is not certain**, which is the whole of its
 * safety. A parameter whose type nothing at runtime can test accepts what it is given; an argument
 * left over at the end, or one that fits nothing, abandons the attempt. So a call this cannot place
 * is passed exactly as it would have been before this existed, and a call it can place was a cast
 * error a moment ago.
 *
 * The other half is older and simpler: a boxed abstract is unwrapped on the way in. Every call the
 * interpreter makes has always done that, and construction was the one that did not, so a vector
 * built by a script reached a host constructor as this library's wrapper around one.
 */
class ArgumentTools {
	/** Parsed shapes, by class name, including the classes that turned out to have none. */
	static var shapes:Map<String, Null<Shape>> = new Map();

	/** Resolved parameter types, by the path recorded for them. */
	static var tested:Map<String, Dynamic> = new Map();

	/** Paths nothing resolved, so the lookup is not repeated per call. */
	static var missing:Map<String, Bool> = new Map();

	/**
	 * Prepares a call's arguments for a constructor.
	 *
	 * Two things, both of which an ordinary method call has done for a long time and a constructor
	 * never had. A boxed abstract is unwrapped, so `new DirLight(new Vector(0, 0, -1), parent)` hands
	 * the constructor a vector rather than this library's wrapper around one. Then the arguments are
	 * placed in the parameters they were written for.
	 *
	 * @param cl The class being constructed.
	 * @param args The arguments as the call wrote them.
	 * @return The arguments to construct with: a longer array with a `null` where a parameter was
	 *         skipped, or the array given when nothing was skipped or nothing could be decided.
	 */
	public static function forConstructor(cl:Dynamic, args:Array<Dynamic>):Array<Dynamic> {
		if (args == null || args.length == 0)
			return args;

		for (i => arg in args)
			if (arg is AbstractValue)
				args[i] = AbstractTools.underlying(arg);

		if (!TypeTools.isClass(cl))
			return args;

		var name:Null<String> = Type.getClassName(cl);
		if (name == null)
			return args;

		var shape:Null<Shape> = shapeOf(name);
		if (shape == null || args.length >= shape.opt.length)
			return args;

		return fit(shape, args);
	}

	/**
	 * Walks parameters and arguments together, the way the compiler does.
	 *
	 * @param shape The constructor's parameters.
	 * @param args The arguments as the call wrote them.
	 * @return The placed arguments, or the ones given when the walk did not account for all of them.
	 */
	static function fit(shape:Shape, args:Array<Dynamic>):Array<Dynamic> {
		var out:Array<Dynamic> = [];
		var at:Int = 0;
		var skipped:Bool = false;

		for (i in 0...shape.opt.length) {
			if (at >= args.length) {
				/** A required parameter with nothing left to give it: not a call this can place. */
				if (!shape.opt[i])
					return args;

				out.push(null);
				continue;
			}

			if (accepts(shape.key[i], args[at])) {
				out.push(args[at]);
				at++;
			} else if (shape.opt[i]) {
				out.push(null);
				skipped = true;
			} else {
				return args;
			}
		}

		/**
		 * Arguments left over means the walk placed them somewhere they do not belong, whatever it
		 * did with the rest. Better the call the script wrote, and its own error.
		 */
		if (at < args.length)
			return args;

		return skipped ? out : args;
	}

	/**
	 * Whether a parameter of this type takes this value.
	 *
	 * Certain of a no, or it says yes: `null` fits anything and an untestable parameter takes
	 * anything.
	 *
	 * @param key The parameter's recorded type, empty for one that takes anything.
	 * @param v The argument.
	 * @return Whether the argument may be placed here.
	 */
	static function accepts(key:String, v:Dynamic):Bool {
		if (key.length == 0 || v == null)
			return true;

		switch (key) {
			case 'Int':
				return (v is Int);
			case 'Float' | 'Single':
				return (v is Float);
			case 'Bool':
				return (v is Bool);
			case 'String':
				return (v is String);
			case 'Array':
				return (v is Array);
			case _:
		}

		if (missing.exists(key))
			return true;

		var t:Dynamic = tested.get(key);

		if (t == null) {
			t = Type.resolveClass(key);

			if (t == null)
				t = Type.resolveEnum(key);

			if (t == null) {
				missing.set(key, true);
				return true;
			}

			tested.set(key, t);
		}

		return Std.isOfType(v, t);
	}

	/**
	 * @param name A class's compile path.
	 * @return Its constructor's parameters, or null when a call of it cannot be short in the middle.
	 */
	static function shapeOf(name:String):Null<Shape> {
		if (shapes.exists(name))
			return shapes.get(name);

		var shape:Null<Shape> = parse(name);
		shapes.set(name, shape);
		return shape;
	}

	/**
	 * @param name A class's compile path.
	 * @return What the build's type table recorded for its constructor, parsed, or null.
	 */
	static function parse(name:String):Null<Shape> {
		var infos:Array<TypeInfo> = TypeCollection.main.fromCompilePath(name);

		if (infos == null || infos.length == 0)
			return null;

		var written:Null<String> = infos[0].ctorSkip;

		if (written == null || written.length == 0)
			return null;

		var parts:Array<String> = written.split('|');
		var shape:Shape = new Shape();

		for (part in parts) {
			var optional:Bool = part.charAt(0) == '?';
			shape.opt.push(optional);
			shape.key.push(optional ? part.substr(1) : part);
		}

		return shape;
	}
}

/** One constructor's parameters: which are optional, and what each takes. */
private class Shape {
	/** Whether each parameter may be skipped. */
	public var opt:Array<Bool> = [];

	/** What each parameter takes, empty for one that takes anything. */
	public var key:Array<String> = [];

	public function new() {}
}
