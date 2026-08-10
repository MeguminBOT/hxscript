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

/**
 * Recursive-descent parser turning script source into `Expr` and `ModuleDecl` trees.
 *
 * Token scanning, the preprocessor and source positions live in `Lexer`, which this extends so the
 * grammar can read tokens without threading a scanner through every call.
 */
class Parser extends Lexer {
	/** Whether the parser is currently at a declaration position. */
	var decl:Bool;

	/** The package being parsed into. */
	var pack:Array<String>;

	/** Counter for anonymous-function ids. */
	var fid:Int = 0;

	/** Counter for unique ids. */
	var uid:Int = 0;

	/**
	 * Parses a full script into a single expression (a block if it has several statements).
	 *
	 * @param s The source text.
	 * @param origin The source origin for error positions.
	 * @param position The starting byte offset.
	 * @return The parsed program expression.
	 */
	public function parseScript(s:String, ?origin:String = "hscript", ?position:Int = 0) {
		initParser(origin, position);
		input = s;
		readPos = 0;
		var a = new Array();
		while (true) {
			var tk = token();
			if (tk == TEof)
				break;
			push(tk);
			parseFullExpr(a);
		}
		return if (a.length == 1) a[0] else mk(EBlock(a), 0);
	}

	/**
	 * Whether an expression ends in a brace block (so no trailing `;` is required after it).
	 *
	 * @param e The expression to test.
	 * @return True if it is block-like.
	 */
	function isBlock(e) {
		if (e == null)
			return false;
		return switch (expr(e)) {
			case EBlock(_), EObject(_), ESwitch(_): true;
			case EFunction(_, e, _, _): isBlock(e);
			case EVar(_, t, e): e != null ? isBlock(e) : t != null ? t.match(CTAnon(_)) : false;
			case EIf(_, e1, e2): if (e2 != null) isBlock(e2) else isBlock(e1);
			case EBinop(_, _, e): isBlock(e);
			case EUnop(_, prefix, e): !prefix && isBlock(e);
			case EWhile(_, e): isBlock(e);
			case EDoWhile(_, e): isBlock(e);
			case EFor(_, _, e), EForGen(_, e): isBlock(e);
			case EReturn(e): e != null && isBlock(e);
			case ETry(_, _, _, e): isBlock(e);
			case EMeta(":markup", _, _): true;
			case EMeta(_, _, e): isBlock(e);
			default: false;
		}
	}

	/**
	 * Parses one full statement into `exprs`, expanding a comma-separated `var a, b, c;` into several.
	 *
	 * @param exprs The list to append the parsed expression(s) to.
	 */
	function parseFullExpr(exprs:Array<Expr>) {
		var e = parseExpr();
		exprs.push(e);

		var tk = token();
		while (tk == TComma && e != null && expr(e).match(EVar(_))) {
			e = parseStructure("var");
			exprs.push(e);
			tk = token();
		}

		if (tk != TSemicolon && tk != TEof) {
			if (isBlock(e))
				push(tk);
			else
				unexpected(tk);
		}
	}

	/**
	 * Parses an anonymous object literal (its opening brace already consumed).
	 *
	 * @param p1 The start offset of the literal.
	 * @return The object expression (with any following postfix access parsed).
	 */
	function parseObject(p1) {
		var fl = new Array();
		while (true) {
			var tk = token(false);
			var id = null;
			switch (tk) {
				case TId(i):
					id = i;
				case TConst(c):
					if (!allowJSON)
						unexpected(tk);
					switch (c) {
						case CString(s): id = s;
						default: unexpected(tk);
					}
				case TBrClose:
					break;
				default:
					unexpected(tk);
					break;
			}
			ensure(TDoubleDot);
			fl.push({name: id, e: parseExpr()});
			tk = token();
			switch (tk) {
				case TBrClose:
					break;
				case TComma:
				default:
					unexpected(tk);
			}
		}
		return parseExprNext(mk(EObject(fl), p1));
	}

	/**
	 * Turns a single-quoted string's `$ident` / `${expr}` interpolations into a chain of string
	 * concatenations.
	 *
	 * @param s The literal text preceding the interpolation cursor.
	 * @return An expression evaluating to the interpolated string.
	 */
	function interpolateString(s:String) {
		var se = mk(EConst(CString(s)));

		while (true) {
			var e:Expr = null;

			var c = StringTools.fastCodeAt(input, readPos);
			if (idents[c]) {
				var ident:String = '';
				while (true) {
					var c = readChar();
					if (!idents[c] || StringTools.isEof(c)) {
						readPos--;
						break;
					} else {
						ident += String.fromCharCode(c);
					}
				}
				e = mk(EIdent(ident.toString()));
			} else {
				ensure(TBrOpen);
				e = parseExpr();
				ensure(TBrClose);
			}

			var r = parseString("'".code, true);

			switch (r) {
				case TConst(CString(s, i)):
					se = mk(EBinop('+', mk(EBinop('+', se, e)), mk(EConst(CString(s)))));

					if (i == null || !i)
						break;
				default:
			}
		}

		return mk(EParent(se));
	}

