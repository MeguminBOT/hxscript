package hxscript.setup;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.Type;
import sys.FileSystem;

/**
 * Generates one bridge per base scripts may extend, which is `Autowire`'s bridging step.
 *
 * **A bridge is the only way a script can extend something the host compiled**, and the reason is
 * not a limitation of this library: a native base's methods can only be overridden by a subclass
 * that existed when the host was built, and a script does not exist then. The bridge is that
 * subclass, generated ahead of time, overriding what the base offers and forwarding into the
 * interpreter. So "any class can be extended" means "any class you bridged", and what follows is the
 * three ways of deciding which.
 *
 * - by default, the curated `bases` list of each active library, which is small and costs little;
 * - `-D hxscript_bridge_types=StringBuf,game.Actor`, exactly those classes;
 * - `-D hxscript_bridge_packages=flixel,openfl.display`, every eligible class under those roots;
 * - `-D hxscript_bridge_all`, every eligible class under every active library's roots.
 *
 * The last two are compile-time decisions about binary size, and they are not free: a bridge carries
 * one generated override per inherited non-`inline`, non-`final` method. `-D hxscript_verbose`
 * reports what was bridged and what was passed over, so the cost and the coverage are both visible
 * rather than guessed at.
 */
class Bridges {
	/** The package generated bridges are defined in. */
	static inline var PACK:String = 'hxscript.wired';

	/**
	 * Defines one bridge per base across every active library.
	 *
	 * A `final` class cannot be bridged at all, which is occasionally the right trade: keeping a
	 * hot-path class `final` lets hxcpp devirtualise calls to it.
	 *
	 * @param libs The active libraries.
	 * @return Expressions referencing each generated bridge, for the manifest to hold.
	 */
	public static function generate(libs:Array<Library>):Array<Expr> {
		var refs:Array<Expr> = [];

		if (Context.defined('hxscript_no_bridges'))
			return refs;

		var pos:Position = Context.currentPos();
		var pack:Array<String> = PACK.split('.');
		var taken:Map<String, String> = [];

		var every:Array<String> = [];
		var listed:Map<String, Bool> = [];

		/**
		 * Each base once, however many ways it arrived. A curated preset and a package scan name the
		 * same class routinely, and the second arrival matched a name already taken by itself, so
		 * every bridged base warned that it was being skipped for colliding with itself. Nothing was
		 * lost, since the bridge was made on the first arrival, but ten such lines per build read as
		 * ten bridges missing.
		 */
		function want(base:String):Void {
			if (listed.exists(base))
				return;

			listed.set(base, true);
			every.push(base);
		}

		for (lib in libs)
			for (base in lib.bases)
				want(base);

		for (base in scanned(libs))
			want(base);

		{
			for (base in every) {
				var parts:Array<String> = base.split('.');
				var superPath:TypePath = {name: parts[parts.length - 1], pack: parts.slice(0, parts.length - 1)};
				var name:String = 'Scripted' + superPath.name;

				if (Autowire.resolve(base) == null) {
					if (!Autowire.declared(base))
						Context.warning('hxscript: no module found for bridged base $base; scripts cannot extend it', pos);

					continue;
				}

				/**
				 * Two bases with the same simple name are ordinary, not exotic. heaps has `h2d.Object`
				 * and `h3d.scene.Object`, and a bridge named after the last segment alone meant the
				 * second was dropped with a warning nobody reads, so a scripted 3D project could not
				 * exist. Whichever comes first keeps the short name, since bridges are indexed by the
				 * base they extend rather than by what they are called and only a person reads these.
				 */
				if (taken.exists(name) && taken.get(name) != base)
					name = 'Scripted' + flatten(base);

				if (taken.exists(name)) {
					Context.warning('hxscript: bridge name $name already taken by ${taken.get(name)}; skipping $base', pos);
					continue;
				}
				taken.set(name, base);

				Context.defineModule('$PACK.$name', [
					{
						pack: pack,
						name: name,
						pos: pos,
						meta: [{name: ':keep', pos: pos}],
						kind: TDClass(superPath, [{pack: ['hxscript'], name: 'IScripted'}], false, false, false),
						fields: []
					}
				]);

				refs.push(macro $p{pack.concat([name])});
			}
		}

		if (Context.defined('hxscript_verbose')) {
			Context.info('  ${refs.length} bridge(s)', pos);
			for (name => base in taken)
				Context.info('    $PACK.$name extends $base', pos);

			for (path => why in passed)
				Context.info('    not bridged: $path ($why)', pos);
		}

		return refs;
	}

	/**
	 * @param path A type path.
	 * @return It as one capitalised word, so `h3d.scene.Object` becomes `H3dSceneObject`.
	 */
	static function flatten(path:String):String {
		var out:String = '';

		for (part in path.split('.'))
			out += part.length == 0 ? '' : part.charAt(0).toUpperCase() + part.substr(1);

		return out;
	}

