/*
 * Copyright (c) 2026 MeguminBOT (hxScript)
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

package hxscript.compile;

#if hxscript_cppia
import haxe.ds.StringMap;
import hxscript.syntax.Expr;

/**
 * Rewrites captured-and-mutated locals so closures match Haxe semantics.
 */
class Capture {
	/** Names that were boxed, so a read of one is rewritten into a read of its box. */
	var boxed:StringMap<Bool>;

	/** The expression a boxed name is replaced by. */
	var replacement:Expr;

	/** Private: the entry point is the static below, which builds one of these per body. */
	function new() {
		boxed = new StringMap();
	}

	/**
	 * Boxes whatever needs boxing in a function body.
	 *
	 * @param args The function's arguments, which are locals too.
	 * @param body The body to rewrite.
	 * @return The rewritten body, and the argument names needing a cell on entry.
	 */
	public static function transform(args:Array<Argument>, body:Expr):{body:Expr, boxedArgs:Array<String>} {
		var self:Capture = new Capture();
		var prepared:Expr = self.desugar(body);

		var assigned:StringMap<Bool> = new StringMap();
		var captured:StringMap<Bool> = new StringMap();
		var locals:StringMap<Bool> = new StringMap();

		for (a in args)
			locals.set(a.name, true);

		self.collect(prepared, assigned, captured, locals, false);

		var any:Bool = false;
		for (name in locals.keys()) {
			if (assigned.exists(name) && captured.exists(name)) {
				self.boxed.set(name, true);
				any = true;
			}
		}

		if (!any)
			return {body: prepared, boxedArgs: []};

		var boxedArgs:Array<String> = [];
		for (a in args) {
			if (self.boxed.exists(a.name))
				boxedArgs.push(a.name);
		}

		return {body: self.rewrite(prepared), boxedArgs: boxedArgs};
	}

	/**
	 * Replaces every mention of a name with another expression.
	 *
	 * @param e The subtree to rewrite.
	 * @param name The name to replace.
	 * @param with What to put in its place.
	 * @return The rewritten subtree.
	 */
	public static function substitute(e:Expr, name:String, with:Expr):Expr {
		var self:Capture = new Capture();
		self.boxed.set(name, true);
		self.replacement = with;
		return self.replaceIdent(e);
	}

	/**
	 * Rewrites every read of a boxed local into a read of its box.
	 *
	 * @param e The expression to rewrite.
	 * @return The rewritten expression, or null when there was none.
	 */
	function replaceIdent(e:Expr):Expr {
		if (e == null)
			return null;

		switch (e.e) {
			case EIdent(v):
				return boxed.exists(v) ? replacement : e;
			case _:
				return mapChildren(e, replaceIdent);
		}
	}

	/**
	 * Gathers which names are written, which are seen from inside a nested function, and which are
	 * locals.
	 *
	 * @param e The subtree to scan.
	 * @param assigned Receives every name that is written.
	 * @param captured Receives every name mentioned inside a nested function.
	 * @param locals Receives every declared local.
	 * @param inFunction Whether this subtree sits inside a nested function.
	 */
	function collect(e:Expr, assigned:StringMap<Bool>, captured:StringMap<Bool>, locals:StringMap<Bool>, inFunction:Bool,
			shadow:StringMap<Bool> = null):Void {
		if (e == null)
			return;

		switch (e.e) {
			case EIdent(v):
				if (inFunction && !hidden(shadow, v))
					captured.set(v, true);

			case EVar(n, _, init, _, _, _):
				collect(init, assigned, captured, locals, inFunction, shadow);
				declare(n, locals, shadow);

			case EBinop(op, e1, e2):
				if (op == '='
					|| (op.length > 1 && op.charAt(op.length - 1) == '=' && op != '==' && op != '!=' && op != '>=' && op != '<=')) {
					switch (e1.e) {
						case EIdent(v):
							if (!hidden(shadow, v))
								assigned.set(v, true);
						case _:
					}
				}
				collect(e1, assigned, captured, locals, inFunction, shadow);
				collect(e2, assigned, captured, locals, inFunction, shadow);

			case EUnop(op, _, inner):
				if (op == '++' || op == '--') {
					switch (inner.e) {
						case EIdent(v):
							if (!hidden(shadow, v))
								assigned.set(v, true);
						case _:
					}
				}
				collect(inner, assigned, captured, locals, inFunction, shadow);

			case EFunction(fargs, fbody, fname, _, _):
				if (fname != null)
					declare(fname, locals, shadow);

				var inner:StringMap<Bool> = new StringMap();
				if (shadow != null)
					for (name in shadow.keys())
						inner.set(name, true);

				for (a in fargs)
					inner.set(a.name, true);

				collect(fbody, assigned, captured, locals, true, inner);

			case EFor(v, it, body):
				collect(it, assigned, captured, locals, inFunction, shadow);
				declare(v, locals, shadow);
				collect(body, assigned, captured, locals, inFunction, shadow);

			case ETry(body, v, _, ecatch, extra):
				collect(body, assigned, captured, locals, inFunction, shadow);
				declare(v, locals, shadow);
				collect(ecatch, assigned, captured, locals, inFunction, shadow);
				if (extra != null) {
					for (x in extra) {
						declare(x.v, locals, shadow);
						collect(x.expr, assigned, captured, locals, inFunction, shadow);
					}
				}

			case _:
				each(e, function(child:Expr):Void {
					collect(child, assigned, captured, locals, inFunction, shadow);
				});
		}
	}