	/**
	 * Parses a single (possibly compound) expression, dispatching on the leading token.
	 *
	 * @param type An optional expected type, threaded through for typed forms.
	 * @return The parsed expression.
	 */
	function parseExpr(?type) {
		var tk = token();
		var p1 = tokenMin;

		switch (tk) {
			case TId(id):
				var e = parseStructure(id, type);
				if (e == null)
					e = mk(EIdent(id));
				return parseExprNext(e);
			case TConst(CString(s, true)):
				return parseExprNext(interpolateString(s));
			case TConst(c):
				return parseExprNext(mk(EConst(c)));
			case TPOpen:
				tk = token();
				if (tk == TPClose) {
					ensureToken(TOp("->"));
					var eret = parseExpr();
					return mkLambda([], eret, p1);
				}
				push(tk);
				var e = parseExpr();
				tk = token();
				switch (tk) {
					case TPClose:
						return parseExprNext(mk(EParent(e), p1, tokenMax));
					case TDoubleDot:
						var t = parseType();
						tk = token();
						switch (tk) {
							case TPClose:
								return parseExprNext(mk(ECheckType(e, t), p1, tokenMax));
							case TComma:
								switch (expr(e)) {
									case EIdent(v): return parseLambda([{name: v, t: t}], pmin(e));
									default:
								}
							default:
						}
					case TComma:
						switch (expr(e)) {
							case EIdent(v): return parseLambda([{name: v}], pmin(e));
							default:
						}
					case TEof if (resumeErrors):
						return e;
					default:
				}
				return unexpected(tk);
			case TBrOpen:
				tk = token();
				switch (tk) {
					case TBrClose:
						return parseExprNext(mk(EObject([]), p1));
					case TId(_):
						var tk2 = token();
						push(tk2);
						push(tk);
						switch (tk2) {
							case TDoubleDot:
								return parseExprNext(parseObject(p1));
							default:
						}
					case TConst(CString(s, true)):
						push(tk);
					case TConst(c):
						if (allowJSON) {
							switch (c) {
								case CString(s):
									var tk2 = token();
									push(tk2);
									push(tk);
									switch (tk2) {
										case TDoubleDot:
											return parseExprNext(parseObject(p1));
										default:
									}
								default:
									push(tk);
							}
						} else push(tk);
					default:
						push(tk);
				}
				var a = new Array();
				while (true) {
					parseFullExpr(a);
					tk = token();
					if (tk == TBrClose || (resumeErrors && tk == TEof))
						break;
					push(tk);
				}
				return mk(EBlock(a), p1);
			case TOp(op):
				if (op == "-") {
					var start = tokenMin;
					var e = parseExpr();
					if (e == null)
						return makeUnop(op, e);
					switch (expr(e)) {
						case EConst(CInt(i)):
							return mk(EConst(CInt(-i)), start, pmax(e));
						case EConst(CFloat(f)):
							return mk(EConst(CFloat(-f)), start, pmax(e));
						default:
							return makeUnop(op, e);
					}
				}
				if (opPriority.get(op) < 0)
					return makeUnop(op, parseExpr());
				if (op == "<") {
					var start = readPos - 1;
					var ident = getIdent();
					if (tokens.length != 0)
						throw "assert";
					if (readPos == start + ident.length + 1) {
						var endTag = "</" + ident + ">";
						var end = input.indexOf(endTag, readPos);
						if (end < 0) {
							endTag = '/>';
							end = input.indexOf(endTag, readPos);
						}
						if (end >= 0) {
							readPos = end + endTag.length;
							char = -1;
							start--;
							var end = readPos - 1;
							tokenMin = (start + offset);
							tokenMax = (end + offset);
							var str = input.substr(start, end - start + 1);
							return mk(EMeta(":markup", [], mk(EConst(CString(str)))));
						}
					}
				}
				return unexpected(tk);
			case TBkOpen:
				var a = new Array();
				tk = token();
				var first = true;
				while (tk != TBkClose && (!resumeErrors || tk != TEof)) {
					if (!first) {
						if (tk != TComma)
							unexpected(tk);
						else {
							tk = token();
							if (tk == TBkClose)
								break;
						}
					}
					first = false;
					push(tk);
					a.push(parseExpr());
					tk = token();
				}
				return parseExprNext(mk(EArrayDecl(a), p1));
			case TMeta(id) if (allowMetadata):
				var args = parseMetaArgs();
				return mk(EMeta(id, args, parseExpr()), p1);
			default:
				return unexpected(tk);
		}
	}

	/**
	 * Parses the remaining parameters of an arrow lambda `(a, b) -> expr` and its body.
	 *
	 * @param args The already-parsed leading arguments.
	 * @param pmin The lambda's start offset.
	 * @return The function expression.
	 */
	function parseLambda(args:Array<Argument>, pmin) {
		while (true) {
			var id = getIdent();
			var t = maybe(TDoubleDot) ? parseType() : null;
			args.push({name: id, t: t});
			var tk = token();
			switch (tk) {
				case TComma:
				case TPClose:
					break;
				default:
					unexpected(tk);
					break;
			}
		}
		ensureToken(TOp("->"));
		var eret = parseExpr();
		return mkLambda(args, eret, pmin);
	}

	/**
	 * Builds a lambda whose body returns `eret`.
	 *
	 * @param args The arguments.
	 * @param eret The body expression, wrapped in a `return`.
	 * @param p The start offset.
	 * @return The function expression.
	 */
	function mkLambda(args, eret, p) {
		return mk(EFunction(args, mk(EReturn(eret), pmin(eret)), ++fid), p);
	}

	/**
	 * Parses a metadata entry's `(args)`, if present.
	 *
	 * @return The argument expressions, or null when there are no parentheses.
	 */
	function parseMetaArgs() {
		var tk = token();
		if (tk != TPOpen) {
			push(tk);
			return null;
		}
		var args = [];
		tk = token();
		if (tk != TPClose) {
			push(tk);
			while (true) {
				args.push(parseExpr());
				switch (token()) {
					case TComma:
					case TPClose:
						break;
					case tk:
						unexpected(tk);
				}
			}
		}
		return args;
	}

	/**
	 * Builds a prefix unary operation, pushing it inside a binary/ternary operand to respect precedence.
	 *
	 * @param op The unary operator.
	 * @param e The operand expression.
	 * @return The resulting expression.
	 */
	function makeUnop(op, e) {
		if (e == null && resumeErrors)
			return null;
		return switch (expr(e)) {
			case EBinop(bop, e1, e2): mk(EBinop(bop, makeUnop(op, e1), e2), pmin(e1), pmax(e2));
			case ETernary(e1, e2, e3): mk(ETernary(makeUnop(op, e1), e2, e3), pmin(e1), pmax(e3));
			default: mk(EUnop(op, true, e), pmin(e), pmax(e));
		}
	}

