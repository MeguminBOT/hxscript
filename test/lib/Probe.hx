import hxscript.types.TypeCollection;

/**
 * Writes one `import` per type in the build, runs it, and reports what a script actually got.
 *
 * Run by `test/lib/reach.py`, once per shipped stack, with the package prefixes to report on as
 * arguments. Everything it prints is measured: the question is never whether a record names a type,
 * it is whether a script author writing the ordinary `import` at the top of a file ends up holding
 * something they can use.
 *
 * Output is one tab-separated row per type after the `##ROWS` marker, so the generator can read it
 * without parsing prose: path, kind, status, detail.
 */
class Probe {
	/**
	 * A type is *usable* when the name a script imported has a runtime identity behind it.
	 *
	 * Binding is not enough on its own. An abstract with no wrapper, a typedef of an anonymous shape
	 * and a name that resolved to nothing all bind without complaint and then answer nothing on first
	 * use, which is the failure this exists to catch. A class or enum the target can still name at run
	 * time is one a script can construct, call a static on, or hold.
	 *
	 * @param v Whatever the script's last expression evaluated to.
	 * @return Why it is unusable, or null when it is fine.
	 */
	static function unusable(v:Dynamic):Null<String> {
		/**
		 * The binding, and nothing reflective on top of it.
		 *
		 * This asked `Type.getClassName(cast v)` first, which no two targets agree about: eval answers
		 * null for a value that is not a class, HashLink throws `Can't cast h2d.$BlendMode to hl.Class`,
		 * and hxcpp takes an access violation and loses the whole run with it. The question it was
		 * asking is answered without it anyway. Whether the name bound is right here; whether what it
		 * bound has a runtime form is `reason`, off the type index, which is the same answer on every
		 * target because it is not reflection.
		 */
		return v == null ? 'the import bound nothing' : null;
	}

	/**
	 * Why a type of this kind is unreachable, when the kind alone is enough to say.
	 *
	 * The interpreter's own message is the same sentence 273 times over, `Module X does not define
	 * type X`, which is accurate and tells a reader nothing about what to do. These are the two causes
	 * behind nearly all of them, and each has a different answer: one is a preset that can be widened,
	 * the other is a shape with no runtime form at all and nothing to widen.
	 *
	 * @param info What the index knows about it.
	 * @return A reason, or null to fall back to what the interpreter said.
	 */
	static function reason(info:TypeInfo):Null<String> {
		if (info == null)
			return null;

		if (info.kind == 'abstract') {
			var wrapper:Dynamic = hxscript.types.AbstractTools.resolve(TypeCollection.compilePath(info));
			if (wrapper == null)
				return 'no wrapper was generated, so it has no runtime form';
		}

		if (info.kind == 'typedef')
			return 'a function or anonymous shape, which has no runtime form to bind';

		return null;
	}

	/**
	 * @param path The path an import would write, which is `module.Name`.
	 * @param info What the index knows about it, for a better answer than the interpreter's.
	 * @return The status and the detail behind it.
	 */
	static function check(path:String, info:TypeInfo):{status:String, detail:String} {
		var name:String = path.split('.').pop();
		var why:String = null;

		hxscript.error.Sink.printing = false;
		hxscript.error.Sink.onDiagnostic.push(function(d):Void {
			if (why == null)
				why = d.message;
		});

		var v:Dynamic = null;
		try {
			v = new hxscript.Script('import $path;\n$name', 'probe').start();
		} catch (e:Dynamic) {
			why = Std.string(e);
		}

		hxscript.error.Sink.onDiagnostic.pop();

		if (why != null)
			return {status: 'no', detail: reason(info) ?? trim(why)};

		var bad:Null<String> = unusable(v);
		if (bad == null)
			return {status: 'yes', detail: ''};

		return {status: 'no', detail: reason(info) ?? bad};
	}

	/**
	 * Whether a type belongs to one of the packages being reported on.
	 *
	 * Matched as a package rather than a first segment, because haxe.ui lives under `haxe` and a first
	 * segment of `haxe` is also every typedef in the standard library. Comparing against `haxe.ui`
	 * keeps `haxe.ui.components.Button` and drops `haxe.ds.StringMap`, which the shorter test could
	 * not tell apart.
	 *
	 * @param path The type's path.
	 * @param packs The packages to report on.
	 * @return Whether the path is in one of them.
	 */
	static function within(path:String, packs:Array<String>):Bool {
		for (pack in packs)
			if (path == pack || StringTools.startsWith(path, pack + '.'))
				return true;

		return false;
	}

