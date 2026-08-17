/*
 * Copyright (C)2008-2017 Haxe Foundation
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 * DEALINGS IN THE SOFTWARE.
 */

package hxscript.syntax;

import hxscript.syntax.Expr;
import hxscript.syntax.Token;
import hxscript.error.ErrorKind;
import hxscript.error.ParserException;

using hxscript.syntax.ExprTools;
using hxscript.types.TypeTools;

/** A recursive-descent parser/lexer that turns script source into `Expr`/`ModuleDecl` trees. */
class Lexer {
	/** Operator precedence, keyed by operator (lower binds looser). */
	public var opPriority:Map<String, Int>;

	/** Which operators are right-associative. */
	public var opRightAssoc:Map<String, Bool>;

	/** Whether to accept JSON-style syntax. */
	public var allowJSON:Bool;

	/** Whether to accept type declarations. */
	public var allowTypes:Bool;

	/** Whether to accept Haxe metadata. */
	public var allowMetadata:Bool;

	/** The current 1-based line number. */
	public var line:Int;

	/** Characters that may appear in operators. */
	public var opChars:String;

	/** Characters that may appear in identifiers. */
	public var identChars:String;

	/** Column offset applied to positions (for embedded sources). */
	public var columnOffset:Int;

	/** Preprocessor values used to evaluate `#if`/`#else`. */
	public var preprocessorValues:Map<String, Dynamic> = new Map();

	/** Whether to recover from parse errors (e.g. for completion over incomplete code) rather than throw. */
	public var resumeErrors:Bool;

	/** The source origin (for error positions). */
	var origin:String;

	/** The source text. */
	var input:String;

	/** The current read offset into `input`. */
	var readPos:Int;

	/** Base offset added to positions. */
	var offset:Int;

	/** The absolute current position (`readPos + offset`). */
	var currentPos(get, never):Int;

	/** The most recently read character code. */
	var char:Int;

	/** Lookup of which character codes are operator characters. */
	var ops:Array<Bool>;

	/** Lookup of which character codes are identifier characters. */
	var idents:Array<Bool>;

	/** Start offset of the current token. */
	var tokenMin:Int;

	/** End offset of the current token. */
	var tokenMax:Int;

	/** Start offset of the previous token. */
	var oldTokenMin:Int;

	/** End offset of the previous token. */
	var oldTokenMax:Int;

	/**
	 * Pushed-back tokens, innermost LAST.
	 */
	var tokens:Array<TokenEntry>;

	/** @return The absolute current read position. */
	inline function get_currentPos()
		return readPos + offset;

	/**
	 * Raises a parse error (unless in resume-errors mode).
	 *
	 * @param err The error kind.
	 * @param pmin Start offset of the offending span.
	 * @param pmax End offset of the offending span.
	 */
	public inline function error(err, pmin, pmax) {
		if (!resumeErrors)
			throw new ParserException(err, pmin, pmax, origin, line);
	}

	/**
	 * Raises an invalid-character error at the current position.
	 *
	 * @param c The offending character code.
	 */
	public function invalidChar(c) {
		error(EInvalidChar(c), readPos - 1, readPos - 1);
	}

	/**
	 * Raises an "unexpected token" error.
	 *
	 * @param tk The unexpected token.
	 * @return Never returns; typed `Dynamic` to stand in an expression.
	 */
	function unexpected(tk):Dynamic {
		error(EUnexpected(tokenString(tk)), tokenMin, tokenMax);
		return null;
	}

	/**
	 * Pushes a token back for re-reading (one-token lookahead).
	 *
	 * @param tk The token to push back.
	 */
	inline function push(tk) {
		tokens.push({t: tk, min: tokenMin, max: tokenMax});
		tokenMin = oldTokenMin;
		tokenMax = oldTokenMax;
	}

	/**
	 * Consumes the next token, erroring unless it equals `tk`.
	 *
	 * @param tk The expected token.
	 */
	inline function ensure(tk) {
		var t = token();
		if (t != tk)
			unexpected(t);
	}