	/**
	 * Builds a binary operation, rebalancing against the right operand so operator precedence and
	 * associativity come out correct.
	 *
	 * @param op The operator.
	 * @param e1 The left operand.
	 * @param e The right operand (already parsed).
	 * @return The resulting expression.
	 */
	function makeBinop(op, e1, e) {
		if (e == null && resumeErrors)
			return mk(EBinop(op, e1, e), pmin(e1), pmax(e1));
		return switch (expr(e)) {
			case EBinop(op2, e2, e3):
				var delta = opPriority.get(op) - opPriority.get(op2);
				if (delta < 0
					|| (delta == 0 && !opRightAssoc.exists(op))) mk(EBinop(op2, makeBinop(op, e1, e2), e3), pmin(e1),
						pmax(e3)); else mk(EBinop(op, e1, e), pmin(e1), pmax(e));
			case ETernary(e2, e3, e4):
				if (opRightAssoc.exists(op)) mk(EBinop(op, e1, e), pmin(e1), pmax(e)); else mk(ETernary(makeBinop(op, e1, e2), e3, e4), pmin(e1), pmax(e));
			default:
				mk(EBinop(op, e1, e), pmin(e1), pmax(e));
		}
	}

	/**
	 * Parses a keyword-led construct (`if`, `while`, `for`, `switch`, `try`, `var`, `function`,
	 * `return`, `import`, `using`, `cast`, `new`, and so on), dispatched by the leading keyword.
	 *
	 * @param id The leading keyword.
	 * @param type An optional expected type for typed forms.
	 * @return The parsed expression.
	 */
	function parseStructure(id, ?type) {
		var p1 = tokenMin;

		if (id != 'import' && id != 'using')
			decl = true;

		return switch (id) {
			case "using":
				if (decl)
					error(ECustom('import and using may not appear after a declaration'), p1, tokenMax);

				var path:Array<String> = [getIdent()];

				while (true) {
					var t = token();
					if (t != TDot) {
						push(t);
						break;
					}

					t = token();
					switch (t) {
						case TId(id):
							path.push(id);
						default:
							unexpected(t);
					}
				}

				mk(EUsing(path));
			case "import":
				if (decl)
					error(ECustom('import and using may not appear after a declaration'), p1, tokenMax);

				var path:Array<String> = [getIdent()];
				var mode:ImportMode = INormal;
				var tid:String = null;

				if (path[0].isTypeIdentifier())
					tid = path[0];

				while (true) {
					var t = token();
					if (t != TDot) {
						push(t);
						break;
					}

					t = token();
					switch (t) {
						case TId(id):
							if (mode == IAll)
								unexpected(t);

							if (tid != null || id.isTypeIdentifier())
								tid = id;

							path.push(id);
						case TOp("*"):
							if (tid != null)
								unexpected(t);

							mode = IAll;
						default:
							unexpected(t);
					}
				}

				if (mode != IAll && (maybe(TId('as')) || maybe(TId('in')))) {
					if (tid == null)
						error(ECustom('Module name must start with an uppercase letter'), p1, tokenMax);

					var t = token();
					switch (t) {
						case TId(id):
							if (!id.isTypeIdentifier() && tid.isTypeIdentifier())
								error(ECustom('Type aliases must start with an uppercase letter'), p1, tokenMax);

							mode = IAsName(id);
						default:
							unexpected(t);
					}
				}

				mk(EImport(path, mode));
			case "class", "interface", "enum", "typedef", "abstract":
				push(TId(id));
				var decl = parseModuleDecl();
				if (!maybe(TSemicolon))
					push(TSemicolon);

				mk(EDecl(decl));
			case "final" if (peekIdent("class")):
				push(TId(id));
				var decl = parseModuleDecl();
				if (!maybe(TSemicolon))
					push(TSemicolon);

				mk(EDecl(decl));
			case "if":
				ensure(TPOpen);
				var cond = parseExpr();
				ensure(TPClose);
				var e1 = parseExpr();
				var e2 = null;
				var semic = false;
				var tk = token();
				if (tk == TSemicolon) {
					semic = true;
					tk = token();
				}
				if (Type.enumEq(tk, TId("else")))
					e2 = parseExpr();
				else {
					push(tk);
					if (semic)
						push(TSemicolon);
				}
				mk(EIf(cond, e1, e2), p1, (e2 == null) ? tokenMax : pmax(e2));
			case "var", "final":
				var ident = getIdent();
				var get = null, set = null;
				if (id == 'var' && maybe(TPOpen)) {
					get = getIdent();
					ensure(TComma);
					set = getIdent();
					ensure(TPClose);
				}
				var tk = token();
				var t = null;
				if (tk == TDoubleDot && allowTypes) {
					t = parseType();
					tk = token();
				}
				var e = null;

				switch (tk) {
					case TOp("="): e = parseExpr(t);
					case TOp(_): unexpected(tk);
					case TComma | TSemicolon: push(tk);
					case _ if (t != null): push(tk);
					default: unexpected(tk);
				}

				mk(EVar(ident, t, e, get, set, id == 'final'), p1, (e == null) ? tokenMax : pmax(e));
			case "while":
				var econd = parseExpr();
				var e = parseExpr();
				mk(EWhile(econd, e), p1, pmax(e));
			case "do":
				var e = parseExpr();
				maybe(TSemicolon);
				var tk = token();
				switch (tk) {
					case TId("while"):
					default: unexpected(tk);
				}
				var econd = parseExpr();
				mk(EDoWhile(econd, e), p1, pmax(econd));
			case "for":
				ensure(TPOpen);
				var eit = parseExpr();
				ensure(TPClose);
				var e = parseExpr();
				switch (expr(eit)) {
					case EBinop("in", ev, eit):
						switch (expr(ev)) {
							case EIdent(v):
								return mk(EFor(v, eit, e), p1, pmax(e));
							default:
						}
					default:
				}
				mk(EForGen(eit, e), p1, pmax(e));
			case "break": mk(EBreak);
			case "continue": mk(EContinue);
			case "else": unexpected(TId(id));
			case "inline":
				if (!maybe(TId("function")))
					unexpected(TId("inline"));
				return parseStructure("function");
			case "function":
				var tk = token();
				var name = null;
				switch (tk) {
					case TId(id): name = id;
					default: push(tk);
				}
				var inf = parseFunctionDecl();
				mk(EFunction(inf.args, inf.body, name, inf.ret, (name == null ? ++fid : null)), p1, pmax(inf.body));
			case "return":
				var tk = token();
				push(tk);
				var e = if (tk == TSemicolon) null else parseExpr();
				mk(EReturn(e), p1, if (e == null) tokenMax else pmax(e));
			case "new":
				var a = new Array();
				a.push(getIdent());
				var targs:Array<CType> = null;
				while (true) {
					var tk = token();
					switch (tk) {
						case TDot:
							a.push(getIdent());
						case TPOpen:
							break;
						case TOp(op) if (op == "<" && targs == null):
							push(tk);
							targs = parseTypeArgs();
						default:
							unexpected(tk);
							break;
					}
				}
				var args = parseExprList(TPClose);
				mk(ENew(mapClassFor(a.join("."), targs), args), p1);
			case "throw":
				var e = parseExpr();
				mk(EThrow(e), p1, pmax(e));
			case "try":
				var e = parseExpr();
				ensureToken(TId("catch"));
				/**
				 * Parses one `catch (v:T) expr` clause.
				 *
				 * The first clause fills `v`/`t`/`ecatch` and the rest go into `extra`, matched in declaration
				 * order at runtime (typed multi-catch).
				 *
				 * @return The clause's variable, declared type and body.
				 */
				function parseCatch():{v:String, t:Null<CType>, expr:Expr} {
					ensure(TPOpen);
					var cv = getIdent();
					var ct:Null<CType> = null;
					if (maybe(TDoubleDot)) {
						if (allowTypes)
							ct = parseType();
						else
							ensureToken(TId("Dynamic"));
					}
					ensure(TPClose);
					return {v: cv, t: ct, expr: parseExpr()};
				}
				var head = parseCatch();
				var extra:Array<{v:String, t:Null<CType>, expr:Expr}> = null;
				while (true) {
					var tk = token();
					switch (tk) {
						case TId("catch"):
							if (extra == null)
								extra = [];
							extra.push(parseCatch());
						default:
							push(tk);
							break;
					}
				}
				mk(ETry(e, head.v, head.t, head.expr, extra), p1, tokenMax);
			case "switch":
				var e = parseExpr();
				var def = null, cases = [];
				ensure(TBrOpen);
				while (true) {
					var tk = token();
					switch (tk) {
						case TId("case"):
							var c = {values: [], expr: null, guard: null};
							cases.push(c);
							while (true) {
								var e:Expr;

								if (maybe(TId('var'))) {
									e = mk(EVar(getIdent()), p1);
								} else {
									e = parseExpr();
								}

								c.values.push(e);
								tk = token();

								switch (tk) {
									case TId('if'):
										ensure(TPOpen);
										c.guard = parseExpr();
										ensure(TPClose);

										switch (tk = token()) {
											case TDoubleDot:
												break;
											default:
												unexpected(tk);
												break;
										}
									case TComma:
									case TDoubleDot:
										break;
									default:
										unexpected(tk);
										break;
								}
							}
							var exprs = [];
							while (true) {
								tk = token();
								push(tk);
								switch (tk) {
									case TId("case"), TId("default"), TBrClose:
										break;
									case TEof if (resumeErrors):
										break;
									default:
										parseFullExpr(exprs);
								}
							}
							c.expr = if (exprs.length == 1) exprs[0]; else if (exprs.length == 0) mk(EBlock([]), tokenMin,
								tokenMin); else mk(EBlock(exprs), pmin(exprs[0]), pmax(exprs[exprs.length - 1]));
						case TId("default"):
							if (def != null)
								unexpected(tk);
							ensure(TDoubleDot);
							var exprs = [];
							while (true) {
								tk = token();
								push(tk);
								switch (tk) {
									case TId("case"), TId("default"), TBrClose:
										break;
									case TEof if (resumeErrors):
										break;
									default:
										parseFullExpr(exprs);
								}
							}
							def = if (exprs.length == 1) exprs[0]; else if (exprs.length == 0) mk(EBlock([]), tokenMin,
								tokenMin); else mk(EBlock(exprs), pmin(exprs[0]), pmax(exprs[exprs.length - 1]));
						case TBrClose:
							break;
						default:
							unexpected(tk);
							break;
					}
				}
				mk(ESwitch(e, cases, def), p1, tokenMax);
			case "cast":
				var tk = token();
				if (tk == TPOpen) {
					var e = parseExpr();
					ensure(TComma);
					var t = parseType();
					ensure(TPClose);
					mk(ECast(e, t), p1, tokenMax);
				} else {
					push(tk);
					var e = parseExpr();
					mk(ECast(e, type), p1, tokenMax);
				}
			case "untyped":
				parseExpr();
			default:
				null;
		}
	}

