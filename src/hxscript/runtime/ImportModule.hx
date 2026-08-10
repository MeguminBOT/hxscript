package hxscript.runtime;

import hxscript.Module;

/**
 * A shared "prelude" module whose declarations are folded into any module that imports it. Unlike a
 * normal `Module`, it runs its program at most once (the first `start`) and reuses the result for
 * every importer, so a common set of imports/usings is defined a single time.
 */
class ImportModule extends Module {
	/** Whether `start` has already run once; further calls are no-ops. */
	var attempted:Bool = false;

	/**
	 * Creates an import module in the root package under the reserved name `import`.
	 *
	 * @param string The prelude source to parse.
	 * @param origin Source origin used for error positions.
	 */
	public function new(string:String, origin:String = 'hscript'):Void {
		super(string, 'import', [], origin);
	}

	/**
	 * Parses the prelude, allowing it to declare imports/usings only.
	 *
	 * @param string The prelude source to parse.
	 * @return The parsed declarations.
	 */
	public override function parse(string:String) {
		attempted = false;
		decls.resize(0);

		try {
			decls = parser.parseModule(string, origin, true);
		} catch (e:haxe.Exception) {
			onParsingError(e);
		}

		return decls;
	}

	/**
	 * Runs the prelude program once and remembers that it ran, so importing it from many modules
	 * doesn't re-execute it.
	 *
	 * @param environment The world the prelude runs against.
	 */
	public override function start(?environment) {
		if (attempted)
			return;
		attempted = true;

		try {
			if (decls.length == 0)
				throw 'Module is uninitialized';

			starting = true;

			interp.environment = environment;
			interp.setDefaults();
			interp.executeModule(decls, path);

			starting = false;
			started = true;
		} catch (e:haxe.Exception) {
			onProgramError(e);
		}
	}
}
