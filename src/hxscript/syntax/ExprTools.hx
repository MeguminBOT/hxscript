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

/** Shallow walking and construction helpers for the script AST. */
class ExprTools {
	/**
	 * Applies `f` to each immediate sub-expression of `e` (a shallow, non-recursive walk).
	 *
	 * @param e The expression to visit.
	 * @param f The callback run on every direct child expression.
	 */
	public static function iter(e:Expr, f:Expr->Void) {
		switch (expr(e)) {
			case EConst(_), EIdent(_), EImport(_, _), EUsing(_), EDecl(_):
			case EVar(_, _, e):
				if (e != null)
					f(e);
			case EParent(e):
				f(e);
			case EBlock(el):
				for (e in el)
					f(e);
			case EField(e, _):
				f(e);
			case EBinop(_, e1, e2):
				f(e1);
				f(e2);
			case EUnop(_, _, e):
				f(e);
			case ECall(e, args):
				f(e);
				for (a in args)
					f(a);
			case EIf(c, e1, e2):
				f(c);
				f(e1);
				if (e2 != null)
					f(e2);
			case EWhile(c, e):
				f(c);
				f(e);
			case EDoWhile(c, e):
				f(c);
				f(e);
			case EFor(_, it, e):
				f(it);
				f(e);
			case EForGen(it, e):
				f(it);
				f(e);
			case EBreak, EContinue:
			case EFunction(_, e, _, _):
				f(e);
			case EReturn(e):
				if (e != null)
					f(e);
			case EArray(e, i):
				f(e);
				f(i);
			case EArrayDecl(el):
				for (e in el)
					f(e);
			case ENew(_, el):
				for (e in el)
					f(e);
			case EThrow(e):
				f(e);
			case ETry(e, _, _, c, extra):
				f(e);
				f(c);
				if (extra != null)
					for (cc in extra)
						f(cc.expr);
			case EObject(fl):
				for (fi in fl)
					f(fi.e);
			case ETernary(c, e1, e2):
				f(c);
				f(e1);
				f(e2);
			case ESwitch(e, cases, def):
				f(e);
				for (c in cases) {
					for (v in c.values)
						f(v);
					f(c.expr);
				}
				if (def != null)
					f(def);
			case EMeta(name, args, e):
				if (args != null)
					for (a in args)
						f(a);
				f(e);
			case ECheckType(e, _):
				f(e);
			case ECast(e, _):
				f(e);
		}
	}

	/**
	 * Rebuilds `e` with `f` applied to each immediate sub-expression, preserving structure and
	 * position (a shallow transform used to rewrite trees).
	 *
	 * @param e The expression to transform.
	 * @param f The mapping applied to every direct child expression.
	 * @return A new expression with the mapped children.
	 */
	public static function map(e:Expr, f:Expr->Expr) {
		var edef = switch (expr(e)) {
			case EConst(_), EIdent(_), EBreak, EContinue, EImport(_, _), EUsing(_), EDecl(_): expr(e);
			case EVar(n, t, e): EVar(n, t, if (e != null) f(e) else null);
			case EParent(e): EParent(f(e));
			case EBlock(el): EBlock([for (e in el) f(e)]);
			case EField(e, fi): EField(f(e), fi);
			case EBinop(op, e1, e2): EBinop(op, f(e1), f(e2));
			case EUnop(op, pre, e): EUnop(op, pre, f(e));
			case ECall(e, args): ECall(f(e), [for (a in args) f(a)]);
			case EIf(c, e1, e2): EIf(f(c), f(e1), if (e2 != null) f(e2) else null);
			case EWhile(c, e): EWhile(f(c), f(e));
			case EDoWhile(c, e): EDoWhile(f(c), f(e));
			case EFor(v, it, e): EFor(v, f(it), f(e));
			case EForGen(it, e): EForGen(f(it), f(e));
			case EFunction(args, e, name, t): EFunction(args, f(e), name, t);
			case EReturn(e): EReturn(if (e != null) f(e) else null);
			case EArray(e, i): EArray(f(e), f(i));
			case EArrayDecl(el): EArrayDecl([for (e in el) f(e)]);
			case ENew(cl, el): ENew(cl, [for (e in el) f(e)]);
			case EThrow(e): EThrow(f(e));
			case ETry(e, v, t, c,
				extra): ETry(f(e), v, t, f(c),
					extra == null ? null : [for (cc in extra) {v: cc.v, t: cc.t, expr: f(cc.expr)}]);
			case EObject(fl): EObject([for (fi in fl) {name: fi.name, e: f(fi.e)}]);
			case ETernary(c, e1, e2): ETernary(f(c), f(e1), f(e2));
			case ESwitch(e, cases,
				def): ESwitch(f(e), [for (c in cases) {values: [for (v in c.values) f(v)], expr: f(c.expr)}],
					def == null ? null : f(def));
			case EMeta(name, args, e): EMeta(name, args == null ? null : [for (a in args) f(a)], f(e));
			case ECheckType(e, t): ECheckType(f(e), t);
			case ECast(e, t): ECast(f(e), t);
		}
		return mk(edef, e.pos);
	}

	/**
	 * Unwraps an expression to its definition.
	 *
	 * @param e The positioned expression.
	 * @return Its inner `ExprDef`.
	 */
	public static inline function expr(e:Expr):ExprDef {
		return e.e;
	}

	/**
	 * Wraps an expression definition with a copy of a position.
	 *
	 * @param e The expression definition.
	 * @param pos The position to attach (copied).
	 * @return The positioned expression.
	 */
	public static inline function mk(e:ExprDef, pos:Position) {
		return {
			e: e,
			pos: {
				pmin: pos.pmin,
				pmax: pos.pmax,
				origin: pos.origin,
				line: pos.line,
				column: pos.column
			}
		};
	}

	/**
	 * Recognises a key-value iteration head (`k => v in iter`) and reports its parts.
	 *
	 * @param e The iterator expression.
	 * @param callb Receives the key name, value name (both null for a plain `in`), and the iterated expression.
	 * @return Whatever `callb` returns.
	 */
	public static inline function getKeyIterator<T>(e:Expr, callb:String->String->Expr->T) {
		var key = null, value = null, it = e;
		switch (expr(it)) {
			case EBinop("in", ekv, eiter):
				switch (expr(ekv)) {
					case EBinop("=>", v1, v2):
						switch ([expr(v1), expr(v2)]) {
							case [EIdent(v1), EIdent(v2)]:
								key = v1;
								value = v2;
								it = eiter;
							default:
						}
					default:
				}
			default:
		}
		return callb(key, value, it);
	}

	/**
	 * Whether an anonymous-structure field may be absent: either written `?x:Int`, which the parser
	 * desugars to `@:optional`, or annotated with a type that is itself optional.
	 *
	 * @param f The field descriptor.
	 * @return True if the field is optional.
	 */
	public static function isOptionalField(f:{name:String, t:CType, ?meta:Metadata}):Bool {
		if (f.t != null && f.t.match(CTOpt(_)))
			return true;
		if (f.meta != null)
			for (m in f.meta)
				if (m.name == ':optional')
					return true;
		return false;
	}
}