	/**
	 * Parses whatever can follow an expression (field access, calls, indexing, binary operators,
	 * ternary, etc.), extending `e1` until the expression ends.
	 *
	 * @param e1 The expression parsed so far.
	 * @return The (possibly extended) expression.
	 */
	function parseExprNext(e1:Expr) {
		var tk = token();
		switch (tk) {
			case TOp(op):
				if (op == "->") {
					switch (expr(e1)) {
						case EIdent(i), EParent(expr(_) => EIdent(i)):
							var eret = parseExpr();
							return mkLambda([{name: i}], eret, pmin(e1));
						case ECheckType(expr(_) => EIdent(i), t):
							var eret = parseExpr();
							return mkLambda([{name: i, t: t}], eret, pmin(e1));
						default:
					}
					unexpected(tk);
				}

				if (opPriority.get(op) == -1) {
					if (isBlock(e1) || switch (expr(e1)) {
							case EParent(_): true;
							default: false;
						}) {
						push(tk);
						return e1;
						}
					return parseExprNext(mk(EUnop(op, false, e1), pmin(e1)));
				}
				return makeBinop(op, e1, parseExpr());
			case TId(op) if (opPriority.exists(op)):
				return parseExprNext(makeBinop(op, e1, parseExpr()));
			case TDot | TQuestionDot:
				var field = getIdent();
				return parseExprNext(mk(EField(e1, field, tk == TQuestionDot), pmin(e1)));
			case TPOpen:
				return parseExprNext(mk(ECall(e1, parseExprList(TPClose)), pmin(e1)));
			case TBkOpen:
				var e2 = parseExpr();
				ensure(TBkClose);
				return parseExprNext(mk(EArray(e1, e2), pmin(e1)));
			case TQuestion:
				var e2 = parseExpr();
				ensure(TDoubleDot);
				var e3 = parseExpr();
				return mk(ETernary(e1, e2, e3), pmin(e1), pmax(e3));
			default:
				push(tk);
				return e1;
		}
	}

