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

			for (name in declaredAbstracts(File.getContent(full)))
				wrap((name == module) ? '$pack.$module' : '$pack.$module.$name', exclude, wrapped);
		}
	}

	/**
	 * Applies the wrapper build macro to one abstract.
	 *
	 * @param path The abstract's path.
	 * @param exclude Paths to leave alone.
	 * @param wrapped Collects what was wrapped.
	 */
	static function wrap(path:String, exclude:Array<String>, wrapped:Array<String>):Void {
		if (exclude.indexOf(path) >= 0 || wrapped.indexOf(path) >= 0)
			return;

		Compiler.addMetadata('@:build(hxscript.macro.Abstract.build())', path);
		wrapped.push(path);
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

		var at:Int = 0;
		while (re.matchSub(source, at)) {
			found.push(re.matched(4));
			var p = re.matchedPos();
			at = p.pos + p.len;
		}

		return found;
	}
}
#end