	/**
	 * Consumes the next token, erroring unless it structurally equals `tk`.
	 *
	 * @param tk The expected token.
	 */
	inline function ensureToken(tk) {
		var t = token();
		if (!Type.enumEq(t, tk))
			unexpected(t);
	}

	/**
	 * Consumes the next token only if it matches `tk`.
	 *
	 * @param tk The token to look for.
	 * @return True if it was consumed, false (and pushed back) otherwise.
	 */
	function maybe(tk) {
		var t = token();
		if (t == tk || Type.enumEq(t, tk))
			return true;
		push(t);
		return false;
	}

	/**
	 * Consumes and returns an identifier, erroring on anything else.
	 *
	 * @return The identifier text.
	 */
	function getIdent() {
		var tk = token();
		switch (tk) {
			case TId(id):
				return id;
			default:
				unexpected(tk);
				return null;
		}
	}

	/**
	 * @param e An expression.
	 * @return Its definition.
	 */
	inline function expr(e:Expr) {
		return e.e;
	}

	/**
	 * @param e An expression.
	 * @return Its start offset.
	 */
	inline function pmin(e:Expr) {
		return e.pos.pmin;
	}

	/**
	 * @param e An expression.
	 * @return Its end offset.
	 */
	inline function pmax(e:Expr) {
		return e.pos.pmax;
	}

	/**
	 * Wraps an expression definition with a position.
	 *
	 * @param e The expression definition.
	 * @param pmin Optional start offset (defaults to the current token's).
	 * @param pmax Optional end offset (defaults to the current token's).
	 * @return The positioned expression.
	 */
	inline function mk(e, ?pmin:Int, ?pmax:Int):Expr {
		return {e: e, pos: getPos(pmin, pmax)};
	}

	/**
	 * Wraps a declaration definition with a position.
	 *
	 * @param d The declaration definition.
	 * @param pmin Optional start offset.
	 * @param pmax Optional end offset.
	 * @return The positioned declaration.
	 */
	inline function mkd(d, ?pmin:Int, ?pmax:Int):ModuleDecl {
		return {d: d, pos: getPos(pmin, pmax)};
	}

	/**
	 * Builds a position from offsets, computing the column.
	 *
	 * @param pmin Start offset, or -1 for the current token's.
	 * @param pmax End offset, or -1 for the current token's.
	 * @return The position.
	 */
	inline function getPos(pmin:Int = -1, pmax:Int = -1):Position {
		if (pmin < 0)
			pmin = tokenMin;
		if (pmax < 0)
			pmax = tokenMax;

		var column:Int = ((pmin < columnOffset ? pmax : pmin) - columnOffset + 1);

		return {
			pmin: pmin,
			pmax: pmax,
			origin: origin,
			line: line,
			column: column
		};
	}

	/** @return The next character code from the input, advancing the read position. */
	inline function readChar() {
		return StringTools.fastCodeAt(input, readPos++);
	}

	/**
	 * Decodes a string escape sequence (`\n`, `\t`, `\uXXXX`, `\xXX`, etc.) into the output buffer.
	 *
	 * @param c The character following the backslash.
	 * @param b The buffer to append the decoded character to.
	 * @param old The start offset of the string, for error reporting.
	 */
	inline function parseEscape(c:Int, b:StringBuf, old:Int) {
		var p1 = (currentPos - 1);
		switch (c) {
			case 'n'.code:
				b.addChar('\n'.code);
			case 'r'.code:
				b.addChar('\r'.code);
			case 't'.code:
				b.addChar('\t'.code);
			case "'".code, '"'.code, '\\'.code:
				b.addChar(c);
			case '/'.code:
				if (allowJSON)
					b.addChar(c)
				else
					invalidChar(c);
			case "u".code:
				if (!allowJSON)
					invalidChar(c);
				var k = 0;
				for (i in 0...4) {
					k <<= 4;
					var char = readChar();
					switch (char) {
						case 48, 49, 50, 51, 52, 53, 54, 55, 56, 57:
							k += char - 48;
						case 65, 66, 67, 68, 69, 70:
							k += char - 55;
						case 97, 98, 99, 100, 101, 102:
							k += char - 87;
						default:
							if (StringTools.isEof(char)) {
								line = old;
								error(EUnterminatedString, p1, p1);
							}
							invalidChar(char);
					}
				}
				b.addChar(k);
			default:
				invalidChar(c);
		}
	}