	/**
	 * Parses a function's parenthesized argument list (optionals, defaults, and rest).
	 *
	 * @param restAllowed Whether a trailing rest (`...`) argument is permitted.
	 * @return The parsed arguments.
	 */
	function parseFunctionArgs(restAllowed:Bool = true) {
		var args = new Array();
		var hasRest = false;
		var tk = token();
		if (tk != TPClose) {
			var done = false;
			while (!done) {
				var name = null, opt = false, rest = false;
				switch (tk) {
					case TQuestion:
						opt = true;
						tk = token();
					case TOp('...'):
						if (!restAllowed)
							unexpected(tk);
						rest = true;
						tk = token();
					default:
				}

				switch (tk) {
					case TId(id):
						if (hasRest)
							error(ECustom('Rest should only be used for the last function argument'), tokenMin, tokenMax);
						hasRest = rest;
						name = id;
					default:
						unexpected(tk);
						break;
				}

				var arg:Argument = {name: name, rest: rest, opt: opt};
				if (allowTypes) {
					if (maybe(TDoubleDot))
						arg.t = parseType();
					if (maybe(TOp("="))) {
						if (rest)
							error(ECustom('Rest argument cannot have default value'), tokenMin, tokenMax);
						arg.value = parseExpr();
						arg.opt = true;
					}
				}

				args.push(arg);
				tk = token();

				switch (tk) {
					case TComma:
						tk = token();
					case TPClose:
						done = true;
					default:
						unexpected(tk);
				}
			}
		}
		return args;
	}

	/**
	 * Parses a function's arguments, optional return type, and body.
	 *
	 * @param allowNoBody Whether a bodyless signature (interface/extern) is permitted.
	 * @return The parsed arguments, return type, and body expression.
	 */
	function parseFunctionDecl(allowNoBody:Bool = false) {
		parseParams();
		ensure(TPOpen);
		var args = parseFunctionArgs();
		var ret = null;
		if (allowTypes) {
			var tk = token();
			if (tk != TDoubleDot)
				push(tk);
			else
				ret = parseType();
		}
		if (allowNoBody && maybe(TSemicolon))
			return {args: args, ret: ret, body: null};
		return {args: args, ret: ret, body: parseExpr()};
	}

	/**
	 * Parses a dotted type/module path.
	 *
	 * @return The path segments.
	 */
	function parsePath() {
		var path = [getIdent()];
		while (true) {
			var t = token();
			if (t != TDot) {
				push(t);
				break;
			}
			path.push(getIdent());
		}
		return path;
	}

	/**
	 * Parses a type annotation (paths with parameters, function types, anonymous structures,
	 * parentheses, and optionals).
	 *
	 * @return The parsed type.
	 */
	function parseType():CType {
		var t = token();
		switch (t) {
			case TId(v):
				push(t);
				var path = parsePath();
				var params = parseTypeArgs();
				return parseTypeNext(CTPath(path, params));
			case TPOpen:
				var a = token();
				var b = token();

				push(b);
				push(a);

				/**
				 * Parses the return type of a function type after its arguments.
				 *
				 * @param args The argument types already parsed.
				 * @return The complete function type.
				 */
				function withReturn(args) {
					switch token() {
						case TOp('->'):
						case t:
							unexpected(t);
					}

					return CTFun(args, parseType());
				}

				switch [a, b] {
					case [TPClose, _] | [TId(_), TDoubleDot]:
						var args = [
							for (arg in parseFunctionArgs()) {
								switch arg.value {
									case null:
									case v:
										error(ECustom('Default values not allowed in function types'), v.pos.pmin, v.pos.pmax);
								}

								CTNamed(arg.name, if (arg.opt) CTOpt(arg.t) else arg.t);
							}
						];

						return withReturn(args);
					default:
						var t = parseType();
						return switch token() {
							case TComma:
								var args = [t];

								while (true) {
									args.push(parseType());
									if (!maybe(TComma))
										break;
								}
								ensure(TPClose);
								withReturn(args);
							case TPClose:
								parseTypeNext(CTParent(t));
							case t: unexpected(t);
						}
				}
			case TBrOpen:
				var fields = [];
				var meta = null;
				while (true) {
					t = token();
					switch (t) {
						case TBrClose: break;
						case TQuestion:
							if (meta == null)
								meta = [];
							meta.push({name: ":optional", params: []});
						case TId("var"), TId("final"):
							var name = getIdent();
							ensure(TDoubleDot);
							if (t.match(TId("final"))) {
								if (meta == null)
									meta = [];
								meta.push({name: ":final", params: []});
							}
							fields.push({name: name, t: parseType(), meta: meta});
							meta = null;
							ensure(TSemicolon);
						case TId(name):
							ensure(TDoubleDot);
							fields.push({name: name, t: parseType(), meta: meta});
							t = token();
							switch (t) {
								case TComma:
								case TBrClose: break;
								default: unexpected(t);
							}
						case TMeta(name):
							if (meta == null)
								meta = [];
							meta.push({name: name, params: parseMetaArgs()});
						default:
							unexpected(t);
							break;
					}
				}
				return parseTypeNext(CTAnon(fields));
			default:
				return unexpected(t);
		}
	}

	/**
	 * Resolves `new Map<K, V>()` to the concrete map class its key type selects.
	 *
	 * @param path The constructed type path.
	 * @param targs Its written type arguments, or null when it had none.
	 * @return The class to construct.
	 */
	function mapClassFor(path:String, targs:Array<CType>):String {
		if (targs == null || targs.length == 0 || (path != "Map" && path != "haxe.ds.Map"))
			return path;

		return switch (targs[0]) {
			case CTPath(["String"], _): "haxe.ds.StringMap";
			case CTPath(["Int"], _): "haxe.ds.IntMap";
			default: path;
		}
	}

