package hxscript.error;

/**
 * Where every diagnostic goes, whoever produced it.
 */
class Sink {
	/** Listeners, called in order for every diagnostic. */
	public static var onDiagnostic:Array<Diagnostic->Void> = [];

	/**
	 * Whether to print diagnostics nobody listened for.
	 */
	public static var printing:Bool = true;

	/**
	 * The last few diagnostics, newest last, for a host with no console to show them in.
	 *
	 * Capped by `historyLimit`, because a script erroring every frame would otherwise be a leak.
	 */
	public static var history(default, null):Array<Diagnostic> = [];

	/** How many diagnostics `history` keeps. Zero turns it off. */
	public static var historyLimit:Int = 64;

	/** Whether a listener has ever been added, which is what silences the default printer. */
	static var claimed:Bool = false;

	/**
	 * Takes over reporting. Equivalent to pushing onto `onDiagnostic`, but also stops the default
	 * printer, which is what a host adding a listener almost always means.
	 *
	 * @param listener Called for every diagnostic from now on.
	 */
	public static function listen(listener:Diagnostic->Void):Void {
		onDiagnostic.push(listener);

		if (!claimed) {
			claimed = true;
			printing = false;
		}
	}

	/**
	 * Reports one diagnostic.
	 *
	 * Never throws: a listener that fails must not turn an error being reported into a second error
	 * with the first one lost.
	 *
	 * @param d The diagnostic.
	 */
	public static function report(d:Diagnostic):Void {
		if (historyLimit > 0) {
			history.push(d);

			while (history.length > historyLimit)
				history.shift();
		}

		for (listener in onDiagnostic) {
			try {
				listener(d);
			} catch (e:haxe.Exception) {}
		}

		if (printing)
			print(d.toString());
	}

	/**
	 * Reports a message with no source position, which is what the setup and compile phases have.
	 *
	 * @param phase Which part of the pipeline.
	 * @param message What happened.
	 * @param hint What usually causes it.
	 * @param fatal Whether it stopped something.
	 */
	public static function note(phase:Phase, message:String, ?hint:String, fatal:Bool = true):Void {
		report({phase: phase, message: message, hint: hint, fatal: fatal});
	}

	/**
	 * Turns whatever was thrown into a diagnostic.
	 *
	 * @param e What was caught.
	 * @param phase Which part of the pipeline caught it.
	 * @param context What was being done, prefixed to the message when given.
	 * @return The diagnostic.
	 */
	public static function fromException(e:haxe.Exception, phase:Phase, ?context:String):Diagnostic {
		var d:Diagnostic = if (Std.isOfType(e, ParserException)) {
			(cast e : ParserException).toDiagnostic();
		} else if (Std.isOfType(e, InterpException)) {
			(cast e : InterpException).toDiagnostic();
		} else {
			{phase: phase, message: e.message, stack: e.details()};
		}

		d.phase = phase;

		if (context != null)
			d.message = context + ': ' + d.message;

		return d;
	}

	/**
	 * Reports whatever was thrown.
	 *
	 * @param e What was caught.
	 * @param phase Which part of the pipeline caught it.
	 * @param context What was being done.
	 */
	public static function caught(e:haxe.Exception, phase:Phase, ?context:String):Void {
		report(fromException(e, phase, context));
	}

	/** Empties the history. */
	public static function clear():Void {
		history = [];
	}

	/**
	 * The default printer.
	 *
	 * stderr rather than `trace`, so a diagnostic looks like a compiler's output rather than like a
	 * debug print, and so it can be redirected separately from whatever the program itself says.
	 *
	 * @param text The rendered diagnostic.
	 */
	static function print(text:String):Void {
		#if sys
		try {
			Sys.stderr().writeString(text + '\n');
			return;
		} catch (e:haxe.Exception) {}
		#end

		haxe.Log.trace(text, null);
	}
}