	/**
	 * Reads a string literal up to its closing quote, decoding escapes.
	 *
	 * @param until The closing quote character code.
	 * @param interpolate Whether this is a single-quoted, interpolatable string.
	 * @return The literal's contents.
	 */
	function parseString(until:Int, interpolate:Bool = false) {
		var c = 0;
		var b = new StringBuf();
		var esc = false;
		var old = line;
		var s = input;
		var p1 = currentPos - 1;

		while (true) {
			var c = readChar();
			if (StringTools.isEof(c)) {
				line = old;
				error(EUnterminatedString, p1, p1);
				break;
			}
			if (esc) {
				esc = false;
				parseEscape(c, b, old);
			} else if (c == 92) {
				esc = true;
			} else if (c == until) {
				break;
			} else if (interpolate && c == '$'.code) {
				var next = readChar();
				var startsIdent:Bool = (idents[next] == true && !(next >= '0'.code && next <= '9'.code));
				if (startsIdent || next == '{'.code) {
					readPos--;
					return TConst(CString(b.toString(), true));
				} else if (next == '$'.code) {
					b.addChar(c);
				} else {
					b.addChar(c);
					readPos--;
				}
			} else {
				if (c == 10) {
					columnOffset = p1;
					line++;
				}
				b.addChar(c);
			}
		}
		return TConst(CString(b.toString()));
	}

	/**
	 * Reads a `~/.../flags` regular-expression literal.
	 *
	 * @return The regex token.
	 */
	function parseRegex() {
		var c = 0;
		var old = line;
		var p1 = currentPos - 1;
		var esc = false;

		var p = new StringBuf();
		var m = new StringBuf();

		while (true) {
			var c = readChar();

			if (StringTools.isEof(c) || c == 10) {
				line = old;
				error(EUnterminatedRegex, p1, p1);
				break;
			}

			if (esc) {
				esc = false;
				parseEscape(c, p, old);
			} else if (c == '\\'.code) {
				esc = true;
			} else if (c == '/'.code) {
				while (true) {
					var c = readChar();
					if (c < 97 || c > 122)
						break;

					switch (c) {
						case 'i'.code, 'g'.code, 'm'.code, 's'.code, 'u'.code:
							m.addChar(c);
						default:
							error(ECustom('Invalid regular expression option'), p1, p1);
					}
				}
				break;
			} else {
				p.addChar(c);
			}
		}

		readPos--;
		return TConst(CReg(p.toString(), m.toString()));
	}

	/**
	 * Reads the next token from the input (or replays a pushed-back one), skipping whitespace and
	 * comments and handling metadata and preprocessor tokens.
	 *
	 * @param interpolateStrings Whether single-quoted strings should be tokenized as interpolatable.
	 * @return The next token.
	 */
	function token(interpolateStrings:Bool = true) {
		var t = tokens.pop();
		if (t != null) {
			tokenMin = t.min;
			tokenMax = t.max;
			return t.t;
		}
		oldTokenMin = tokenMin;
		oldTokenMax = tokenMax;
		tokenMin = (this.char < 0) ? currentPos : currentPos - 1;
		var t = _token(interpolateStrings);
		tokenMax = (this.char < 0) ? currentPos - 1 : currentPos - 2;
		return t;
	}

