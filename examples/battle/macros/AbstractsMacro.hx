package macros;

#if macro
import haxe.macro.Compiler;
import haxe.macro.Context;
import sys.FileSystem;
import sys.io.File;

/**
 * Makes the build's abstracts usable from scripts, without touching the abstracts themselves.
 *
 * `hxscript.macro.Abstract` emits the reflectable wrapper an abstract needs to exist at
 * runtime, but it is a `@:build` macro, so something has to apply it. Writing
 * `@:build(hxscript.macro.Abstract.build())` on your own abstract is fine; the abstracts a
 * host actually wants scriptable are usually in libraries it does not own, and those cannot be
 * annotated. `Compiler.addMetadata` applies it from outside, which works for both.
 *
 * This scans a package for `abstract` declarations rather than keeping a hand-written list. A list
 * is discovered the hard way: a runtime "Unknown identifier" from somebody's script, then a rebuild
 * to add one line.
 *
 * Two shapes are known to break the generator, so a package-wide filter is not an option, because it does
 * not degrade on them, it fails the build:
 *
 * - an `enum abstract` with a value-less constructor (`var Red;` with no `= 0`), and
 * - an abstract whose members call each other unqualified.
 *
 * Name those in `EXCLUDE`. A real host scans several packages and skips more; see
 * [docs/advanced.md](../../../docs/advanced.md) for the flixel and openfl lists.
 *
 * Applying the macro is only half of it: the abstract also has to BE in the build. A type nothing
 * compiled references is never typed, and metadata on a type that does not exist does nothing, so
 * the script then fails with `Type not found`, which does not point at the cause. Pair this with
 * an include of the same package.
 *
 * Run it from the build:
 *
 *     --macro macros.AbstractsMacro.generate() --macro include('game')
 */
class AbstractsMacro {
	/** Packages scanned for abstracts. */
	static final PACKAGES:Array<String> = ['game'];

	/** Abstracts the generator cannot wrap, by fully-qualified name. */
	static final EXCLUDE:Array<String> = [];

	/** Applies the build macro to every abstract found under `PACKAGES`. */
	public static function generate():Void {
		for (pack in PACKAGES)
			for (dir in Context.getClassPath())
				scan(dir + pack.split('.').join('/'), pack);
	}

	/**
	 * Applies the macro to each abstract declared in one directory, recursing into sub-packages.
	 *
	 * @param dir The directory on disk.
	 * @param pack The package it holds.
	 */
	static function scan(dir:String, pack:String):Void {
		if (!FileSystem.exists(dir) || !FileSystem.isDirectory(dir))
			return;

		for (entry in FileSystem.readDirectory(dir)) {
			var full:String = '$dir/$entry';

			if (FileSystem.isDirectory(full)) {
				scan(full, '$pack.$entry');
				continue;
			}

			if (!StringTools.endsWith(entry, '.hx'))
				continue;

			// A module can hold several types, and only the one sharing the file's name is addressable
			// as `pack.Name`; the rest need `pack.Module.Name`. Both spellings are emitted, since an
			// abstract that is not there is simply not matched.
			var module:String = entry.substr(0, entry.length - 3);
			for (name in declaredAbstracts(File.getContent(full))) {
				var path:String = (name == module) ? '$pack.$module' : '$pack.$module.$name';
				if (EXCLUDE.contains(path))
					continue;

				Compiler.addMetadata('@:build(hxscript.macro.Abstract.build())', path);
			}
		}
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
	static function declaredAbstracts(source:String):Array<String> {
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
