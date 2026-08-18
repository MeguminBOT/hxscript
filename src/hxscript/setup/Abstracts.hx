package hxscript.setup;

#if macro
import haxe.macro.Compiler;
import haxe.macro.Context;
import sys.FileSystem;
import sys.io.File;

/** Gives the abstracts scripts hold a runtime form, which is `Autowire`'s wrapping step. */
class Abstracts {
	/**
	 * Wraps every abstract named or scanned for by the active libraries.
	 *
	 * @param libs The active libraries.
	 * @return The paths wrapped, for the manifest to report.
	 */
	public static function generate(libs:Array<Library>):Array<String> {
		var wrapped:Array<String> = [];

		if (Context.defined('hxscript_no_abstracts'))
			return wrapped;

		var exclude:Array<String> = [];
		for (lib in libs)
			for (name in lib.abstractExclude)
				exclude.push(name);

		for (lib in libs) {
			for (pack in lib.abstractPackages)
				for (dir in Context.getClassPath())
					scan(dir + pack.split('.').join('/'), pack, exclude, wrapped);

			for (path in lib.abstracts)
				wrap(path, exclude, wrapped);
		}

		if (Context.defined('hxscript_verbose')) {
			Context.info('  ${wrapped.length} abstract(s) exposed to scripts', Context.currentPos());
			for (path in wrapped)
				Context.info('    $path', Context.currentPos());
		}

		return wrapped;
	}

	/**
	 * Applies the macro to each abstract declared in one directory, recursing into sub-packages.
	 *
	 * @param dir The directory on disk.
	 * @param pack The package it holds.
	 * @param exclude Paths to leave alone.
	 * @param wrapped Collects what was wrapped.
	 */
	static function scan(dir:String, pack:String, exclude:Array<String>, wrapped:Array<String>):Void {
		if (!FileSystem.exists(dir) || !FileSystem.isDirectory(dir))
			return;

		for (entry in FileSystem.readDirectory(dir)) {
			var full:String = '$dir/$entry';

			if (FileSystem.isDirectory(full)) {
				scan(full, '$pack.$entry', exclude, wrapped);
				continue;
			}

			if (!StringTools.endsWith(entry, '.hx'))
				continue;

			var module:String = entry.substr(0, entry.length - 3);

			for (name in declaredAbstracts(File.getContent(full))) {
				/**
				 * The build is applied to the package and the name, with the module left out.
				 *
				 * `Compiler.addMetadata` takes the path a type is *declared* under, which is its package
				 * and its own name. A module only decides where a type is written down, so it is absent
				 * from that path, and `flixel.text.FlxText.FlxTextAlign` matched nothing. Metadata on a
				 * path nothing declares is not an error, so every abstract sharing a module with another
				 * type was silently never built: no `AbstractValue_*` was emitted, `AbstractTools.resolve`
				 * answered null, and a script importing one bound the name to nothing and failed on use
				 * with `Module FlxTextAlign does not define type FlxTextAlign`. Of flixel's abstracts only
				 * the eleven written in a module of their own were reached.
				 *
				 * Two names in one package cannot collide, so dropping the module cannot aim this at the
				 * wrong abstract. It is still reported under the path a script imports, which does need
				 * the module.
				 */
				wrap('$pack.$name', exclude, wrapped, (name == module) ? null : '$pack.$module.$name');
			}
		}
	}

	/**
	 * Applies the wrapper build macro to one abstract.
	 *
	 * @param path The path to apply the build to, which for a sub-type is its implementation class.
	 * @param exclude Paths to leave alone.
	 * @param wrapped Collects what was wrapped.
	 * @param reported How to name it in the report, which is the abstract rather than its
	 *        implementation. Defaults to `path`, which is the same thing for a top-level abstract.
	 */
	static function wrap(path:String, exclude:Array<String>, wrapped:Array<String>, ?reported:String):Void {
		var name:String = reported == null ? path : reported;

		if (exclude.indexOf(path) >= 0 || exclude.indexOf(name) >= 0 || wrapped.indexOf(name) >= 0)
			return;

		Compiler.addMetadata('@:build(hxscript.macro.Abstract.build())', declared(path));
		wrapped.push(name);
	}