	/**
	 * Parses the `<...>` argument list that may follow a type path, or returns null when the next
	 * token does not open one.
	 *
	 * The closing `>` of a nested list arrives glued to its parent's as a single `>>` operator token,
	 * so the tail is pushed back for the enclosing list to consume.
	 *
	 * @return The type arguments, or null when there were none.
	 */
	function parseTypeArgs():Array<CType> {
		var t = token();

		switch (t) {
			case TOp(op) if (op == "<"):
			default:
				push(t);
				return null;
		}

		var params:Array<CType> = [];
		while (true) {
			switch (token(false)) {
				case TConst(c):
					params.push(CTExpr(mk(EConst(c))));
				case tk:
					push(tk);
					params.push(parseType());
			}
			t = token();
			switch (t) {
				case TComma:
					continue;
				case TOp(op):
					if (op == ">")
						break;
					if (op.charCodeAt(0) == ">".code) {
						tokens.unshift({t: TOp(op.substr(1)), min: tokenMax - op.length - 1, max: tokenMax});
						break;
					}
				default:
			}
			unexpected(t);
			break;
		}

		return params;
	}

	/**
	 * Parses whatever can follow a type, notably the `->` that turns it into a function type.
	 *
	 * @param t The type parsed so far.
	 * @return The (possibly extended) type.
	 */
	function parseTypeNext(t:CType) {
		var tk = token();
		switch (tk) {
			case TOp(op):
				if (op != "->") {
					push(tk);
					return t;
				}
			default:
				push(tk);
				return t;
		}
		var t2 = parseType();
		switch (t2) {
			case CTFun(args, _):
				args.unshift(t);
				return t2;
			default:
				return CTFun([t], t2);
		}
	}

	/**
	 * Parses a comma-separated list of expressions terminated by a given closing token.
	 *
	 * @param etk The token that closes the list.
	 * @return The parsed expressions.
	 */
	function parseExprList(etk) {
		var args = new Array();
		var tk = token();
		if (tk == etk)
			return args;
		push(tk);
		while (true) {
			args.push(parseExpr());
			tk = token();
			switch (tk) {
				case TComma:
				default:
					if (tk == etk)
						break;
					unexpected(tk);
					break;
			}
		}
		return args;
	}

	/**
	 * Parses a whole module (a sequence of top-level declarations).
	 *
	 * @param content The source text.
	 * @param origin The source origin for error positions.
	 * @param position The starting byte offset.
	 * @param pack The package to parse into.
	 * @param importModule Whether this is an `import.hx` prelude (restricted to imports/usings).
	 * @return The parsed declarations.
	 */
	public function parseModule(content:String, ?origin:String = "hscript", position:Int = 0, ?pack:Array<String>, importModule:Bool = false) {
		this.pack = pack;
		initParser(origin, position);
		input = content;
		readPos = 0;
		allowTypes = true;
		allowMetadata = true;

		var decls = [];
		while (true) {
			var tk = token();
			if (tk == TEof)
				break;
			push(tk);
			decls.push(parseModuleDecl(decls, importModule));
		}

		if (!importModule) {
			pack ??= [];
			var fullPack = pack.join('.');
			var thisPack = (switch (decls[0]?.d) {
				case DPackage(path): path;
				default: [];
			}).join('.');
			if (thisPack != fullPack) {
				throw new haxe.Exception('"package${thisPack.length > 0 ? ' ' : ''}$thisPack;" in $origin should be "package${fullPack.length > 0 ? ' ' : ''}$fullPack;"');
			}
		}

		return decls;
	}

	/**
	 * Parses a run of `@name`/`@:name(args)` metadata.
	 *
	 * @return The parsed metadata entries.
	 */
	function parseMetadata():Metadata {
		var meta = [];
		while (true) {
			var tk = token();
			switch (tk) {
				case TMeta(name):
					meta.push({name: name, params: parseMetaArgs()});
				default:
					push(tk);
					break;
			}
		}
		return meta;
	}

	/**
	 * Parses a `<...>` type-parameter list, keeping only the parameter names (constraints are erased).
	 *
	 * @return The type-parameter names.
	 */
	function parseParams():Array<String> {
		var params:Array<String> = [];
		if (!maybe(TOp("<")))
			return params;

		while (true) {
			var name = getIdent();
			if (!name.isTypeIdentifier())
				error(ECustom('Type parameter name should start with an uppercase letter'), tokenMin, tokenMax);
			params.push(name);

			if (maybe(TDoubleDot)) {
				if (maybe(TPOpen)) {
					while (true) {
						parseType();
						if (!maybe(TComma))
							break;
					}
					ensure(TPClose);
				} else {
					parseType();
				}
			}

			var t = token();
			switch (t) {
				case TComma:
					continue;
				case TOp(op):
					if (op == ">")
						break;
					if (op.charCodeAt(0) == ">".code) {
						tokens.unshift({t: TOp(op.substr(1)), min: tokenMax - op.length - 1, max: tokenMax});
						break;
					}
				default:
			}
			unexpected(t);
			break;
		}

		return params;
	}

	/**
	 * Parses an `abstract` (or `enum abstract`) declaration, desugaring it into a class of static
	 * constants tagged with the appropriate metadata.
	 *
	 * @param name The abstract's name.
	 * @param meta Metadata already parsed for it.
	 * @param params Its type-parameter names.
	 * @param isEnum Whether it is an `enum abstract`.
	 * @param isPrivate Whether it is `private`.
	 * @return The resulting declaration.
	 */
	function parseAbstractDecl(name:String, meta:Metadata, params:Array<String>, isEnum:Bool, isPrivate:Bool):ModuleDecl {
		var underlying:Null<CType> = null;
		if (maybe(TPOpen)) {
			underlying = parseType();
			ensure(TPClose);
		}

		var from:Array<CType> = [];
		var to:Array<CType> = [];
		while (true) {
			var t = token();
			switch (t) {
				case TId("from"):
					from.push(parseType());
				case TId("to"):
					to.push(parseType());
				default:
					push(t);
					break;
			}
		}

		var fields = [];
		ensure(TBrOpen);
		while (!maybe(TBrClose)) {
			var f = parseField(true);
			if (isEnum && !f.access.contains(AStatic))
				f.access.push(AStatic);
			fields.push(f);
		}

		if (isEnum) {
			return mkd(DClass({
				name: name,
				meta: meta.concat([{name: ':enumAbstract', params: []}]),
				params: params,
				extend: null,
				implement: [],
				fields: fields,
				isPrivate: isPrivate,
				isExtern: false,
			}), tokenMin, tokenMax);
		}

		return mkd(DAbstract({
			name: name,
			meta: meta,
			params: params,
			extend: null,
			implement: [],
			fields: fields,
			isPrivate: isPrivate,
			isExtern: false,
			underlying: underlying,
			from: from,
			to: to,
		}), tokenMin, tokenMax);
	}

