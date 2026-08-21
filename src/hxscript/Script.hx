package hxscript;

import hxscript.syntax.Parser;
import hxscript.runtime.Interp;
import hxscript.syntax.Expr;

/**
 * A single free-standing script: one expression program with its own parser and interpreter, run
 * top-to-bottom rather than compiled into named types. This is the plain-script counterpart to
 * `Module` (which produces scripted classes/enums); use it to evaluate a body and then `call`
 * functions it declared.
 */
@:access(hxscript.runtime.Interp)
class Script {
	/** The script's name, used for error positions. */
	public var name:String;

	/** The parser that produced this script's program. */
	public var parser:Parser = new Parser();

	/** The interpreter that runs the program and hosts its variables. */
	public var interp:Interp = null;

	/** The parsed expression program, or null if parsing failed. */
	public var program:Expr = null;

	/** True if the last `start` threw. */
	public var failed:Bool = false;

	/** The interpreter's variable table. */
	public var variables(get, never):hxscript.runtime.Bindings;

	/** @return The interpreter's variable table. */
	inline function get_variables():hxscript.runtime.Bindings {
		return interp.variables;
	}

	/**
	 * Creates a script and immediately parses its source.
	 *
	 * @param string The script source to parse.
	 * @param name The script's name, used for error positions.
	 * @param environment An optional world whose variables are shared in at `start`.
	 */
	public function new(string:String, name:String = 'hscript', ?environment:Environment):Void {
		hxscript.setup.Boot.ensure();

		parser.allowTypes = parser.allowJSON = parser.allowMetadata = true;
		interp = Type.createInstance(Config.interpClass, [environment, this]);
		interp.defineGlobals = true;

		this.name = name;

		parse(string);
	}

	/**
	 * Parses `string` into `program`, replacing any previous parse. Parse errors are routed to
	 * `onParsingError` and leave `program` null.
	 *
	 * @param string The script source to parse.
	 * @return The parsed program, or null on failure.
	 */
	public function parse(string:String):Expr {
		hxscript.error.Sources.remember(name, string);

		try {
			program = parser.parseScript(string, name);
		} catch (e:haxe.Exception) {
			hxscript.error.Sink.caught(e, PParse);
			onParsingError(e);
			program = null;
		}

		return program;
	}

	/**
	 * Runs the parsed program top-to-bottom, sharing in the environment's variables first. Runtime
	 * errors are routed to `onProgramError` and set `failed`.
	 *
	 * @param expr Unused; retained for signature compatibility.
	 * @return The program's result value, or null if it was uninitialized or threw.
	 */
	public function start(?expr:Expr):Any {
		try {
			if (program == null)
				throw 'Program is uninitialized';

			failed = false;
			setDefaults();

			if (interp.environment != null) {
				for (k => v in interp.environment.variables)
					if (!variables.exists(k))
						variables.set(k, v);
			}

			return interp.execute(program);
		} catch (e:haxe.Exception) {
			hxscript.error.Sink.caught(e, PRun, 'script $name');
			onProgramError(e);
			failed = true;
		}

		return null;
	}

	/**
	 * Calls a function the script declared (a script variable or a top-level local) by name.
	 *
	 * @param variable The name of the function to call.
	 * @param args The arguments to pass; defaults to none.
	 * @return The function's result, or null if the name isn't a function.
	 */
	public function call(variable:String, ?args:Array<Dynamic>):Any {
		if (interp == null)
			throw 'Interpreter is uninitialized';

		var fun = (variables.get(variable) ?? interp.getLocal(variable));

		if (!Reflect.isFunction(fun)) {
			trace('$variable isn\'t a function');
			return null;
		}

		return Reflect.callMethod(interp, fun, args ?? []);
	}

	/** Resets the interpreter to its defaults and re-binds `this`, `script`, and `interp`. */
	public function setDefaults():Void {
		interp.setDefaults();

		variables.set('this', this);
		variables.set('script', this);
		variables.set('interp', interp);
	}

	/**
	 * Overridable hook invoked when parsing fails.
	 *
	 * Empty by default, and that is not the same as errors being swallowed: everything reaching here
	 * has already gone to [`hxscript.error.Sink`](error/Sink.hx), which prints it until a host takes
	 * over. Overriding this is purely additive.
	 *
	 * @param e The parse exception.
	 */
	public dynamic function onParsingError(e:haxe.Exception):Void {}

	/**
	 * Overridable hook invoked when the program throws. See `onParsingError` for why it is empty.
	 *
	 * @param e The runtime exception.
	 */
	public dynamic function onProgramError(e:haxe.Exception):Void {}
}