	/**
	 * The path a type is declared under, which is what `Compiler.addMetadata` matches on.
	 *
	 * A preset's `abstracts` list is written by hand, so it may name a sub-type the way a script
	 * imports it, `flixel.text.FlxText.FlxTextAlign`. That is a module and a type, and the declared
	 * path is the package and the type, so the module comes out. Getting this wrong is silent: the
	 * metadata lands on nothing, no wrapper is built, and the abstract is unusable rather than absent,
	 * which is what the scan itself did to two thirds of what it found.
	 *
	 * Haxe requires a package name to begin lowercase, so a segment before the last that begins
	 * uppercase is a module and never a package. That makes the two spellings tellable apart here
	 * without touching the file system.
	 *
	 * @param path The path as written.
	 * @return The same path with a module segment removed, if there was one.
	 */
	public static function declared(path:String):String {
		var parts:Array<String> = path.split('.');
		if (parts.length < 3)
			return path;

		var module:String = parts[parts.length - 2];
		var lead:String = module.charAt(0);
		if (lead != lead.toUpperCase())
			return path;

		return parts.slice(0, parts.length - 2).concat([parts[parts.length - 1]]).join('.');
	}

	/**
	 * The abstracts a source file declares.
	 *
	 * Text, not the typer: this runs before typing, and asking the typer for a module here would
	 * force it to be typed at the wrong moment.
	 *
	 * @param source The file's contents.
	 * @return The declared abstract names.
	 */
	public static function declaredAbstracts(source:String):Array<String> {
		var found:Array<String> = [];

		/**
		 * The modifiers Haxe allows in front of `abstract`, and `enum` is the one that matters.
		 *
		 * `enum abstract Foo(Int)` is how every enum abstract has been written since Haxe 4, and this
		 * pattern only allowed metadata and `private`, so the whole shape was skipped without a word.
		 * In flixel that is `FlxKey`, `FlxAxes` and every other keyed constant: a script importing one
		 * got the module registered with no type behind it, and using it failed at run time with
		 * `Module FlxKey does not define type FlxKey`. Eight of flixel's abstracts were reached and
		 * the rest were not, which looked like a preset that had missed a few rather than a pattern
		 * that could not see them.
		 *
		 * `extern` is allowed for the same reason: it is legal in front of `abstract` and nothing here
		 * should turn on which order the modifiers were written in.
		 */
		var re:EReg = ~/^[ \t]*(@:[^\n]*[ \t]+)*((private|extern|enum)[ \t]+)*abstract[ \t]+([A-Za-z_][A-Za-z0-9_]*)/gm;

		/**
		 * What may follow `abstract` and not be an abstract's name.
		 *
		 * `abstract` is also a class modifier and a method modifier in Haxe 4, so `abstract class Foo`
		 * and `abstract public function f()` both match the pattern above and hand back the keyword
		 * after it. flixel's `FlxBaseTilemap` has all three shapes and produced
		 * `FlxBaseTilemap.class`, `.public` and `.function`, which were then handed to
		 * `Compiler.addMetadata` as though they were types. Nothing failed, because metadata on a path
		 * nothing declares does nothing, so the only symptom was three junk entries in the count
		 * `-D hxscript_verbose` prints.
		 *
		 * The same shape as the `enum` fix above, from the other side: that one was a modifier before
		 * `abstract` the pattern did not know, this is a keyword after it.
		 */
		var keywords:Array<String> = [
			'class',
			'function',
			'public',
			'private',
			'static',
			'inline',
			'final',
			'override',
			'dynamic',
			'extern',
			'macro',
			'var',
			'enum',
			'interface',
			'typedef'
		];

		var at:Int = 0;
		while (re.matchSub(source, at)) {
			var name:String = re.matched(4);
			if (keywords.indexOf(name) < 0)
				found.push(name);

			var p = re.matchedPos();
			at = p.pos + p.len;
		}

		return found;
	}
}
#end