	/**
	 * Reads the next token. `token` wraps this to record the token's extent for error positions.
	 *
	 * @param interpolateStrings Whether a single-quoted string is scanned for `$` interpolation.
	 * @return The token.
	 */
	function _token(interpolateStrings:Bool = true) {
		var char;
		var colOffset:Int = this.columnOffset;
		if (this.char < 0)
			char = readChar();
		else {
			char = this.char;
			this.char = -1;
		}
		while (true) {
			if (StringTools.isEof(char)) {
				this.char = char;
				return TEof;
			}
			switch (char) {
				case 0:
					return TEof;
				case 32, 9, 13:
					tokenMin++;
				case 10:
					columnOffset = currentPos;
					line++;
					tokenMin++;
				case 48, 49, 50, 51, 52, 53, 54, 55, 56, 57:
					var n = (char - 48) * 1.0;
					var exp = 0.;
					while (true) {
						char = readChar();
						exp *= 10;
						switch (char) {
							case 48, 49, 50, 51, 52, 53, 54, 55, 56, 57:
								n = n * 10 + (char - 48);
							case "_".code:
							case "e".code, "E".code:
								var tk = token();
								var pow:Null<Int> = null;
								switch (tk) {
									case TConst(CInt(e)): pow = e;
									case TOp("-"):
										tk = token();
										switch (tk) {
											case TConst(CInt(e)): pow = -e;
											default: push(tk);
										}
									default:
										push(tk);
								}
								if (pow == null)
									invalidChar(char);
								var mantissa:Float = (exp > 0) ? n * 10 / exp : n;
								return TConst(CFloat(pow < 0 ? mantissa / Math.pow(10,
									-pow) : mantissa * Math.pow(10, pow)));
							case ".".code:
								if (exp > 0) {
									if (exp == 10 && readChar() == ".".code) {
										push(TOp("..."));
										var i = Std.int(n);
										return TConst((i == n) ? CInt(i) : CFloat(n));
									}
									invalidChar(char);
								}
								exp = 1.;
							case "x".code:
								if (n > 0 || exp > 0)
									invalidChar(char);
								var n = 0;
								while (true) {
									char = readChar();
									switch (char) {
										case 48, 49, 50, 51, 52, 53, 54, 55, 56, 57:
											n = (n << 4) + char - 48;
										case 65, 66, 67, 68, 69, 70:
											n = (n << 4) + (char - 55);
										case 97, 98, 99, 100, 101, 102:
											n = (n << 4) + (char - 87);
										case "_".code:
										default:
											this.char = char;
											return TConst(CInt(n));
									}
								}
							case "b".code:
								if (n > 0 || exp > 0)
									invalidChar(char);
								var n = 0;
								while (true) {
									char = readChar();
									switch (char) {
										case 48, 49:
											n = (n << 1) + (char - 48);
										case "_".code:
										default:
											this.char = char;
											return TConst(CInt(n));
									}
								}
							default:
								this.char = char;
								this.columnOffset = colOffset;
								var i = Std.int(n);
								return TConst((exp > 0) ? CFloat(n * 10 / exp) : ((i == n) ? CInt(i) : CFloat(n)));
						}
					}
				case ";".code:
					return TSemicolon;
				case "(".code:
					return TPOpen;
				case ")".code:
					return TPClose;
				case ",".code:
					return TComma;
				case ".".code:
					char = readChar();
					switch (char) {
						case 48, 49, 50, 51, 52, 53, 54, 55, 56, 57:
							var n = char - 48;
							var exp = 1;
							while (true) {
								char = readChar();
								exp *= 10;
								switch (char) {
									case 48, 49, 50, 51, 52, 53, 54, 55, 56, 57:
										n = n * 10 + (char - 48);
									default:
										this.char = char;
										this.columnOffset = colOffset;
										return TConst(CFloat(n / exp));
								}
							}
						case ".".code:
							char = readChar();
							if (char != ".".code)
								invalidChar(char);
							return TOp("...");
						default:
							this.char = char;
							this.columnOffset = colOffset;
							return TDot;
					}
				case "~".code:
					char = readChar();
					if (char == "/".code)
						return parseRegex();
					this.char = char;
					this.columnOffset = colOffset;
					return TOp("~");
				case "{".code:
					return TBrOpen;
				case "}".code:
					return TBrClose;
				case "[".code:
					return TBkOpen;
				case "]".code:
					return TBkClose;
				case "'".code, '"'.code:
					return parseString(char, interpolateStrings && char == "'".code);
				case "?".code:
					char = readChar();
					if (char == ".".code) {
						return TQuestionDot;
					} else if (char == '?'.code) {
						char = readChar();
						if (char == "=".code) {
							return TOp('??=');
						} else {
							return TOp('??');
						}
					}
					this.char = char;
					this.columnOffset = colOffset;
					return TQuestion;
				case ":".code:
					return TDoubleDot;
				case '='.code:
					char = readChar();
					if (char == '='.code)
						return TOp("==");
					else if (char == '>'.code)
						return TOp("=>");
					this.char = char;
					this.columnOffset = colOffset;
					return TOp("=");
				case '@'.code:
					char = readChar();
					if (idents[char] == true || char == ':'.code) {
						var start:Int = readPos - 1;
						while (true) {
							char = readChar();
							if (StringTools.isEof(char))
								char = 0;
							if (idents[char] != true) {
								this.char = char;
								this.columnOffset = colOffset;
								return TMeta(input.substr(start, readPos - 1 - start));
							}
						}
					}
					invalidChar(char);
				case '#'.code:
					char = readChar();
					if (idents[char] == true) {
						var start:Int = readPos - 1;
						while (true) {
							char = readChar();
							if (StringTools.isEof(char))
								char = 0;
							if (idents[char] != true) {
								this.char = char;
								this.columnOffset = colOffset;
								return preprocess(input.substr(start, readPos - 1 - start));
							}
						}
					}
					invalidChar(char);
				default:
					if (ops[char] == true) {
						var op = String.fromCharCode(char);
						while (true) {
							char = readChar();
							if (StringTools.isEof(char))
								char = 0;
							if (ops[char] != true) {
								this.char = char;
								return TOp(op);
							}
							var pop = op;
							op += String.fromCharCode(char);
							if (!opPriority.exists(op) && opPriority.exists(pop)) {
								if (op == "//" || op == "/*")
									return tokenComment(op, char);
								this.char = char;
								this.columnOffset = colOffset;
								return TOp(pop);
							}
						}
					}
					if (idents[char] == true) {
						var start:Int = readPos - 1;
						while (true) {
							char = readChar();
							if (StringTools.isEof(char))
								char = 0;
							if (idents[char] != true) {
								this.char = char;
								return TId(input.substr(start, readPos - 1 - start));
							}
						}
					}
					invalidChar(char);
			}
			char = readChar();
		}
		return null;
	}

