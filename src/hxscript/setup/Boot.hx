package hxscript.setup;

import hxscript.Config;
import hxscript.syntax.Expr.ImportMode;
import hxscript.types.TypeCollection;

/**
 * The runtime half of embedding, and the half a host used to have to write.
 */
class Boot {
	/** Whether `ensure` has run. Process-wide, because `Config` is. */
	public static var done(default, null):Bool = false;

	/** The libraries wired into this build, by title. Empty when the build did no autowiring. */
	public static var libraries(default, null):Array<String> = [];

	/**
	 * Types a `Library` record OFFERS as bare names, which nothing has imported.
	 *
	 * Empty in any build using only the shipped presets, because none of them offer a name. A preset
	 * says what a script *can* import; what is already imported into every script is the host's call
	 * and nobody else's. Adding a record to `Presets.custom` with its own `globals` is how a host
	 * fills this, and `importGlobals(['flixel.FlxG'])` skips the record and takes paths directly.
	 *
	 * This is a menu rather than a state either way: `importGlobals()` takes all of it,
	 * `-D hxscript_globals` takes all of it at startup, and until one of those runs a script writes
	 * its own `import` for anything in the build, as in Haxe.
	 */
	public static var globals(default, null):Array<String> = [];

	/**
	 * Types the host marked `@:scriptAmbient`, which ARE registered.
	 *
	 * Kept apart from `globals` because the two are different requests. A `globals` entry is an offer
	 * waiting on an answer; a mark on your own class is the answer already given, and there would be
	 * no point reading the mark and then asking again.
	 */
	public static var ambient(default, null):Array<String> = [];

	/**
	 * Puts the runtime half of the setup in place, once.
	 *
	 * Cheap enough to call from anywhere and harmless to call again: the second call returns on the
	 * first line.
	 */
	public static function ensure():Void {
		if (done)
			return;

		done = true;

		read();
		blacklist();

		hxscript.macro.Expose.apply();

		ambient = hxscript.macro.Expose.ambient();
		register(ambient);

		#if hxscript_globals
		importGlobals();
		#end

		#if hxscript_no_shims
		#else
		Shims.register();
		#end
	}

	/**
	 * Makes types nameable without an import, which nothing does on its own.
	 *
	 * Naming the paths is the usual call, because no shipped preset offers any and passing nothing
	 * then takes nothing:
	 *
	 * ```haxe
	 * Boot.importGlobals(['flixel.FlxG', 'flixel.FlxSprite']);
	 * ```
	 *
	 * @param only The paths to take, or null for every one a `Library` record offers.
	 * @return The paths actually registered, which is not the same list when the build lacks one.
	 */
	public static function importGlobals(?only:Array<String>):Array<String> {
		ensure();
		return register(only == null ? globals : only);
	}

	/**
	 * Reads what the build wired, from the class `Autowire` generated.
	 */
	static function read():Void {
		var manifest:Class<Dynamic> = Type.resolveClass('hxscript.wired.Manifest');
		if (manifest == null)
			return;

		var names:Array<String> = Reflect.field(manifest, 'libraries');
		if (names != null)
			libraries = names;

		var paths:Array<String> = Reflect.field(manifest, 'globals');
		if (paths != null)
			globals = paths;
	}

	/**
	 * Registers a list of paths as importable without an import, and says what it could not.
	 *
	 * A path this build does not carry used to be skipped in silence, which is how `openfl.Lib` sat in
	 * the openfl preset's globals for as long as it did: the record named it, no included root covered
	 * the `openfl` package root, and a script writing `Lib` got `Unknown identifier` with nothing
	 * anywhere saying the name had been dropped. Reported now, once, naming every one, and not fatal:
	 * the rest of the list is still worth having.
	 *
	 * @param paths The paths to register.
	 * @return Those that resolved, so a caller can diff it against what it asked for.
	 */
	static function register(paths:Array<String>):Array<String> {
		var taken:Array<String> = [];
		var missing:Array<String> = [];

		for (path in paths) {
			if (TypeCollection.main.fromPath(path) == null) {
				missing.push(path);
				continue;
			}

			Config.globalImports.set(path, INormal);
			taken.push(path);
		}

		if (missing.length > 0) {
			hxscript.error.Sink.report({
				phase: PSetup,
				fatal: false,
				message: missing.length + ' name(s) offered without an import are not in this build: ' +
				missing.join(', '),
				hint: 'Each is named by a preset or a @:scriptAmbient mark, and nothing compiled references it, so' +
				' dead code elimination kept nothing. Force the package in, or stop offering the name.'
			});
		}

		/**
		 * cppia only, and deliberately. A HashLink module resolves a type-shaped name against the
		 * world as it loads, so `hl.Backend.ambient` is declared for the shared configuration surface
		 * and reads nothing; telling it would change no answer.
		 */
		#if hxscript_cppia
		var known:Array<String> = hxscript.compile.Compiler.ambient.copy();

		for (path in taken)
			if (known.indexOf(path) < 0)
				known.push(path);

		hxscript.compile.Compiler.ambient = known;
		#end

		return taken;
	}

	/**
	 * Blocks what a script has no business reaching.
	 */
	static function blacklist():Void {
		var blocked:Array<String> = Config.blacklist.get(ByType);

		block(blocked, 'hxscript.Config');

		#if hxscript_sandbox
		for (name in ['Sys', 'sys.io.File', 'sys.io.Process', 'sys.FileSystem', 'sys.net.Socket'])
			block(blocked, name);
		#end
	}

	/**
	 * Adds one entry to the blacklist if it is not already there.
	 *
	 * @param blocked The list to add to.
	 * @param name The type path to block.
	 */
	static inline function block(blocked:Array<String>, name:String):Void {
		if (blocked.indexOf(name) < 0)
			blocked.push(name);
	}

	/**
	 * A human-readable account of what the setup did, for a host that wants to print one.
	 *
	 * Worth showing at least once in any project that embeds this. All four setup steps fail silently
	 * in the sense that matters, because the build succeeds and a script finds a null field months
	 * later. The cheapest guard against that is a line at startup saying what was wired.
	 *
	 * @return One line per fact, newline-separated.
	 */
	public static function report():String {
		ensure();

		var lines:Array<String> = [];

		lines.push(libraries.length == 0 ? 'hxscript: nothing autowired' : 'hxscript: wired ' + libraries.join(', '));

		if (globals.length == 0) {
			lines.push('  no type is offered without an import');
		} else {
			var taken:Int = 0;
			for (path in globals)
				if (Config.globalImports.exists(path))
					taken++;

			var offer:String = '  ${globals.length} type(s) offered without an import, $taken taken';
			if (taken == 0)
				offer += ' (Boot.importGlobals() takes them)';

			lines.push(offer);
		}
		lines.push('  ${ambient.length} type(s) marked @:scriptAmbient, always taken');
		lines.push('  ${Shims.registered.length} shim(s) registered');

		var manifest:Class<Dynamic> = Type.resolveClass('hxscript.wired.Manifest');
		if (manifest != null) {
			var bridges:Array<Dynamic> = Reflect.field(manifest, 'bridges');
			var abstracts:Array<String> = Reflect.field(manifest, 'abstracts');

			lines.push('  ' + (bridges == null ? 0 : bridges.length) + ' bridged base(s)');
			lines.push('  ' + (abstracts == null ? 0 : abstracts.length) + ' abstract(s) with a runtime form');
		}

		lines.push('  '
			+
			(hxscript.compile.Compiler.available ? 'runtime compiler available' : 'interpreted only (built without -D hxscript_cppia)'));

		return lines.join('\n');
	}
}
