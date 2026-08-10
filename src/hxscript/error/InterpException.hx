package hxscript.error;

import haxe.Exception;
import hxscript.runtime.ScriptStack;

/** A runtime error raised while interpreting, carrying the interpreter's own call stack. */
class InterpException extends Exception {
	/** The interpreter-level call stack captured when the error was raised. */
	public var customStack(default, null):ScriptStack;

	/**
	 * The error kind, when the failure came from the interpreter rather than from a script's own
	 * `throw`. Null for anything wrapped from outside.
	 */
	public var kind(default, null):Null<ErrorKind>;

	/** Whether to print the full native stack; on by default only in debug builds. */
	var fullStack:Bool = #if debug true #else false #end;

	/**
	 * Creates an interpreter exception.
	 *
	 * @param stack The interpreter call stack at the point of failure.
	 * @param message The error message.
	 * @param previous The underlying exception being wrapped, if any.
	 * @param kind The error kind, when there is one.
	 */
	public function new(stack:ScriptStack, message:String, ?previous:Exception, ?kind:ErrorKind) {
		super(message, previous);

		this.customStack = stack;
		this.kind = kind;
	}

	/**
	 * Renders the error where it happened, with the source line, the interpreter stack, and what usually
	 * causes it.
	 *
	 * @return The detailed error text.
	 */
	public override function details():String {
		var b:StringBuf = new StringBuf();
		b.add(Printer.render(toDiagnostic()));

		var stack:haxe.CallStack = stack?.copy();
		if (stack != null) {
			if (!fullStack && stack.length > 0) {
				while (true) {
					switch (stack[0]) {
						case FilePos(s, file, line, col):
							if (StringTools.startsWith(file, 'hxscript/')) {
								stack.asArray().shift();
							} else {
								break;
							}
						default:
							break;
					}
				}
			}
			b.add(Std.string(stack));
		}

		return b.toString();
	}

	/**
	 * The same error as a diagnostic, positioned at the innermost script frame.
	 *
	 * The interpreter's own stack is where the position comes from, not the native one: the native
	 * trace points inside the interpreter, which is true and useless, while the interpreter's
	 * innermost `SFilePos` is the line of script that failed.
	 *
	 * @return The diagnostic.
	 */
	public function toDiagnostic():Diagnostic {
		var origin:String = null;
		var line:Int = 0;
		var column:Int = 0;

		if (customStack != null) {
			for (frame in customStack.stack) {
				switch (frame.item) {
					case SFilePos(_, file, at, col) if (Sources.known(file)):
						origin = file;
						line = at;
						column = col == null ? 0 : col;
						break;

					case _:
				}
			}
		}

		return {
			phase: PRun,
			message: message,
			origin: origin,
			line: line,
			column: column,
			excerpt: origin != null && line > 0 ? Sources.line(origin, line) : null,
			hint: kind == null ? null : Hint.forKind(kind),
			stack: customStack == null ? null : Std.string(customStack)
		};
	}
}