	/**
	 * Looks up a preprocessor define's value.
	 *
	 * @param id The define name.
	 * @return Its value, or null if undefined.
	 */
	function preprocValue(id:String):Dynamic {
		return (preprocessorValues.get(id) ?? Config.preprocessorValues.get(id));
	}

	/** The stack of open `#if` branches, each recording whether it is currently active. */
	var preprocStack:Array<{r:Bool}>;

	/** Comparison/logic operators available inside `#if` conditions. */
	var preprocessorBinops:Map<String, Dynamic->Dynamic->Bool>;

	/**
	 * Parses the condition expression of a `#if`/`#elseif`.
	 *
	 * @return The condition expression.
	 */
	function parsePreproCond() {
		var tk = token();
		return switch (tk) {
			case TPOpen:
				var e = preproExpr();
				ensure(TPClose);
				e;
			case TId(id):
				mk(EIdent(id), tokenMin, tokenMax);
			case TOp("!"):
				mk(EUnop("!", true, parsePreproCond()), tokenMin, tokenMax);
			default:
				unexpected(tk);
		}
	}

	/**
	 * Evaluates a `#if`/`#elseif` condition against the preprocessor defines.
	 *
	 * @param e The condition expression.
	 * @return The condition's value.
	 */
	function evalPreproCond(e:Expr):Dynamic {
		switch (expr(e)) {
			case EIdent(id):
				return preprocValue(id);
			case EConst(CInt(v)):
				return v;
			case EConst(CFloat(v)):
				return v;
			case EConst(CString(v)):
				return v;
			case EUnop("!", _, e):
				var v:Dynamic = evalPreproCond(e);
				return (v is Bool ? !v : v == null);
			case EParent(e):
				return evalPreproCond(e);
			case EBinop(op, e1, e2) if (preprocessorBinops.exists(op)):
				return preprocessorBinops.get(op)(evalPreproCond(e1), evalPreproCond(e2));
			case EBinop(op, _, _):
				error(EInvalidPreprocessor('Unsupported operation $op'), currentPos, currentPos);
				return null;
			default:
				error(EInvalidPreprocessor(expr(e).getName()), currentPos, currentPos);
				return null;
		}
	}

