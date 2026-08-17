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
import hxscript.error.ParserException;

/** Turns parsed AST back into source text, and renders parser/interpreter errors. */
class Printer {
	/** Accumulates the printed output. */
	var buf:StringBuf;

	/** Current indentation string (one tab per level). */
	var tabs:String;

	/** Current block nesting depth. */
	var level:Int;

	/** Creates a printer. Output state is reset per call, so one instance can be reused. */
	public function new() {}

	/**
	 * Prints an expression tree as source.
	 *
	 * @param e The expression to print.
	 * @return The source text.
	 */
	public function exprToString(e:Expr) {
		buf = new StringBuf();
		tabs = "";
		level = 0;
		expr(e);
		return buf.toString();
	}

	/**
	 * Prints a type as source.
	 *
	 * @param t The type to print.
	 * @return The source text.
	 */
	public function typeToString(t:CType) {
		buf = new StringBuf();
		tabs = "";
		level = 0;
		type(t);
		return buf.toString();
	}

	/** Appends a value to the output buffer. */
	inline function add<T>(s:T)
		buf.add(s);

	/**
	 * Prints a type into the buffer.
	 *
	 * @param t The type to print.
	 */
	function type(t:CType) {
		switch (t) {
			case CTOpt(t):
				add('?');
				type(t);
			case CTPath(path, params):
				add(path.join("."));
				if (params != null) {
					add("<");
					var first = true;
					for (p in params) {
						if (first)
							first = false
						else
							add(", ");
						type(p);
					}
					add(">");
				}
			case CTNamed(name, t):
				add(name);
				add(':');
				type(t);
			case CTFun(args, ret) if (Lambda.exists(args, function(a) return a.match(CTNamed(_, _)))):
				add('(');
				for (a in args)
					switch a {
						case CTNamed(_, _): type(a);
						default: type(CTNamed('_', a));
					}
				add(')->');
				type(ret);
			case CTFun(args, ret):
				if (args.length == 0)
					add("Void -> ");
				else {
					for (a in args) {
						type(a);
						add(" -> ");
					}
				}
				type(ret);
			case CTAnon(fields):
				add("{");
				var first = true;
				for (f in fields) {
					if (first) {
						first = false;
						add(" ");
					} else
						add(", ");
					add(f.name + " : ");
					type(f.t);
				}
				add(first ? "}" : " }");
			case CTParent(t):
				add("(");
				type(t);
				add(")");
			case CTExpr(e):
				expr(e);
		}
	}

	/**
	 * Prints a module-level declaration as source.
	 *
	 * The bar for this is ROUND-TRIP, not readability: printing a parsed module, reparsing the
	 * output and printing it again has to produce the same text, so anything dropped here shows up
	 * as a difference rather than as silently missing source.
	 *
	 * @param d The declaration to print.
	 */
	function decl(d:ModuleDecl) {
		switch (d.d) {
			case DPackage(path):
				add('package');
				if (path != null && path.length > 0)
					add(' ' + path.join('.'));
				add(';');
			case DImport(path, mode):
				add('import ' + path.join('.'));
				switch (mode) {
					case INormal:
					case IAsName(alias): add(' as ' + alias);
					case IAll: add('.*');
				}
				add(';');
			case DUsing(path):
				add('using ' + path.join('.') + ';');
			case DField(f):
				meta(f.meta);
				if (f.isPrivate)
					add('private ');
				fieldBody(f.name, f.kind);
			case DClass(c):
				typeHead(c.meta, c.isPrivate, c.isExtern ? 'extern class' : 'class', c.name, c.params);
				if (c.extend != null) {
					add(' extends ');
					type(c.extend);
				}
				for (i in c.implement) {
					add(' implements ');
					type(i);
				}
				fieldBlock(c.fields);
			case DInterface(c):
				typeHead(c.meta, c.isPrivate, 'interface', c.name, c.params);
				if (c.extend != null) {
					add(' extends ');
					type(c.extend);
				}
				for (i in c.implement) {
					add(' extends ');
					type(i);
				}
				fieldBlock(c.fields);
			case DEnum(e):
				typeHead(e.meta, e.isPrivate, 'enum', e.name, e.params);
				add(' {');
				level++;
				tabs += '	';
				for (n in e.names) {
					var c:EnumFieldDecl = e.constructs.get(n);
					if (c == null)
						continue;
					add('\n' + tabs);
					meta(c.meta);
					add(c.name);
					if (c.arguments != null && c.arguments.length > 0)
						args(c.arguments);
					add(';');
				}
				level--;
				tabs = tabs.substr(1);
				add('\n' + tabs + '}');
			case DTypedef(t):
				typeHead(t.meta, t.isPrivate, 'typedef', t.name, t.params);
				add(' = ');
				type(t.t);
				add(';');
			case DAbstract(a):
				typeHead(a.meta, a.isPrivate, 'abstract', a.name, a.params);
				if (a.underlying != null) {
					add('(');
					type(a.underlying);
					add(')');
				}
				for (f in a.from) {
					add(' from ');
					type(f);
				}
				for (t in a.to) {
					add(' to ');
					type(t);
				}
				fieldBlock(a.fields);
		}
	}

