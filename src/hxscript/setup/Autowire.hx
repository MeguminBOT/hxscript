package hxscript.setup;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;
import sys.FileSystem;
import sys.io.File;

/**
 * The compile-time half of embedding, and the only thing a build file needs, since
 * `extraParams.hxml` runs it for anyone who writes `-lib hxscript`. It runs three steps per active
 * library: include the types, bridge the bases, wrap the abstracts. The fourth, shimming members
 * with no runtime form, is a closure rather than a name and runs from `Boot` at startup.
 */
class Autowire {
	/** The package the generated manifest and bridges are defined in. */
	static inline var PACK:String = 'hxscript.wired';

	/**
	 * The whole of the compile-time setup.
	 *
	 * Called from `extraParams.hxml`, so no build file has to name it.
	 */
	public static function run():Void {
		/**
		 * The native module first, and outside the autowire switch. What it produces is what lets a
		 * HashLink host compile a script at all, which is a different question from which game
		 * library's types to wire in, and a build that turned the wiring off still wants the module.
		 */
		Native.run();

		if (Context.defined('hxscript_no_autowire'))
			return;

		/**
		 * The list is read after the init macros rather than during them, and that is the whole of
		 * what lets a host's own record arrive.
		 *
		 * `Presets.custom` is filled from an init macro the host writes, and no build file can make
		 * that macro run before this one: lime resolves each haxelib and writes its
		 * `extraParams.hxml` at the top of the generated hxml, beside the library's own class path,
		 * while the project's own flags land some fifty lines below. So `--macro
		 * hxscript.setup.Autowire.run()` is always the earlier of the two, and a list read when it
		 * runs is a list taken before the host had a chance to add to it.
		 */
		Context.onAfterInitMacros(function():Void {
			var libs:Array<Library> = Presets.active();

			var host:Library = hostLibrary();
			if (host != null)
				libs.push(host);

			if (Context.defined('hxscript_verbose'))
				Context.info('hxscript: wiring ' + [for (lib in libs) lib.title].join(', '), Context.currentPos());

			include(libs);

			var abstracts:Array<String> = Abstracts.generate(libs);

			var globals:Array<String> = [];
			for (lib in libs)
				for (path in lib.globals)
					if (globals.indexOf(path) < 0)
						globals.push(path);

			/**
			 * Registered from inside this one rather than beside it, because `include` defers its own
			 * walk the same way and the bridges below read the types that walk is what puts in the
			 * build. Callbacks added while the queue is draining are still run, in the order they
			 * were added, so this arrives after the walk it depends on.
			 */
			Context.onAfterInitMacros(function():Void {
				var forced:{refs:Array<Expr>, args:Array<FunctionArg>, named:Array<String>} = reference(libs);
				var bridges:Array<Expr> = Bridges.generate(libs);
				var titles:Array<String> = [for (lib in libs) lib.title];

				manifest(bridges, forced, globals, abstracts, titles);
				hxscript.macro.Banner.wired(titles, bridges.length, forced.named.length, abstracts.length, globals.length);
			});
		});
	}

	/**
	 * Resolves a type path, or null when this build does not have it.
	 *
	 * @param path The fully-qualified type path.
	 * @return The type, or null.
	 */
	public static function resolve(path:String):Null<haxe.macro.Type> {
		try {
			return Context.getType(path);
		} catch (e:Dynamic) {
			return null;
		}
	}

	/**
	 * Whether some classpath holds a module file that could declare a path.
	 *
	 * Only used to decide whether a type this build could not resolve is worth reporting. The last
	 * segment is dropped and retried, because a sub-type lives in its module's file rather than in
	 * one of its own.
	 *
	 * @param path The fully-qualified type path.
	 * @return Whether a file for it exists.
	 */
	public static function declared(path:String):Bool {
		if (fileFor(path))
			return true;

		var at:Int = path.lastIndexOf('.');
		return at > 0 && fileFor(path.substr(0, at));
	}