	/**
	 * Handles a preprocessor directive (`#if`/`#elseif`/`#else`/`#end`/`#error`), skipping the
	 * inactive branches, and returns the next real token.
	 *
	 * @param id The directive name.
	 * @return The next token after the directive is applied.
	 */
	function preprocess(id:String):Token {
		switch (id) {
			case "if":
				var e = parsePreproCond();
				var v:Dynamic = evalPreproCond(e);

				if (v != null && (!(v is Bool) || v != false)) {
					preprocStack.push({r: true});
					return token();
				}

				preprocStack.push({r: false});
				skipTokens();

				return token();
			case "else", "elseif" if (preprocStack.length > 0):
				if (preprocStack[preprocStack.length - 1].r) {
					preprocStack[preprocStack.length - 1].r = false;
					skipTokens();
					return token();
				} else if (id == "else") {
					preprocStack.pop();
					preprocStack.push({r: true});
					return token();
				} else {
					preprocStack.pop();
					return preprocess("if");
				}
			case "end" if (preprocStack.length > 0):
				preprocStack.pop();
				return token();
			case 'error':
				if (preprocStack.length < 1 || preprocStack[preprocStack.length - 1].r) {
					var string:String = switch (expr(preproExpr())) {
						case EConst(CString(v)): v;
						default: 'Not implemented';
					};
					error(ECustom(string), currentPos, currentPos);
				}

				return token();
			default:
				return TPrepro(id);
		}
	}

	/**
	 * Skips tokens of an inactive preprocessor branch until its matching `#else`/`#elseif`/`#end`.
	 *
	 * @return The directive token that ended the skipped region.
	 */
	function skipTokens() {
		var spos = preprocStack.length - 1;
		var obj = preprocStack[spos];
		var pos = currentPos;
		while (true) {
			var tk = token();
			if (preprocStack[spos] != obj) {
				push(tk);
				break;
			}
			if (tk == TEof)
				error(EInvalidPreprocessor("Unclosed"), pos, pos);
		}
	}

	/**
	 * Consumes a line (`//`) or block (`/* *\/`) comment.
	 *
	 * @param op The comment-opening operator text read so far.
	 * @param char The character following it.
	 * @return The next token after the comment.
	 */
	function tokenComment(op:String, char:Int) {
		var c = op.charCodeAt(1);
		var s = input;
		if (c == '/'.code) {
			while (char != '\r'.code && char != '\n'.code) {
				char = readChar();
				if (StringTools.isEof(char))
					break;
			}
			this.char = char;
			return token();
		}
		if (c == '*'.code) {/* comment */
			var old = line;
			if (op == "/**/") {
				this.char = char;
				return token();
			}
			while (true) {
				while (char != '*'.code) {
					if (char == '\n'.code) {
						columnOffset = currentPos;
						line++;
					}
					char = readChar();
					if (StringTools.isEof(char)) {
						line = old;
						error(EUnterminatedComment, tokenMin, tokenMin);
						break;
					}
				}
				char = readChar();
				if (StringTools.isEof(char)) {
					line = old;
					error(EUnterminatedComment, tokenMin, tokenMin);
					break;
				}
				if (char == '/'.code)
					break;
			}
			return token();
		}
		this.char = char;
		return TOp(op);
	}

	/**
	 * Renders a constant's literal text (for error messages and token strings).
	 *
	 * @param c The constant.
	 * @return Its source-like text.
	 */
	function constString(c) {
		return switch (c) {
			case CInt(v): Std.string(v);
			case CFloat(f): Std.string(f);
			case CString(s): s;
			case CReg(p, m): '~/$p/$m';
		}
	}