	/**
	 * Looks one token ahead without consuming it.
	 *
	 * @param id The identifier to test for.
	 * @return True if the next token is that identifier.
	 */
	function peekIdent(id:String):Bool {
		var t = token();
		push(t);
		return t.match(TId(_ == id => true));
	}

	/**
	 * Parses one top-level declaration: `package`, `import`, `using`, `class`, `interface`, `enum`,
	 * `typedef`, `abstract`, or a module-level field.
	 *
	 * @param decls The declarations parsed so far (some forms append to this directly).
	 * @param importModule Whether only imports/usings are allowed (an `import.hx` prelude).
	 * @return The parsed declaration.
	 */
	function parseModuleDecl(?decls:Array<ModuleDecl>, importModule:Bool = false):ModuleDecl {
		var meta = parseMetadata();
		var ident = getIdent();
		var isPrivate = false, isExtern = false, isFinal = false, isAbstract = false;
		while (true) {
			switch (ident) {
				case "private":
					isPrivate = true;
				case "extern":
					isExtern = true;
				case "final" | "abstract":
					var peek = token();
					push(peek);
					if (!peek.match(TId("class")))
						break;

					if (ident == "final")
						isFinal = true;
					else
						isAbstract = true;
				default:
					break;
			}
			ident = getIdent();
		}
		if (ident != 'package' && ident != 'import' && ident != 'using')
			decl = true;

		return switch (ident) {
			case "using":
				if (decl)
					error(ECustom('import and using may not appear after a declaration'), tokenMin, tokenMax);

				var path:Array<String> = [getIdent()];

				while (true) {
					var t = token();
					if (t != TDot) {
						push(t);
						break;
					}

					t = token();
					switch (t) {
						case TId(id):
							path.push(id);
						default:
							unexpected(t);
					}
				}

				ensure(TSemicolon);

				return mkd(DUsing(path), tokenMin, tokenMax);
			case "package":
				if (decls != null && decls.length > 0)
					error(EUnexpected(ident), tokenMin, tokenMax);

				var noPath = maybe(TSemicolon);
				var path = (noPath ? [] : parsePath());
				if (!noPath)
					ensure(TSemicolon);

				return mkd(DPackage(path), tokenMin, tokenMax);
			case "import":
				if (decl)
					error(ECustom('import and using may not appear after a declaration'), tokenMin, tokenMax);

				var path:Array<String> = [getIdent()];
				var mode:ImportMode = INormal;
				var tid:String = null;

				if (path[0].isTypeIdentifier())
					tid = path[0];

				while (true) {
					var t = token();
					if (t != TDot) {
						push(t);
						break;
					}

					t = token();
					switch (t) {
						case TId(id):
							if (mode == IAll)
								unexpected(t);

							if (tid != null || id.isTypeIdentifier())
								tid = id;

							path.push(id);
						case TOp("*"):
							if (tid != null)
								unexpected(t);

							mode = IAll;
						default:
							unexpected(t);
					}
				}

				if (mode != IAll && (maybe(TId('as')) || maybe(TId('in')))) {
					if (tid == null)
						error(ECustom('Module name must start with an uppercase letter'), tokenMin, tokenMax);

					var t = token();
					switch (t) {
						case TId(id):
							if (!id.isTypeIdentifier() && tid.isTypeIdentifier())
								error(ECustom('Type aliases must start with an uppercase letter'), tokenMin, tokenMax);

							mode = IAsName(id);
						default:
							unexpected(t);
					}
				}

				ensure(TSemicolon);

				return mkd(DImport(path, mode), tokenMin, tokenMax);
			case "class":
				if (importModule)
					error(EImportHx, tokenMin, tokenMax);

				var name = getIdent();
				if (!name.isTypeIdentifier())
					error(ECustom('Type name should start with an uppercase letter'), tokenMin, tokenMax);

				var params = parseParams();
				var extend = null;
				var implement = [];

				while (true) {
					var t = token();
					switch (t) {
						case TId("extends"):
							extend = parseType();
						case TId("implements"):
							implement.push(parseType());
						default:
							push(t);
							break;
					}
				}

				var fields = [];
				ensure(TBrOpen);
				while (!maybe(TBrClose))
					fields.push(parseField());

				return mkd(DClass({
					name: name,
					meta: meta,
					params: params,
					extend: extend,
					implement: implement,
					fields: fields,
					isPrivate: isPrivate,
					isExtern: isExtern,
					isFinal: isFinal,
					isAbstract: isAbstract,
				}), tokenMin, tokenMax);
			case "interface":
				if (importModule)
					error(EImportHx, tokenMin, tokenMax);

				var name = getIdent();
				if (!name.isTypeIdentifier())
					error(ECustom('Type name should start with an uppercase letter'), tokenMin, tokenMax);

				var params = parseParams();
				var implement = [];

				while (true) {
					var t = token();
					switch (t) {
						case TId("extends"), TId("implements"):
							implement.push(parseType());
						default:
							push(t);
							break;
					}
				}

				var fields = [];
				ensure(TBrOpen);
				while (!maybe(TBrClose))
					fields.push(parseField(true));

				return mkd(DInterface({
					name: name,
					meta: meta,
					params: params,
					extend: null,
					implement: implement,
					fields: fields,
					isPrivate: isPrivate,
					isExtern: isExtern,
				}), tokenMin, tokenMax);
			case "enum":
				if (importModule)
					error(EImportHx, tokenMin, tokenMax);

				var enumPeek = token();
				if (enumPeek.match(TId("abstract"))) {
					var aName = getIdent();
					if (!aName.isTypeIdentifier())
						error(ECustom('Type name should start with an uppercase letter'), tokenMin, tokenMax);
					return parseAbstractDecl(aName, meta, parseParams(), true, isPrivate);
				}
				push(enumPeek);

				var name = getIdent();
				if (!name.isTypeIdentifier())
					error(ECustom('Type name should start with an uppercase letter'), tokenMin, tokenMax);

				var params = parseParams();
				var names:Array<String> = [];
				var constructs:Map<String, EnumFieldDecl> = [];

				ensure(TBrOpen);
				while (!maybe(TBrClose)) {
					var field:EnumFieldDecl = parseEnumField();
					constructs.set(field.name, field);

					names.push(field.name);
				}

				return mkd(DEnum({
					name: name,
					meta: meta,
					params: params,
					isPrivate: isPrivate,
					constructs: constructs,
					names: names
				}), tokenMin, tokenMax);
			case "abstract":
				if (importModule)
					error(EImportHx, tokenMin, tokenMax);

				var name = getIdent();
				if (!name.isTypeIdentifier())
					error(ECustom('Type name should start with an uppercase letter'), tokenMin, tokenMax);

				var params = parseParams();
				var isEnumAbstract = false;
				for (m in meta)
					if (m.name == ':enum')
						isEnumAbstract = true;
				return parseAbstractDecl(name, meta, params, isEnumAbstract, isPrivate);
			case "typedef":
				if (importModule)
					error(EImportHx, tokenMin, tokenMax);

				var name = getIdent();
				if (!name.isTypeIdentifier())
					error(ECustom('Type name should start with an uppercase letter'), tokenMin, tokenMax);

				var params = parseParams();

				ensureToken(TOp("="));

				var t = parseType();
				switch (t) {
					case CTPath(_, _):
						ensure(TSemicolon);

					default:
						maybe(TSemicolon);
				}

				return mkd(DTypedef({
					name: name,
					meta: meta,
					params: params,
					isPrivate: isPrivate,
					t: t,
				}), tokenMin, tokenMax);
			case "var", "final", "function":
				push(TId(ident));

				var f = parseField();

				return mkd(DField({
					name: f.name,
					meta: f.meta,
					kind: f.kind,
					params: null,
					isPrivate: isPrivate,
				}), tokenMin, tokenMax);
			default:
				unexpected(TId(ident));
		}
		return null;
	}