	/**
	 * @param path A module path.
	 * @return Whether a file for it exists on some classpath.
	 */
	static function fileFor(path:String):Bool {
		var relative:String = path.split('.').join('/') + '.hx';

		for (dir in Context.getClassPath())
			if (FileSystem.exists(dir + relative))
				return true;

		return false;
	}

	/**
	 * Force-compiles every active library's package roots.
	 *
	 * The walk is deferred rather than done here, because the types it pulls in have to arrive after
	 * the build metadata `Abstracts` registers for them, and metadata does nothing to a type that is
	 * already loaded. `Compiler.include` defers its own walk for the same reason and would have done,
	 * but it asserts it was called from an init macro, and by the time the active libraries are known
	 * this is running out of `onAfterInitMacros` instead. So the walk is here, minus the assert.
	 *
	 * @param libs The active libraries.
	 */
	static function include(libs:Array<Library>):Void {
		var ignore:Array<String> = [];
		for (lib in libs)
			for (name in lib.ignore)
				if (ignore.indexOf(name) < 0)
					ignore.push(name);

		var roots:Array<String> = [];
		for (lib in libs) {
			for (root in lib.roots) {
				if (roots.indexOf(root) < 0)
					roots.push(root);

				if (Context.defined('hxscript_verbose'))
					Context.info('  include $root (recursive)', Context.currentPos());
			}
		}

		if (Context.defined('hxscript_verbose') && ignore.length > 0)
			Context.info('  skipping ' + ignore.join(', '), Context.currentPos());

		Context.onAfterInitMacros(function():Void {
			var paths:Array<String> = searchPaths();
			if (paths == null)
				return;

			for (root in roots)
				walk(root, paths, ignore);
		});
	}

	/**
	 * The class paths a package walk searches, normalised the way `Compiler.include` normalises them.
	 *
	 * @return The paths, or null for a completion request, which must not force anything into a build
	 * it is only asking questions about.
	 */
	static function searchPaths():Array<String> {
		switch (Context.definedValue('display')) {
			case null:
			case 'usage':
			case _:
				return null;
		}

		var out:Array<String> = [];
		for (cp in Context.getClassPath()) {
			/**
			 * `normalize` is what turns a Windows class path into one the walk can join with `/`, and
			 * it drops a trailing separator on the way, which is the rest of what `Compiler.include`
			 * does to these before it looks at them.
			 */
			var path:String = haxe.io.Path.normalize(cp);

			out.push(path == '' ? '.' : path);
		}

		return out;
	}

	/**
	 * One package root, force-compiled by loading every module under it.
	 *
	 * @param pack The package to walk.
	 * @param paths The class paths to look for it in.
	 * @param ignore Packages and modules to leave out.
	 */
	static function walk(pack:String, paths:Array<String>, ignore:Array<String>):Void {
		var prefix:String = pack == '' ? '' : pack + '.';

		for (cp in paths) {
			var dir:String = pack == '' ? cp : cp + '/' + pack.split('.').join('/');
			if (!FileSystem.exists(dir) || !FileSystem.isDirectory(dir))
				continue;

			for (entry in FileSystem.readDirectory(dir)) {
				if (FileSystem.isDirectory('$dir/$entry')) {
					if (!ignored(prefix + entry, ignore))
						walk(prefix + entry, paths, ignore);

					continue;
				}

				if (!StringTools.endsWith(entry, '.hx'))
					continue;

				/**
				 * `import.hx` is not a module, and a name with a dot left in it after the extension
				 * comes off is a module nothing can load by that name: `Macro.macro.hx` is the shape
				 * a host writes for macro-only code. `Compiler.include` leaves both out and so does
				 * this, which is why a host's macro package needs no ignore entry of its own.
				 */
				var name:String = entry.substr(0, entry.length - 3);
				if (entry == 'import.hx' || name.indexOf('.') >= 0)
					continue;

				if (!ignored(prefix + name, ignore))
					Context.getModule(prefix + name);
			}
		}
	}