	/**
	 * Records a declaration against whichever function actually declares it.
	 *
	 * A name declared inside a nested function belongs to that function. Recording it as a local of
	 * the enclosing one made it look assigned and captured at the same time, which is the test for
	 * boxing, so an unrelated local of the same name in a sibling closure was rewritten into a read
	 * of a cell that was never a cell.
	 *
	 * @param name The declared name.
	 * @param locals The enclosing function's locals.
	 * @param shadow The nested function's own names, or null at the enclosing level.
	 */
	static inline function declare(name:String, locals:StringMap<Bool>, shadow:StringMap<Bool>):Void {
		if (shadow != null)
			shadow.set(name, true);
		else
			locals.set(name, true);
	}

	/**
	 * @param shadow The names a nested function declares, or null.
	 * @param name The name being mentioned.
	 * @return Whether it refers to the nested function's own local rather than the enclosing one's.
	 */
	static inline function hidden(shadow:StringMap<Bool>, name:String):Bool {
		return shadow != null && shadow.exists(name);
	}

	/** Rewrites every mention of a boxed name into an access on its cell. */
	function rewrite(e:Expr):Expr {
		if (e == null)
			return null;

		switch (e.e) {
			case EIdent(v):
				if (!boxed.exists(v))
					return e;
				return {e: EArray(e, {e: EConst(CInt(0)), pos: e.pos}), pos: e.pos};

			case EVar(n, t, init, get, set, isFinal):
				var value:Expr = rewrite(init);
				if (!boxed.exists(n))
					return {e: EVar(n, t, value, get, set, isFinal), pos: e.pos};

				var cell:Expr = {e: EArrayDecl(value == null ? [] : [value]), pos: e.pos};
				return {e: EVar(n, null, cell, get, set, isFinal), pos: e.pos};

			case EFunction(fargs, fbody, fname, ret, id):
				var shadowed:Array<String> = [];

				for (a in fargs) {
					if (boxed.exists(a.name)) {
						boxed.remove(a.name);
						shadowed.push(a.name);
					}
				}

				for (name in declaredIn(fbody)) {
					if (boxed.exists(name)) {
						boxed.remove(name);
						shadowed.push(name);
					}
				}

				var out:Expr = {e: EFunction(fargs, rewrite(fbody), fname, ret, id), pos: e.pos};

				for (name in shadowed)
					boxed.set(name, true);

				return out;

			case _:
				return mapChildren(e, rewrite);
		}
	}

	/**
	 * The names a function body declares at its own level.
	 *
	 * Deeper functions are not descended into: each one shadows for itself when it is rewritten, so
	 * looking inside here would hide a name from code that can still see the outer one.
	 *
	 * @param e The function body.
	 * @return Every name it declares.
	 */
	function declaredIn(e:Expr):Array<String> {
		var found:Array<String> = [];

		function walk(node:Expr):Void {
			if (node == null)
				return;

			switch (node.e) {
				case EVar(n, _, init, _, _, _):
					found.push(n);
					walk(init);

				case EFor(v, it, body):
					found.push(v);
					walk(it);
					walk(body);

				case ETry(body, v, _, ecatch, extra):
					found.push(v);
					walk(body);
					walk(ecatch);
					if (extra != null) {
						for (x in extra) {
							found.push(x.v);
							walk(x.expr);
						}
					}

				case EFunction(_, _, fname, _, _):
					if (fname != null)
						found.push(fname);

				case _:
					each(node, walk);
			}
		}

		walk(e);
		return found;
	}

