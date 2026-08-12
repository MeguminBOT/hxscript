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

	/** Types scripts may name without importing, as wired. */
	public static var globals(default, null):Array<String> = [];

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

		var exposed:Array<String> = hxscript.macro.Expose.ambient();
		for (path in exposed)
			if (globals.indexOf(path) < 0)
				globals.push(path);

		imports();

		#if hxscript_no_shims
		#else
		Shims.register();
		#end
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
	 * Makes the wired types nameable without an import.
	 */
	static function imports():Void {
		var ambient:Array<String> = [];

		for (path in globals) {
			if (TypeCollection.main.fromPath(path) == null)
				continue;

			Config.globalImports.set(path, INormal);
			ambient.push(path);
		}

		#if (hxscript_cppia || hxscript_hl)
		var known:Array<String> = hxscript.compile.Compiler.ambient.copy();

		for (path in ambient)
			if (known.indexOf(path) < 0)
				known.push(path);

		hxscript.compile.Compiler.ambient = known;
		#end
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
		lines.push('  ${globals.length} type(s) nameable without an import');
		lines.push('  ${Shims.registered.length} shim(s) registered');

		var manifest:Class<Dynamic> = Type.resolveClass('hxscript.wired.Manifest');
		if (manifest != null) {
			var bridges:Array<Dynamic> = Reflect.field(manifest, 'bridges');
			var abstracts:Array<String> = Reflect.field(manifest, 'abstracts');

			lines.push('  ' + (bridges == null ? 0 : bridges.length) + ' bridged base(s)');
			lines.push('  ' + (abstracts == null ? 0 : abstracts.length) + ' abstract(s) with a runtime form');
		}

		lines.push('  ' + (hxscript.compile.Compiler.available ? 'runtime compiler available' : 'interpreted only (built without -D hxscript_cppia)'));

		return lines.join('\n');
	}
}