	/**
	 * Renders a token as source-like text (for error messages).
	 *
	 * @param t The token.
	 * @return Its display text.
	 */
	function tokenString(t) {
		return switch (t) {
			case TEof: "<eof>";
			case TConst(c): constString(c);
			case TId(s): s;
			case TOp(s): s;
			case TPOpen: "(";
			case TPClose: ")";
			case TBrOpen: "{";
			case TBrClose: "}";
			case TDot: ".";
			case TQuestionDot: "?.";
			case TComma: ",";
			case TSemicolon: ";";
			case TBkOpen: "[";
			case TBkClose: "]";
			case TQuestion: "?";
			case TDoubleDot: ":";
			case TMeta(id): "@" + id;
			case TPrepro(id): "#" + id;
		}
	}

	/**
	 * Sets up the character tables and the operators usable inside `#if` conditions.
	 */
	public function new() {
		line = 1;
		opChars = "+*/-=!><&|^%~";
		identChars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_";

		/**
		 * One row per precedence level, loosest last, because the row's INDEX is the priority: the
		 * loop below writes `i` into `opPriority` and asks `i == 10` to mark the assignments
		 * right-associative. So a row moving is a silent change to how every expression parses, which
		 * is why the indices are written down and why `@formatter:off` keeps the rows one to a line.
		 */
		// @formatter:off
		var priorities = [
			/*  0 */ ["%"],
			/*  1 */ ["*", "/"],
			/*  2 */ ["+", "-"],
			/*  3 */ ["<<", ">>", ">>>"],
			/*  4 */ ["|", "&", "^"],
			/*  5 */ ["??"],
			/*  6 */ ["==", "!=", ">", "<", ">=", "<="],
			/*  7 */ ["..."],
			/*  8 */ ["&&"],
			/*  9 */ ["||"],
			/* 10 */ ["=", "+=", "-=", "*=", "/=", "%=", "<<=", ">>=", ">>>=", "|=", "&=", "^=", "=>", "??="],
			/* 11 */ ["->"],
			/* 12 */ ["in", "is"]
		];
		// @formatter:on
		opPriority = new Map();
		opRightAssoc = new Map();
		for (i in 0...priorities.length) {
			for (x in priorities[i]) {
				opPriority.set(x, i);
				if (i == 10)
					opRightAssoc.set(x, true);
			}
		}

		for (x in ["!", "++", "--", "~"])
			opPriority.set(x, x == "++" || x == "--" ? -1 : -2);

		preprocessorBinops = [
			'&&' => function(a:Dynamic, b:Dynamic) return (a && b),
			'||' => function(a:Dynamic, b:Dynamic) return (a || b),
			'==' => function(a:Dynamic, b:Dynamic) return (a == b),
			'!=' => function(a:Dynamic, b:Dynamic) return (a != b),
			'>=' => function(a:Dynamic, b:Dynamic) return (a >= b),
			'<=' => function(a:Dynamic, b:Dynamic) return (a <= b),
			'>' => function(a:Dynamic, b:Dynamic) return (a > b),
			'<' => function(a:Dynamic, b:Dynamic) return (a < b)
		];
	}

	/**
	 * Resets the scanner for a fresh pass over `input`.
	 *
	 * @param origin The source origin, used for error positions.
	 * @param pos The starting byte offset.
	 */
	function initLexer(origin, pos) {
		columnOffset = 0;
		line = 1;
		preprocStack = [];
		this.origin = origin;
		readPos = 0;
		tokenMin = oldTokenMin = pos;
		tokenMax = oldTokenMax = pos;
		tokens = [];
		offset = pos;
		char = -1;
		ops = new Array();
		idents = new Array();
		for (i in 0...opChars.length)
			ops[opChars.charCodeAt(i)] = true;
		for (i in 0...identChars.length)
			idents[identChars.charCodeAt(i)] = true;
	}

	/**
	 * The expression inside a `#if (...)` condition. Conditions are the one place the scanner needs
	 * the grammar, so `Parser` overrides this; the scanner on its own has no expression parser.
	 *
	 * @return The parsed condition expression.
	 */
	function preproExpr():Expr {
		return unexpected(token());
	}
}
