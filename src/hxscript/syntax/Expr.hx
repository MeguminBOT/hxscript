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

/** A literal constant in the AST. */
enum Const {
	/** Integer literal. */
	CInt(v:Int);

	/** Floating-point literal. */
	CFloat(f:Float);

	/** String literal; `interp` marks a single-quoted string that allows `$` interpolation. */
	CString(s:String, ?interp:Bool);

	/** Regular-expression literal with its pattern and modifier flags. */
	CReg(pattern:String, modifiers:String);
}

/** A source position: the origin and line always present, byte/column offsets optional. */
@:structInit
class Position {
	/** The source origin (usually a file path or script name). */
	public var origin:String;

	/** The 1-based line number. */
	public var line:Int;

	/** The inclusive start byte offset. */
	public var pmin:Int = 0;

	/** The exclusive end byte offset. */
	public var pmax:Int = 0;

	/** The 1-based column. */
	public var column:Int = 0;
}

/** An expression: its definition plus source position. */
@:structInit
class Expr {
	/** The expression definition. */
	public var e:ExprDef;

	/** Where it appears in source. */
	public var pos:Position;
}

/** The shape of every expression the interpreter can evaluate. */
enum ExprDef {
	/** An inline type declaration (a nested class/enum/etc). */
	EDecl(t:ModuleDecl);

	/** A literal constant. */
	EConst(c:Const);

	/** An identifier reference. */
	EIdent(v:String);

	/** A variable/`final` binding with optional type, initializer, accessors, and finality. */
	EVar(n:String, ?t:CType, ?e:Expr, ?get:String, ?set:String, ?isFinal:Bool);

	/** A parenthesized expression. */
	EParent(e:Expr);

	/** A brace block of expressions. */
	EBlock(e:Array<Expr>);

	/** Field access `e.f`; `maybe` marks the null-safe `?.` form. */
	EField(e:Expr, f:String, ?maybe:Bool);

	/** A binary operation. */
	EBinop(op:String, e1:Expr, e2:Expr);

	/** A unary operation; `prefix` distinguishes `++x` from `x++`. */
	EUnop(op:String, prefix:Bool, e:Expr);

	/** A call of `e` with the given arguments. */
	ECall(e:Expr, params:Array<Expr>);

	/** An `if` with an optional `else`. */
	EIf(cond:Expr, e1:Expr, ?e2:Expr);

	/** A `while` loop. */
	EWhile(cond:Expr, e:Expr);

	/** A `for (v in it)` loop. */
	EFor(v:String, it:Expr, e:Expr);

	/** A `break`. */
	EBreak;

	/** A `continue`. */
	EContinue;

	/** A function literal or named function; `id` is a runtime slot assigned by the interpreter. */
	EFunction(args:Array<Argument>, e:Expr, ?name:String, ?ret:CType, ?id:Int);

	/** A `return` with an optional value. */
	EReturn(?e:Expr);

	/** Array access `e[index]`. */
	EArray(e:Expr, index:Expr);

	/** An array literal. */
	EArrayDecl(e:Array<Expr>);

	/** A `new cl(params)` construction. */
	ENew(cl:String, params:Array<Expr>);

	/** A `throw`. */
	EThrow(e:Expr);

	/** A `try`/`catch`; `extra` holds any additional typed catch clauses. */
	ETry(e:Expr, v:String, t:Null<CType>, ecatch:Expr, ?extra:Array<{v:String, t:Null<CType>, expr:Expr}>);

	/** An anonymous object literal. */
	EObject(fl:Array<{name:String, e:Expr}>);

	/** A ternary `cond ? e1 : e2`. */
	ETernary(cond:Expr, e1:Expr, e2:Expr);

	/** A `switch` with cases (each with optional guard) and an optional default. */
	ESwitch(e:Expr, cases:Array<{values:Array<Expr>, expr:Expr, ?guard:Expr}>, ?defaultExpr:Expr);

	/** A `do`/`while` loop. */
	EDoWhile(cond:Expr, e:Expr);

	/** A metadata annotation attached to an expression. */
	EMeta(name:String, args:Array<Expr>, e:Expr);

	/** A type check `(e : t)`. */
	ECheckType(e:Expr, t:CType);

	/** A general `for` whose iterator expression carries the loop variable(s). */
	EForGen(it:Expr, e:Expr);

	/** A `cast`, optionally to a type. */
	ECast(e:Expr, ?t:CType);

	/** An `import`. */
	EImport(path:Array<String>, mode:ImportMode);

	/** A `using`. */
	EUsing(path:Array<String>);
}

/** A function argument: name, optional type, optionality, default value, and rest (`...`) flag. */
typedef Argument = {name:String, ?t:CType, ?opt:Bool, ?value:Expr, ?rest:Bool};

/** A list of metadata entries. */
typedef Metadata = Array<MetadataEntry>;

/** One metadata entry: its name and argument expressions. */
typedef MetadataEntry = {name:String, params:Array<Expr>};

/** The shape of a type annotation. */
enum CType {
	/** A dotted type path with optional type parameters. */
	CTPath(path:Array<String>, ?params:Array<CType>);

	/** A function type `args -> ret`. */
	CTFun(args:Array<CType>, ret:CType);

	/** An anonymous structure type. */
	CTAnon(fields:Array<{name:String, t:CType, ?meta:Metadata}>);

	/** A parenthesized type. */
	CTParent(t:CType);

	/** An optional type `?T`. */
	CTOpt(t:CType);

	/** A named function argument type `name:T`. */
	CTNamed(n:String, t:CType);

	/** An expression used where a type is expected (type parameters only). */
	CTExpr(e:Expr);
}

