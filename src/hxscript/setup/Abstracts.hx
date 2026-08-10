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
		var re:EReg = ~/^[ \t]*(@:[^\n]*[ \t]+)*(private[ \t]+)?abstract[ \t]+([A-Za-z_][A-Za-z0-9_]*)/gm;

		var at:Int = 0;
		while (re.matchSub(source, at)) {
			found.push(re.matched(3));
			var p = re.matchedPos();
			at = p.pos + p.len;
		}

		return found;
	}
}
#end