	/**
	 * Whether a package or module path is one to leave out.
	 *
	 * @param path The dot path.
	 * @param ignore The entries to match, by name or by a trailing `*`.
	 * @return Whether it is ignored.
	 */
	static function ignored(path:String, ignore:Array<String>):Bool {
		for (rule in ignore) {
			if (StringTools.endsWith(rule, '*')) {
				if (StringTools.startsWith(path, rule.substr(0, rule.length - 1)))
					return true;
			} else if (rule == path)
				return true;
		}

		return false;
	}

	/**
	 * Collects the modules to force-compile by **referencing** them rather than by including a package.
	 *
	 * @param libs The active libraries.
	 * @return The reference expressions, the signature arguments, and what was named.
	 */
	static function reference(libs:Array<Library>):{refs:Array<Expr>, args:Array<FunctionArg>, named:Array<String>} {
		var pos:Position = Context.currentPos();
		var refs:Array<Expr> = [];
		var args:Array<FunctionArg> = [];
		var named:Array<String> = [];

		for (lib in libs) {
			for (path in lib.types) {
				if (named.indexOf(path) >= 0)
					continue;

				var type:haxe.macro.Type = resolve(path);

				if (type == null) {
					if (!declared(path))
						Context.warning('hxscript: no module found for $path; scripts cannot name it', pos);

					continue;
				}

				named.push(path);

				args.push({name: 'a${args.length}', type: Context.toComplexType(type), opt: true});

				switch (type) {
					case TAbstract(_, _) | TEnum(_, _):

					case _:
						refs.push(macro $p{path.split('.')});
				}
			}
		}

		if (Context.defined('hxscript_verbose') && named.length > 0) {
			Context.info('  ${named.length} module(s) forced in by reference', pos);
			for (path in named)
				Context.info('    $path', pos);
		}

		return {refs: refs, args: args, named: named};
	}

	/**
	 * Bakes what was wired into one generated class, which is both the keep-alive and the record the
	 * runtime half reads.
	 *
	 * @param bridges References to every generated bridge.
	 * @param forced The reference expressions and signature arguments from `reference`.
	 * @param globals Types scripts may name without importing.
	 * @param abstracts The abstracts that were given a runtime form, for the report.
	 * @param libraries The active libraries' titles, for the report.
	 */
	static function manifest(bridges:Array<Expr>,
			forced:{refs:Array<Expr>, args:Array<FunctionArg>, named:Array<String>}, globals:Array<String>,
			abstracts:Array<String>, libraries:Array<String>):Void {
		var pos:Position = Context.currentPos();
		var pack:Array<String> = PACK.split('.');

		Context.defineModule('$PACK.Manifest', [
			{
				pack: pack,
				name: 'Manifest',
				pos: pos,
				meta: [{name: ':keep', pos: pos}],
				kind: TDClass(null, [], false, false, false),
				fields: [
					{
						name: 'bridges',
						access: [APublic, AStatic],
						pos: pos,
						doc: 'Every generated bridge. Referenced so the classes survive dead-code elimination, and read by the setup report.',
						kind: FVar(macro :Array<Class<Dynamic>>, {
							expr: EArrayDecl(bridges),
							pos: pos
						})
					},
					{
						name: 'forced',
						access: [APublic, AStatic],
						pos: pos,
						doc: 'Modules pulled into the build by being referenced here, so scripts can name them.',
						kind: FVar(macro :Array<Class<Dynamic>>, {
							expr: EArrayDecl(forced.refs),
							pos: pos
						})
					},
					{
						name: 'signatures',
						access: [APublic, AStatic],
						pos: pos,
						doc: 'Never called. Its parameter types are the point: naming a type in a signature loads its module, including for abstracts, which cannot be values.',
						kind: FFun({
							args: forced.args,
							ret: macro :Void,
							expr: macro {}
						})
					},
					{
						name: 'globals',
						access: [APublic, AStatic],
						pos: pos,
						doc: 'Types scripts may name without importing them.',
						kind: FVar(macro :Array<String>, {
							expr: EArrayDecl([for (path in globals) macro $v{path}]),
							pos: pos
						})
					},
					{
						name: 'abstracts',
						access: [APublic, AStatic],
						pos: pos,
						doc: 'Abstracts given a runtime form, for the report.',
						kind: FVar(macro :Array<String>, {
							expr: EArrayDecl([for (path in abstracts) macro $v{path}]),
							pos: pos
						})
					},
					{
						name: 'libraries',
						access: [APublic, AStatic],
						pos: pos,
						doc: 'The libraries wired into this build, by title.',
						kind: FVar(macro :Array<String>, {
							expr: EArrayDecl([for (title in libraries) macro $v{title}]),
							pos: pos
						})
					}
				]
			}
		]);
	}