	/** Types a scan found and would not bridge, and why, for the verbose report. */
	static var passed:Map<String, String> = [];

	/**
	 * The extra bases the scanning defines turn up.
	 *
	 * Nothing is scanned unless a define asks for it, so a build that names neither does exactly what
	 * it did before and pays nothing for this existing.
	 *
	 * @param libs The active libraries, which is what `-D hxscript_bridge_all` covers.
	 * @return Fully-qualified paths, which `generate` treats exactly as it treats a curated one.
	 */
	static function scanned(libs:Array<Library>):Array<String> {
		var roots:Array<String> = [];
		var found:Array<String> = [];

		/**
		 * Types named one by one, which is the third way and the smallest. A package scan is the
		 * right tool for `flixel.*`; it is the wrong one for wanting scripts to be able to extend
		 * `StringBuf`, which is in the root package and would drag the standard library in with it.
		 */
		var listed:Null<String> = Context.definedValue('hxscript_bridge_types');

		if (listed != null) {
			for (raw in listed.split(',')) {
				var one:String = StringTools.trim(raw);
				if (one.length > 0 && eligible(one))
					found.push(one);
			}
		}

		/**
		 * The named packages are taken as written and are not matched against a library, because the
		 * packages most worth bridging are the host's own and no library declares those.
		 */
		var named:Null<String> = Context.definedValue('hxscript_bridge_packages');

		if (named != null) {
			for (raw in named.split(',')) {
				var one:String = StringTools.trim(raw);
				if (one.length > 0)
					roots.push(one);
			}
		}

		if (Context.defined('hxscript_bridge_all'))
			for (lib in libs)
				for (root in lib.roots)
					roots.push(root);

		if (roots.length == 0)
			return found;

		var seen:Map<String, Bool> = [];

		for (root in roots) {
			for (path in modulesUnder(root)) {
				if (seen.exists(path))
					continue;

				seen.set(path, true);

				if (eligible(path))
					found.push(path);
			}
		}

		return found;
	}

	/**
	 * Every module path under a package root, recursively.
	 *
	 * The classpath is walked rather than the type table, because the table holds what the build has
	 * already typed and a class nobody referenced is exactly the kind a script wants to extend.
	 *
	 * @param root The package.
	 * @return Fully-qualified module paths.
	 */
	static function modulesUnder(root:String):Array<String> {
		var found:Array<String> = [];
		var relative:String = root.split('.').join('/');

		for (dir in Context.getClassPath()) {
			var at:String = dir + relative;
			if (!FileSystem.exists(at) || !FileSystem.isDirectory(at))
				continue;

			walk(at, root, found);
		}

		return found;
	}

	/**
	 * @param dir The directory to read.
	 * @param pack The package it holds.
	 * @param into Filled with what is found.
	 */
	static function walk(dir:String, pack:String, into:Array<String>):Void {
		for (entry in FileSystem.readDirectory(dir)) {
			var at:String = dir + '/' + entry;

			if (FileSystem.isDirectory(at)) {
				walk(at, pack + '.' + entry, into);
				continue;
			}

			/** `import.hx` is a package's own import list rather than a type, and resolves to nothing. */
			if (entry == 'import.hx')
				continue;

			if (StringTools.endsWith(entry, '.hx'))
				into.push(pack + '.' + entry.substr(0, entry.length - 3));
		}
	}

	/**
	 * Whether a scanned type is one a bridge can be generated for.
	 *
	 * Everything rejected here would either fail the build or produce a bridge that cannot work, and
	 * each is recorded so `-D hxscript_verbose` can say which. A curated base skips this: naming one
	 * is a decision already made, and a warning is more useful there than a silent omission.
	 *
	 * @param path The module path.
	 * @return Whether to bridge it.
	 */
	static function eligible(path:String):Bool {
		var found:Null<Type> = Autowire.resolve(path);

		if (found == null) {
			passed.set(path, 'nothing resolved');
			return false;
		}

		switch (found) {
			case TInst(ref, _):
				var cls:ClassType = ref.get();

				if (cls.isExtern) {
					passed.set(path, 'extern');
					return false;
				}

				if (cls.isFinal) {
					passed.set(path, 'final');
					return false;
				}

				if (cls.isInterface) {
					passed.set(path, 'an interface');
					return false;
				}

				if (cls.isPrivate) {
					passed.set(path, 'private');
					return false;
				}

				if (cls.params.length > 0) {
					passed.set(path, 'has type parameters, which erase and cannot be substituted');
					return false;
				}

				if (cls.constructor == null) {
					passed.set(path, 'has no constructor of its own to reconstruct');
					return false;
				}

				return true;

			case _:
				passed.set(path, 'not a class');
				return false;
		}
	}
}
#end