	/** Strips the interpreter's own prefix, which is the same on every row and says nothing. */
	static function trim(message:String):String {
		var at:Int = message.indexOf('script probe: ');
		var out:String = at < 0 ? message : message.substr(at + 'script probe: '.length);
		return StringTools.replace(StringTools.replace(out, '\n', ' '), '\t', ' ');
	}

	/**
	 * The entry point when this is a plain console program, which is every stack without lime in it.
	 *
	 * A stack with lime cannot be one: the flixel family will not run as a bare hxcpp binary at all,
	 * dying at `0xC0000005` before `main` because lime supplies the entry point and the native wiring
	 * a console build never gets. `run` is what that build calls instead, from a generated lime app.
	 */
	static function main():Void {
		var args:Array<String> = Sys.args();

		if (args.length == 0) {
			Sys.stderr().writeString('usage: Probe <out.tsv> [package ...]\n');
			Sys.exit(2);
		}

		run(args[0], args.slice(1));
	}

	/**
	 * Writes one row per type in the build to `file`.
	 *
	 * @param file Where the rows go.
	 * @param packs Top-level packages to report on, or empty for all of them.
	 */
	public static function run(file:String, packs:Array<String>):Void {
		hxscript.setup.Boot.ensure();
		hxscript.error.Sink.printing = false;

		/**
		 * Everything on stdout has to be a row. A typedef whose target the interpreter cannot represent
		 * is announced with a bare `trace`, which is right for a person running a script and wrong here:
		 * fifty-odd of them landed between the rows and the generator read them as malformed data. The
		 * fact is not lost, since that same typedef is about to be reported as unusable anyway.
		 */
		haxe.Log.trace = function(v:Dynamic, ?pos:haxe.PosInfos):Void {};

		/**
		 * Rows go to a file rather than to stdout, and each is flushed as it is written.
		 *
		 * A native build buffers stdout in blocks when it is redirected, so a crash anywhere in the
		 * loop throws away everything measured before it, including the `##ROWS` marker printed first.
		 * That is exactly the case worth diagnosing, and it presented as a program that ran and said
		 * nothing at all. Written this way the file always holds what was reached, and the last row in
		 * it names the type that was being tried.
		 */
		var out:sys.io.FileOutput = sys.io.File.write(file);
		var paths:Array<String> = [];

		for (info in TypeCollection.main.types.all) {
			var path:String = TypeCollection.fullPath(info);
			if (path == null)
				continue;

			/**
			 * An abstract's implementation class is not importable under any spelling, and neither is
			 * anything else in a package Haxe underscores. Reporting them as unusable would be true and
			 * useless, since no script would ever write the name.
			 */
			if (path.indexOf('_Impl_') >= 0 || path.indexOf('._') >= 0)
				continue;

			/** The wrappers this library generates for abstracts. A script names the abstract instead. */
			if (info.name.indexOf('AbstractValue_') == 0)
				continue;

			if (packs.length > 0 && !within(path, packs))
				continue;

			/**
			 * A type alone in its module is written without repeating the name. `fullPath` is always
			 * `module.Name`, so a top-level type comes out as `flixel.FlxBasic.FlxBasic`, which is legal
			 * Haxe nobody writes. The doc is a list of imports to copy, so it carries the short form.
			 */
			var parts:Array<String> = path.split('.');
			if (parts.length >= 2 && parts[parts.length - 1] == parts[parts.length - 2])
				path = parts.slice(0, parts.length - 1).join('.');

			if (paths.indexOf(path) < 0)
				paths.push(path);
		}

		paths.sort(function(a:String, b:String):Int return a < b ? -1 : (a > b ? 1 : 0));

		out.writeString('##ROWS\n');
		out.flush();

		for (path in paths) {
			var found:Array<TypeInfo> = TypeCollection.main.fromPath(path);
			var info:TypeInfo = found == null || found.length == 0 ? null : found[0];
			var kind:String = info == null ? '?' : info.kind;
			var r = check(path, info);
			out.writeString('$path\t$kind\t${r.status}\t${r.detail}\n');
			out.flush();
		}

		out.close();
	}
}
