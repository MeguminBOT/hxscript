package hxscript.setup;

#if macro
import haxe.macro.Compiler;
import haxe.macro.Context;
import haxe.macro.Expr;
import hxscript.setup.Extension.Outcome;
import hxscript.setup.Native.Advice;
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
		if (Context.defined('hxscript_no_autowire'))
			return;

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

		Context.onAfterInitMacros(function():Void {
			var forced:{refs:Array<Expr>, args:Array<FunctionArg>, named:Array<String>} = reference(libs);
			var bridges:Array<Expr> = Bridges.generate(libs);

			manifest(bridges, forced, globals, abstracts, [for (lib in libs) lib.title]);
			extension();
		});
	}

	/**
	 * Builds the HashLink extension into the output directory, when this build wants one.
	 *
	 * A compiled script on HashLink needs `hxscript.hdll` beside what runs, and producing it is a C
	 * compile against a matching hashlink source tree, which is not something a host should have to
	 * know. Asking for `-D hxscript_hl` is taken as asking for the extension too.
	 *
	 * Never fails the build. Without the extension every script is interpreted, which is correct and
	 * slower rather than broken, so what cannot be done here is reported as one sentence naming the
	 * thing to install.
	 */
	static function extension():Void {
		if (!Context.defined('hl') || !Context.defined('hxscript_hl') || Context.defined('hxscript_no_hdll'))
			return;

		var carried:String = null;
		try {
			carried = haxe.io.Path.directory(Context.resolvePath('hxscript/hl/hxscript.c'));
		} catch (e:Dynamic) {
			Context.warning('hxscript: could not find hxscript.c in the class path; the HashLink extension was not built', Context.currentPos());
			return;
		}

		var into:String = haxe.io.Path.directory(Compiler.getOutput());
		if (into == null || into.length == 0)
			into = '.';

		if (Context.defined('hlc')) {
			native(into, carried);
			return;
		}

		switch (Extension.ensure(into, carried)) {
			case Ready(_):
				if (Context.defined('hxscript_verbose'))
					Context.info('hxscript: the HashLink extension is current', Context.currentPos());

			case Built(path):
				Context.info('hxscript: built ' + path, Context.currentPos());

			case Missing(reason, remedy):
				Context.warning('hxscript: ' + reason + ', so scripts will be interpreted. To compile them, ' + remedy, Context.currentPos());
		}
	}

	/**
	 * Leaves an HL/C build what it needs to link the extension in.
	 *
	 * There is no `.hdll` on this target and nothing to build here: the C is compiled into the
	 * program and resolved by the linker, and Haxe hands the native build off to whatever is driving
	 * it. So the useful thing to do is not to compile but to answer, in a form that can be read
	 * without anyone being at a terminal.
	 *
	 * Written beside the generated C as `hxscript.flags`, one argument per line, so a Makefile,
	 * CMake list or shell script can take it whole. The one line printed is what a first build needs
	 * to see, because the alternative to being told is a link that fails on `hxscript_load` with
	 * nothing saying why.
	 *
	 * @param into The directory Haxe generated the C into.
	 * @param carried The directory holding `hxscript.c`.
	 */
	static function native(into:String, carried:String):Void {
		switch (Native.recipe(carried)) {
			case Ready(recipe):
				var args:Array<String> = Native.flags(recipe);
				var listed:String = haxe.io.Path.join([into, 'hxscript.flags']);

				try {
					if (!FileSystem.exists(into))
						FileSystem.createDirectory(into);
					File.saveContent(listed, args.join('\n') + '\n');
				} catch (e:Dynamic) {
					Context.warning('hxscript: could not write ' + listed, Context.currentPos());
				}

				if (Context.defined('hxscript_verbose'))
					Context.info('hxscript: add to the native build: ' + args.join(' '), Context.currentPos());
				else
					Context.info('hxscript: HL/C links the extension rather than loading it; what to add is in ' + listed, Context.currentPos());

			case Missing(reason, remedy):
				Context.warning('hxscript: ' + reason + ', so this HL/C build cannot compile scripts. To fix it, ' + remedy, Context.currentPos());
		}
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
	 * @param libs The active libraries.
	 */
	static function include(libs:Array<Library>):Void {
		var ignore:Array<String> = [];
		for (lib in libs)
			for (name in lib.ignore)
				if (ignore.indexOf(name) < 0)
					ignore.push(name);

		for (lib in libs) {
			for (root in lib.roots) {
				Compiler.include(root, true, ignore);

				if (Context.defined('hxscript_verbose'))
					Context.info('  include $root (recursive)', Context.currentPos());
			}
		}

		if (Context.defined('hxscript_verbose') && ignore.length > 0)
			Context.info('  skipping ' + ignore.join(', '), Context.currentPos());
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
					/**
					 * An abstract and an enum are named in the signature and nowhere else. Writing the
					 * path as an expression gives the enum itself, which is an `Enum<T>` rather than
					 * the `Class<Dynamic>` the manifest holds, and the build stops on the mismatch.
					 * The typed argument is what forces the module in, so nothing is lost by leaving
					 * these out of the references.
					 */
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
	static function manifest(bridges:Array<Expr>, forced:{refs:Array<Expr>, args:Array<FunctionArg>, named:Array<String>}, globals:Array<String>,
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
						kind: FVar(macro :Array<Class<Dynamic>>, {expr: EArrayDecl(bridges), pos: pos})
					},
					{
						name: 'forced',
						access: [APublic, AStatic],
						pos: pos,
						doc: 'Modules pulled into the build by being referenced here, so scripts can name them.',
						kind: FVar(macro :Array<Class<Dynamic>>, {expr: EArrayDecl(forced.refs), pos: pos})
					},
					{
						name: 'signatures',
						access: [APublic, AStatic],
						pos: pos,
						doc: 'Never called. Its parameter types are the point: naming a type in a signature loads its module, including for abstracts, which cannot be values.',
						kind: FFun({args: forced.args, ret: macro :Void, expr: macro {}})
					},
					{
						name: 'globals',
						access: [APublic, AStatic],
						pos: pos,
						doc: 'Types scripts may name without importing them.',
						kind: FVar(macro :Array<String>, {expr: EArrayDecl([for (path in globals) macro $v{path}]), pos: pos})
					},
					{
						name: 'abstracts',
						access: [APublic, AStatic],
						pos: pos,
						doc: 'Abstracts given a runtime form, for the report.',
						kind: FVar(macro :Array<String>, {expr: EArrayDecl([for (path in abstracts) macro $v{path}]), pos: pos})
					},
					{
						name: 'libraries',
						access: [APublic, AStatic],
						pos: pos,
						doc: 'The libraries wired into this build, by title.',
						kind: FVar(macro :Array<String>, {expr: EArrayDecl([for (title in libraries) macro $v{title}]), pos: pos})
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