	/**
	 * Parses one enum constructor, with its optional argument list.
	 *
	 * @return The parsed constructor.
	 */
	function parseEnumField():EnumFieldDecl {
		var arguments:Array<Argument> = null;
		var meta = parseMetadata();
		var id = getIdent();

		if (maybe(TPOpen))
			arguments = parseFunctionArgs(false);

		ensure(TSemicolon);

		return {
			name: id,
			meta: meta,
			arguments: arguments
		};
	}

	/**
	 * Parses one class/interface field: its metadata, access modifiers, and either a variable/property
	 * or a function.
	 *
	 * @param allowNoBody Whether a bodyless member (interface/extern) is permitted.
	 * @return The parsed field.
	 */
	function parseField(allowNoBody:Bool = false):FieldDecl {
		var meta = parseMetadata();
		var access = [];
		while (true) {
			var id = getIdent();
			switch (id) {
				case "override":
					access.push(AOverride);
				case "dynamic":
					access.push(ADynamic);
				case "public":
					access.push(APublic);
				case "private":
					access.push(APrivate);
				case "inline":
					access.push(AInline);
				case "static":
					access.push(AStatic);
				case "macro":
					access.push(AMacro);
				case "extern":
					access.push(AExtern);
				case "abstract":
					var peek = token();
					push(peek);
					if (!peek.match(TId("function")))
						unexpected(TId("abstract"));
					access.push(AAbstract);
				case "overload":
				case "function":
					var name = getIdent();
					var inf = parseFunctionDecl(allowNoBody || access.contains(AAbstract) || access.contains(AExtern));
					maybe(TSemicolon);
					return {
						name: name,
						meta: meta,
						access: access,
						kind: KFunction({
							args: inf.args,
							expr: inf.body,
							ret: inf.ret,
						}),
					};
				case "var", "final":
					if (id == 'final') {
						var peek = token();
						push(peek);
						if (peek.match(TId("function"))) {
							getIdent();
							var fname = getIdent();
							var finf = parseFunctionDecl(allowNoBody);
							maybe(TSemicolon);
							return {
								name: fname,
								meta: meta,
								access: access,
								kind: KFunction({args: finf.args, expr: finf.body, ret: finf.ret}),
							};
						}
					}
					var name = getIdent();
					var get = null, set = null;
					if (id != 'final' && maybe(TPOpen)) {
						get = getIdent();
						ensure(TComma);
						set = getIdent();
						ensure(TPClose);
					}
					var type = maybe(TDoubleDot) ? parseType() : null;
					var expr = maybe(TOp("=")) ? parseExpr() : null;

					if (expr != null) {
						if (isBlock(expr))
							maybe(TSemicolon);
						else
							ensure(TSemicolon);
					} else if (type != null && type.match(CTAnon(_))) {
						maybe(TSemicolon);
					} else
						ensure(TSemicolon);

					return {
						name: name,
						meta: meta,
						access: access,
						kind: KVar({
							get: get,
							set: set,
							type: type,
							expr: expr,
							isFinal: (id == 'final')
						}),
					};
				default:
					unexpected(TId(id));
					break;
			}
		}
		return null;
	}

	/** Creates a parser with the default grammar flags. */
	public function new() {
		super();
	}

	/**
	 * Resets scanner and grammar state for a fresh parse.
	 *
	 * @param origin The source origin, used for error positions.
	 * @param pos The starting byte offset.
	 */
	function initParser(origin, pos) {
		initLexer(origin, pos);
		decl = false;
		fid = uid = 0;
	}

	/**
	 * Parses the condition of a `#if` / `#elseif` as a full expression, so comparisons against
	 * compilation defines work rather than only bare flags.
	 *
	 * @return The condition expression.
	 */
	override function preproExpr():Expr {
		return parseExpr();
	}
}
