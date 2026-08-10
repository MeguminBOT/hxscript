package hxscript.syntax;

import hxscript.syntax.Expr;

/**
 * One pushed-back token and the span it came from.
 */
@:structInit
class TokenEntry {
	/** The token itself. */
	public var t:Token;

	/** Start offset of its span. */
	public var min:Int;

	/** End offset of its span. */
	public var max:Int;
}

/** The lexer's token kinds. */
enum Token {
	/** End of input. */
	TEof;

	/** A literal constant. */
	TConst(c:Const);

	/** An identifier or keyword. */
	TId(s:String);

	/** An operator. */
	TOp(s:String);

	/** `(`. */
	TPOpen;

	/** `)`. */
	TPClose;

	/** `{`. */
	TBrOpen;

	/** `}`. */
	TBrClose;

	/** `.`. */
	TDot;

	/** `?.`. */
	TQuestionDot;

	/** `,`. */
	TComma;

	/** `;`. */
	TSemicolon;

	/** `[`. */
	TBkOpen;

	/** `]`. */
	TBkClose;

	/** `?`. */
	TQuestion;

	/** `:`. */
	TDoubleDot;

	/** A metadata token `@name`. */
	TMeta(s:String);

	/** A preprocessor token `#name`. */
	TPrepro(s:String);
}