	/**
	 * A record built from the host's own classes, when `-D hxscript_host=<package>` names where to
	 * look.
	 *
	 * @return The record, or null when no host package was named or nothing in it was tagged.
	 */
	static function hostLibrary():Library {
		var packs:Array<String> = Presets.list('hxscript_host');
		if (packs.length == 0)
			return null;

		var bases:Array<String> = [];
		var named:Array<String> = [];

		for (pack in packs)
			for (dir in Context.getClassPath())
				scanHost(dir + pack.split('.').join('/'), pack, bases, named);

		if (named.length == 0)
			return null;

		return {
			define: 'hxscript_host',
			title: 'host (' + packs.join(', ') + ')',
			roots: [],
			ignore: [],
			types: named,
			bases: bases,
			abstractPackages: [],
			abstracts: [],
			abstractExclude: [],
			globals: []
		};
	}

	/**
	 * Collects tagged types from one directory of host source, recursing into sub-packages.
	 *
	 * @param dir The directory on disk.
	 * @param pack The package it holds.
	 * @param bases Collects `@:scriptable` paths.
	 * @param named Collects every tagged path, which is what has to be in the build.
	 */
	static function scanHost(dir:String, pack:String, bases:Array<String>, named:Array<String>):Void {
		if (!FileSystem.exists(dir) || !FileSystem.isDirectory(dir))
			return;

		for (entry in FileSystem.readDirectory(dir)) {
			var full:String = '$dir/$entry';

			if (FileSystem.isDirectory(full)) {
				scanHost(full, '$pack.$entry', bases, named);
				continue;
			}

			if (!StringTools.endsWith(entry, '.hx'))
				continue;

			var module:String = entry.substr(0, entry.length - 3);
			tagged(File.getContent(full), pack, module, bases, named);
		}
	}

	/**
	 * Reads one module's source for tagged type declarations.
	 *
	 * @param source The file's contents.
	 * @param pack The package it declares.
	 * @param module The module's name.
	 * @param bases Collects `@:scriptable` paths.
	 * @param named Collects every tagged path.
	 */
	static function tagged(source:String, pack:String, module:String, bases:Array<String>, named:Array<String>):Void {
		if (source.indexOf('@:scriptable') < 0 && source.indexOf('@:scriptAmbient') < 0)
			return;

		var declaration:EReg = ~/^\s*(?:final\s+|private\s+|extern\s+)*(class|interface|abstract|enum)\s+([A-Za-z_][A-Za-z0-9_]*)/;

		var scriptable:Bool = false;
		var ambient:Bool = false;

		for (line in source.split('\n')) {
			var trimmed:String = StringTools.trim(line);

			if (trimmed.length == 0
				|| StringTools.startsWith(trimmed, '//')
				|| StringTools.startsWith(trimmed, '*')
				|| StringTools.startsWith(trimmed, '/*'))
				continue;

			if (StringTools.startsWith(trimmed, '@:')) {
				if (trimmed.indexOf('@:scriptable') == 0)
					scriptable = true;
				if (trimmed.indexOf('@:scriptAmbient') == 0)
					ambient = true;

				continue;
			}

			if ((scriptable || ambient) && declaration.match(trimmed)) {
				var name:String = declaration.matched(2);
				var path:String = (name == module) ? '$pack.$module' : '$pack.$module.$name';

				if (named.indexOf(path) < 0)
					named.push(path);

				if (scriptable && bases.indexOf(path) < 0)
					bases.push(path);
			}

			scriptable = false;
			ambient = false;
		}
	}
}
#end