	/** Visits every child expression of a node. */
	function each(e:Expr, f:Expr->Void):Void {
		switch (e.e) {
			case EConst(_) | EIdent(_) | EBreak | EContinue | EImport(_, _) | EUsing(_) | EDecl(_):
			case EVar(_, _, init, _, _, _):
				f(init);
			case EParent(inner) | EThrow(inner) | ECast(inner, _) | ECheckType(inner, _) | EUnop(_, _, inner) | EField(inner, _, _):
				f(inner);
			case EReturn(inner):
				f(inner);
			case EMeta(_, margs, inner):
				for (a in margs)
					f(a);
				f(inner);
			case EBlock(list) | EArrayDecl(list):
				for (x in list)
					f(x);
			case EBinop(_, e1, e2):
				f(e1);
				f(e2);
			case ECall(callee, params):
				f(callee);
				for (p in params)
					f(p);
			case ENew(_, params):
				for (p in params)
					f(p);
			case EIf(c, e1, e2):
				f(c);
				f(e1);
				f(e2);
			case ETernary(c, e1, e2):
				f(c);
				f(e1);
				f(e2);
			case EWhile(c, body) | EDoWhile(c, body):
				f(c);
				f(body);
			case EFor(_, it, body):
				f(it);
				f(body);
			case EForGen(it, body):
				f(it);
				f(body);
			case EArray(arr, index):
				f(arr);
				f(index);
			case EObject(fields):
				for (fl in fields)
					f(fl.e);
			case EFunction(_, body, _, _, _):
				f(body);
			case ETry(body, _, _, ecatch, extra):
				f(body);
				f(ecatch);
				if (extra != null) {
					for (x in extra)
						f(x.expr);
				}
			case ESwitch(cond, cases, defaultExpr):
				f(cond);
				for (c in cases) {
					for (v in c.values)
						f(v);
					if (c.guard != null)
						f(c.guard);
					f(c.expr);
				}
				f(defaultExpr);
		}
	}

	/**
	 * Splits a named local function into a declaration and an assignment, so a self-recursive one
	 * becomes an assigned local that boxing can then give a cell to.
	 *
	 * @param e The subtree to rewrite.
	 * @return The rewritten subtree.
	 */
	function desugar(e:Expr):Expr {
		if (e == null)
			return null;

		switch (e.e) {
			case EBlock(list):
				var out:Array<Expr> = [];
				for (item in list) {
					switch (item.e) {
						case EFunction(fargs, fbody, fname, ret, id) if (fname != null):
							out.push({e: EVar(fname, null, null, null, null, false), pos: item.pos});
							var value:Expr = {e: EFunction(fargs, desugar(fbody), null, ret, id), pos: item.pos};
							out.push({e: EBinop('=', {e: EIdent(fname), pos: item.pos}, value), pos: item.pos});
						case _:
							out.push(desugar(item));
					}
				}
				return {e: EBlock(out), pos: e.pos};

			case _:
				return mapChildren(e, desugar);
		}
	}

	/** Rebuilds a node with every child mapped, preserving every field the node carries. */
	function mapChildren(e:Expr, rewrite:Expr->Expr):Expr {
		var d:ExprDef = switch (e.e) {
			case EConst(_) | EIdent(_) | EBreak | EContinue | EImport(_, _) | EUsing(_) | EDecl(_): e.e;
			case EParent(inner): EParent(rewrite(inner));
			case EThrow(inner): EThrow(rewrite(inner));
			case ECast(inner, t): ECast(rewrite(inner), t);
			case ECheckType(inner, t): ECheckType(rewrite(inner), t);
			case EUnop(op, pre, inner): EUnop(op, pre, rewrite(inner));
			case EField(inner, fi, maybe): EField(rewrite(inner), fi, maybe);
			case EReturn(inner): EReturn(rewrite(inner));
			case EMeta(n, margs, inner): EMeta(n, [for (a in margs) rewrite(a)], rewrite(inner));
			case EBlock(list): EBlock([for (x in list) rewrite(x)]);
			case EArrayDecl(list): EArrayDecl([for (x in list) rewrite(x)]);
			case EBinop(op, e1, e2): EBinop(op, rewrite(e1), rewrite(e2));
			case ECall(callee, params): ECall(rewrite(callee), [for (p in params) rewrite(p)]);
			case ENew(cl, params): ENew(cl, [for (p in params) rewrite(p)]);
			case EIf(c, e1, e2): EIf(rewrite(c), rewrite(e1), rewrite(e2));
			case ETernary(c, e1, e2): ETernary(rewrite(c), rewrite(e1), rewrite(e2));
			case EWhile(c, body): EWhile(rewrite(c), rewrite(body));
			case EDoWhile(c, body): EDoWhile(rewrite(c), rewrite(body));
			case EFor(v, it, body): EFor(v, rewrite(it), rewrite(body));
			case EForGen(it, body): EForGen(rewrite(it), rewrite(body));
			case EArray(arr, index): EArray(rewrite(arr), rewrite(index));
			case EObject(fields): EObject([for (fl in fields) {name: fl.name, e: rewrite(fl.e)}]);
			case EVar(n, t, init, get, set, isFinal): EVar(n, t, rewrite(init), get, set, isFinal);
			case EFunction(fargs, body, n, ret, id): EFunction(fargs, rewrite(body), n, ret, id);
			case ETry(body, v, t, ecatch, extra):
				ETry(rewrite(body), v, t, rewrite(ecatch), extra == null ? null : [for (x in extra) {v: x.v, t: x.t, expr: rewrite(x.expr)}]);
			case ESwitch(cond, cases, defaultExpr):
				ESwitch(rewrite(cond), [
					for (c in cases)
						{values: [for (v in c.values) rewrite(v)], expr: rewrite(c.expr), guard: c.guard == null ? null : rewrite(c.guard)}
				], rewrite(defaultExpr));
		}

		return {e: d, pos: e.pos};
	}
}
#end
