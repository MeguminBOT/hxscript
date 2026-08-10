package hxscript.error;

import hxscript.syntax.Expr;

/** Every parse/interpret error kind, rendered to text by `Printer.errorToString`. */
enum ErrorKind {
	/** A non-import statement appeared in an `import.hx` prelude. */
	EImportHx;

	/** `super` was used where the current class has no super-class. */
	EHasNoSuper;

	/** A switch pattern the interpreter can't match. */
	EUnrecognizedPattern(e:Expr);

	/** Field `f` does not exist on object `o`. */
	EUnknownField(o:Dynamic, f:String);

	/** Type `t` could not be resolved. */
	EUnknownType(t:String);

	/** An invalid character in the source. */
	EInvalidChar(c:Int);

	/** An unexpected token. */
	EUnexpected(s:String);

	/** A string literal was not closed. */
	EUnterminatedString;

	/** A block comment was not closed. */
	EUnterminatedComment;

	/** A regex literal was not closed. */
	EUnterminatedRegex;

	/** A malformed `#if`/`#elseif` conditional. */
	EInvalidPreprocessor(msg:String);

	/** Identifier `v` is not defined. */
	EUnknownVariable(v:String);

	/** Value `v` cannot be iterated. */
	EInvalidIterator(v:String);

	/** Operator `op` is not valid here. */
	EInvalidOp(op:String);

	/** Field `f` cannot be accessed (e.g. a `private` violation). */
	EInvalidAccess(f:String);

	/** An arbitrary message. */
	ECustom(msg:String);
}