/** A module-level declaration: its definition plus source position. */
typedef ModuleDecl = {
	/** The declaration definition. */
	var d:ModuleDeclDef;

	/** Where it appears in source. */
	var pos:Position;
}

/** The kinds of top-level declaration a module can contain. */
enum ModuleDeclDef {
	/** A `package` declaration. */
	DPackage(path:Array<String>);

	/** An `import`. */
	DImport(path:Array<String>, mode:ImportMode);

	/** A `using`. */
	DUsing(path:Array<String>);

	/** A module-level field. */
	DField(c:ModuleFieldDecl);

	/** A `class`. */
	DClass(c:ClassDecl);

	/** An `interface`. */
	DInterface(c:ClassDecl);

	/** An `enum`. */
	DEnum(c:EnumDecl);

	/** A `typedef`. */
	DTypedef(c:TypeDecl);

	/** An `abstract`. */
	DAbstract(a:AbstractDecl);
}

/** Fields common to every declared type. */
typedef ModuleType = {
	/** The type's short name. */
	var name:String;

	/** Type-parameter names; constraints are erased, only names are kept. */
	var params:Array<String>;

	/** Metadata attached to the type. */
	var meta:Metadata;

	/** Whether the type is `private` to its module. */
	var isPrivate:Bool;
}

/** A `class` or `interface` declaration. */
/** An `abstract` declaration: a class-like body plus the type it boxes and its implicit casts. */
typedef AbstractDecl = {
	> ClassDecl,

	/** The type the abstract boxes, if declared. */
	var underlying:Null<CType>;

	/** Types accepted implicitly (`from`). */
	var from:Array<CType>;

	/** Types converted to implicitly (`to`). */
	var to:Array<CType>;
}

typedef ClassDecl = {
	> ModuleType,

	/** The super-class, if any. */
	var extend:Null<CType>;

	/** The implemented interfaces. */
	var implement:Array<CType>;

	/** The declared fields. */
	var fields:Array<FieldDecl>;

	/** Whether the class is `extern`. */
	var isExtern:Bool;

	/** Whether the class is `final`, and so may not be extended. */
	var ?isFinal:Bool;

	/** Whether the class is `abstract`, and so may not be instantiated directly. */
	var ?isAbstract:Bool;
}

/** A `typedef` declaration and its target type. */
typedef TypeDecl = {
	> ModuleType,

	/** The aliased type. */
	var t:CType;
}

/** One field of a class/interface. */
typedef FieldDecl = {
	/** The field name. */
	var name:String;

	/** Metadata attached to the field. */
	var meta:Metadata;

	/** Whether the field is a method or a variable. */
	var kind:FieldKind;

	/** Access modifiers (`public`, `static`, `override`, etc). */
	var access:Array<FieldAccess>;
}

/** An `enum` declaration. */
typedef EnumDecl = {
	> ModuleType,

	/** Constructors keyed by name. */
	var constructs:Map<String, EnumFieldDecl>;

	/** Constructor names in declaration order. */
	var names:Array<String>;
}

/** One enum constructor: its name, metadata, and optional arguments. */
typedef EnumFieldDecl = {
	/** The constructor name. */
	var name:String;

	/** Metadata attached to the constructor. */
	var meta:Metadata;

	/** The constructor arguments, if it takes any. */
	var ?arguments:Array<Argument>;
}

/** A module-level (top-level) field declaration. */
typedef ModuleFieldDecl = {
	> ModuleType,

	/** Whether the field is a function or a variable. */
	var kind:FieldKind;
}

/** Field access and inheritance modifiers. */
enum FieldAccess {
	/** `public`. */
	APublic;

	/** `private`. */
	APrivate;

	/** `inline`. */
	AInline;

	/** `dynamic`. */
	ADynamic;

	/** `override`. */
	AOverride;

	/** `static`. */
	AStatic;

	/** `macro`. */
	AMacro;

	/** `extern`, on a member declared without a body. */
	AExtern;

	/** `abstract`, on a method an abstract class requires its subclasses to define. */
	AAbstract;
}

/** Whether a field is a method or a variable/property. */
enum FieldKind {
	/** A function field. */
	KFunction(f:FunctionDecl);

	/** A variable or property field. */
	KVar(v:VarDecl);
}

/** A function field's signature and body. */
typedef FunctionDecl = {
	/** The arguments. */
	var args:Array<Argument>;

	/** The body expression. */
	var expr:Expr;

	/** The return type, if annotated. */
	var ret:Null<CType>;

	/**
	 * The method's own type-parameter names, constraints erased as everywhere else.
	 *
	 * Parsed and thrown away until now, which made `function pick<T>(v:T):T` a function whose
	 * argument is annotated with a type nothing answers to. Enforcement then read that as a value of
	 * the wrong type and threw, so the one thing a type parameter has to do, accept anything, was the
	 * one thing it could not. Keeping the names is what lets the annotation be recognised as erased
	 * rather than unknown.
	 */
	var ?params:Array<String>;
}

/** A variable/property field's accessors, type, initializer, and finality. */
typedef VarDecl = {
	/** The getter accessor name (`get`, `null`, `default`, ...), if a property. */
	var get:Null<String>;

	/** The setter accessor name, if a property. */
	var set:Null<String>;

	/** The initializer expression, if any. */
	var expr:Null<Expr>;

	/** The declared type, if annotated. */
	var type:Null<CType>;

	/** Whether it is `final`. */
	var isFinal:Null<Bool>;
}

/** How an `import` brings names into scope. */
enum ImportMode {
	/** Import the type under its own name. */
	INormal;

	/** Import under an alias (`import X as Y`). */
	IAsName(alias:String);

	/** Wildcard import of a package (`import pack.*`). */
	IAll;
}