	/** Prints `meta name<params>` for a type declaration. */
	function typeHead(m:Metadata, isPrivate:Bool, keyword:String, name:String, params:Array<String>) {
		meta(m);
		if (isPrivate)
			add('private ');
		add(keyword + ' ' + name);
		if (params != null && params.length > 0)
			add('<' + params.join(', ') + '>');
	}

	/** Prints a metadata list, each entry trailed by a space. */
	function meta(m:Metadata) {
		if (m == null)
			return;
		for (entry in m) {
			add('@' + entry.name);
			if (entry.params != null && entry.params.length > 0) {
				add('(');
				for (i => p in entry.params) {
					if (i > 0)
						add(', ');
					expr(p);
				}
				add(')');
			}
			add(' ');
		}
	}

	/** Prints a parenthesised argument list. */
	function args(list:Array<Argument>) {
		add('(');
		for (i => a in list) {
			if (i > 0)
				add(', ');
			if (a.rest)
				add('...');
			if (a.opt && a.value == null)
				add('?');
			add(a.name);
			addType(a.t);
			if (a.value != null) {
				add(' = ');
				expr(a.value);
			}
		}
		add(')');
	}

	/** Prints a field's `function`/`var` body, shared by class fields and module-level fields. */
	function fieldBody(name:String, kind:FieldKind) {
		switch (kind) {
			case KFunction(f):
				add('function ' + name);
				args(f.args);
				addType(f.ret);
				if (f.expr != null) {
					add(' ');
					expr(f.expr);
				} else
					add(';');

			case KVar(v):
				add((v.isFinal == true ? 'final ' : 'var ') + name);
				if (v.get != null || v.set != null)
					add('(' + (v.get ?? 'default') + ', ' + (v.set ?? 'default') + ')');
				addType(v.type);
				if (v.expr != null) {
					add(' = ');
					expr(v.expr);
				}
				add(';');
		}
	}

	/** Prints a braced, indented field list. */
	function fieldBlock(fields:Array<FieldDecl>) {
		add(' {');
		level++;
		tabs += '	';
		for (f in fields) {
			add('\n' + tabs);
			meta(f.meta);
			for (a in f.access) {
				add(switch (a) {
					case APublic: 'public ';
					case APrivate: 'private ';
					case AInline: 'inline ';
					case ADynamic: 'dynamic ';
					case AOverride: 'override ';
					case AStatic: 'static ';
					case AMacro: 'macro ';
					case AExtern: 'extern ';
					case AAbstract: 'abstract ';
				});
			}
			fieldBody(f.name, f.kind);
		}
		level--;
		tabs = tabs.substr(1);
		add('\n' + tabs + '}');
	}

	/**
	 * Prints a ` : Type` suffix, or nothing when the type is null.
	 *
	 * @param t The optional type annotation.
	 */
	function addType(t:CType) {
		if (t != null) {
			add(" : ");
			type(t);
		}
	}

	/**
	 * Prints a constant literal (escaping strings and regex delimiters).
	 *
	 * @param c The constant to print.
	 */
	function addConst(c:Const) {
		switch (c) {
			case CInt(i):
				add(i);
			case CFloat(f):
				add(f);
			case CString(s):
				add('"');
				add(s.split("\\")
					.join("\\\\").split('"').join('\\"').split("\n").join("\\n").split("\r").join("\\r").split("\t").join("\\t"));
				add('"');
			case CReg(p, m):
				add('~/');
				add(p);
				add('/');
				add(m);
		}
	}

	/**
	 * Prints an expression into the buffer, recursing into sub-expressions.
	 *
	 * @param e The expression to print; a null expression prints a `??NULL??` marker.
	 */
	function expr(e:Expr) {
		if (e == null) {
			add("??NULL??");
			return;
		}
		switch (e.e) {
			case EDecl(d):
				decl(d);
			case EUsing(path):
				add('using ${path.join('.')}');
			case EImport(path, INormal):
				add('import ${path.join('.')}');
			case EImport(path, IAsName(alias)):
				add('import ${path.join('.')} as $alias');
			case EImport(path, IAll):
				add('import ${path.join('.')}.*');
			case EConst(c):
				addConst(c);
			case EIdent(v):
				add(v);
			case EVar(n, t, e, get, set, isFinal):
				add((isFinal ? 'final ' : 'var ') + n);
				if (get != null) {
					add('(');
					add(get);
					add(', ');
					add(set);
					add(')');
				}
				addType(t);
				if (e != null) {
					add(" = ");
					expr(e);
				}
			case EParent(e):
				add("(");
				expr(e);
				add(")");
			case EBlock(el):
				if (el.length == 0) {
					add("{}");
				} else {
					if (level++ > 0) {
						add("{\n");
						tabs += "\t";
					}

					for (e in el) {
						add(tabs);
						expr(e);
						add(";\n");
					}

					if (--level > 0) {
						tabs = tabs.substr(1);
						add(tabs);
						add("}");
					}
				}
			case EField(e, f, maybe):
				expr(e);
				add(maybe ? '?.$f' : '.$f');
			case EBinop(op, e1, e2):
				expr(e1);
				add(" " + op + " ");
				expr(e2);
			case EUnop(op, pre, e):
				if (pre) {
					add(op);
					expr(e);
				} else {
					expr(e);
					add(op);
				}
			case ECall(e, args):
				if (e == null)
					expr(e);
				else
					switch (e.e) {
						case EField(_), EIdent(_), EConst(_):
							expr(e);
						default:
							add("(");
							expr(e);
							add(")");
					}
				add("(");
				var first = true;
				for (a in args) {
					if (first)
						first = false
					else
						add(", ");
					expr(a);
				}
				add(")");
			case EIf(cond, e1, e2):
				add("if( ");
				expr(cond);
				add(" ) ");
				expr(e1);
				if (e2 != null) {
					add(" else ");
					expr(e2);
				}
			case EWhile(cond, e):
				add("while( ");
				expr(cond);
				add(" ) ");
				expr(e);
			case EDoWhile(cond, e):
				add("do ");
				expr(e);
				add(" while ( ");
				expr(cond);
				add(" )");
			case EFor(v, it, e):
				add("for( " + v + " in ");
				expr(it);
				add(" ) ");
				expr(e);
			case EForGen(it, e):
				add("for( ");
				expr(it);
				add(" ) ");
				expr(e);
			case EBreak:
				add("break");
			case EContinue:
				add("continue");
			case EFunction(params, e, name, ret):
				add("function");
				if (name != null)
					add(" " + name);
				add("(");
				var first = true;
				for (a in params) {
					if (first)
						first = false
					else
						add(", ");
					if (a.rest)
						add('...');
					if (a.opt && a.value == null)
						add("?");
					add(a.name);
					addType(a.t);
					if (a.value != null) {
						add(' = ');
						expr(a.value);
					}
				}
				add(")");
				addType(ret);
				add(" ");
				expr(e);
			case EReturn(e):
				add("return");
				if (e != null) {
					add(" ");
					expr(e);
				}
			case EArray(e, index):
				expr(e);
				add("[");
				expr(index);
				add("]");
			case EArrayDecl(el):
				add("[");
				var first = true;
				for (e in el) {
					if (first)
						first = false
					else
						add(", ");
					expr(e);
				}
				add("]");
			case ENew(cl, args):
				add("new " + cl + "(");
				var first = true;
				for (e in args) {
					if (first)
						first = false
					else
						add(", ");
					expr(e);
				}
				add(")");
			case EThrow(e):
				add("throw ");
				expr(e);
			case ETry(e, v, t, ecatch, extra):
				add("try ");
				expr(e);
				add(" catch( " + v);
				addType(t);
				add(") ");
				expr(ecatch);
				if (extra != null) {
					for (cc in extra) {
						add(" catch( " + cc.v);
						addType(cc.t);
						add(") ");
						expr(cc.expr);
					}
				}
			case EObject(fl):
				if (fl.length == 0) {
					add("{}");
				} else {
					tabs += "\t";
					add("{\n");
					for (f in fl) {
						add(tabs);
						add(f.name + " : ");
						expr(f.e);
						add(",\n");
					}
					tabs = tabs.substr(1);
					add(tabs);
					add("}");
				}
			case ETernary(c, e1, e2):
				expr(c);
				add(" ? ");
				expr(e1);
				add(" : ");
				expr(e2);
			case ESwitch(e, cases, def):
				add("switch ");
				expr(e);
				add(" {\n");

				level++;
				tabs += '\t';

				for (c in cases) {
					add(tabs);
					add("case ");
					var first = true;
					for (v in c.values) {
						if (first)
							first = false
						else
							add(", ");
						expr(v);
					}
					if (c.guard != null) {
						add(' if( ');
						expr(c.guard);
						add(' )');
					}
					add(": ");
					expr(c.expr);
					add(";\n");
				}

				if (def != null) {
					add(tabs);
					add("default: ");
					expr(def);
					add(";\n");
				}

				level--;
				tabs = tabs.substr(1);

				add(tabs);
				add("}");
			case EMeta(name, args, e):
				add("@");
				add(name);
				if (args != null && args.length > 0) {
					add("(");
					var first = true;
					for (a in args) {
						if (first)
							first = false
						else
							add(", ");
						expr(e);
					}
					add(")");
				}
				add(" ");
				expr(e);
			case ECheckType(e, t):
				add("(");
				expr(e);
				add(" : ");
				type(t);
				add(")");
			case ECast(e, t):
				if (t == null) {
					add("cast ");
					expr(e);
				} else {
					add("cast(");
					expr(e);
					add(", ");
					type(t);
					add(")");
				}
		}
	}

	/**
	 * Convenience: prints an expression as source with a fresh printer.
	 *
	 * @param e The expression to print.
	 * @return The source text.
	 */
	public static function toString(e:Expr) {
		return new Printer().exprToString(e);
	}
}
