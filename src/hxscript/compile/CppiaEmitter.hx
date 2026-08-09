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
import haxe.io.Bytes;
import hxscript.syntax.Expr;

/**
 * Turns hxscript's syntax tree into a cppia module.
 *
 * cppia resolves names when the module links, so `emitIdent` must place each one as a local, a field
 * of the enclosing class, or a type; anything else throws `CppiaUnsupported` rather than being
 * guessed at. An unknown TYPE is not a refusal -- it is emitted as `Dynamic`, costing dispatch speed
 * for that expression alone.
 */
class CppiaEmitter {
	/** Names that resolve to a type without an import. Anything else must be imported or declared. */
	static var BUILTIN_TYPES:Array<String> = [
		'Array',
		'Bool',
		'Date',
		'DateTools',
		'Dynamic',
		'EReg',
		'Float',
		'Int',
		'IntIterator',
		'Lambda',
		'Math',
		'Reflect',
		'Std',
		'String',
		'StringBuf',
		'StringTools',
		'Sys',
		'Type',
		'Xml'
	];

	/** Binary operators that map straight through to a cppia token of the same spelling. */
	static var BINOPS:Array<String> = [
		'+', '-', '*', '/', '%', '&', '|', '^', '<<', '>>', '>>>', '==', '!=', '>=', '<=', '>', '<', '&&', '||'
	];

	/** Compound assignments, which cppia spells the same way but reads as a `SetExpr`. */
	static var ASSIGN_OPS:Array<String> = ['+=', '-=', '*=', '/=', '&=', '|=', '^=', '<<=', '>>=', '>>>='];

	/** The token stream being built. */
	var w:CppiaWriter;

	/** How many classes have been written, which the module header has to declare up front. */
	var classCount:Int;

	/** Next free local slot. Slots are numbered across the whole module, not per function. */
	var nextVarId:Int;

	/** Local slots by name, innermost scope last. */
	var scopes:Array<StringMap<Int>>;

	/** The declared type of each local, in step with `scopes`. */
	var scopeTypes:Array<StringMap<String>>;

	/** Full path for each short type name in view, from imports, declarations and ambient types. */
	var typePaths:StringMap<String>;

	/** Paths this batch declares, which can be linked directly rather than resolved as host types. */
	var moduleClasses:StringMap<Bool>;

	/**
	 * Plain instance variables of every class in the batch, by class path then field name, holding
	 * each field's declared type or the empty string when it had none.
	 *
	 * Only fields that are plain variables are here. A field with a `get` or `set` accessor is left
	 * out on purpose: reaching it directly would read the storage behind the property and skip the
	 * accessor that gives it its meaning.
	 */
	var classVars:StringMap<StringMap<String>>;

	/** Fully-qualified `Class.method` to echo readably while emitting, or null. */
	public var echoTarget:Null<String> = null;

	/** What that method emitted, once it has been emitted. */
	public var echoed:Null<String> = null;

	/** Whether the writer is recording, which only the method named by `echoTarget` turns on. */
	var echoing:Bool = false;

	/**
	 * The array type the next literal should be built as, or null for an untyped one.
	 *
	 * An array literal has nothing in it to say what it holds, so it was always built as the loose
	 * kind. That is fine until something reads it back through an annotation promising a specific
	 * kind, because the read trusts the annotation and reinterprets the memory -- which crashes rather
	 * than misbehaves. Carrying the target's type to the literal keeps the two descriptions of the
	 * same array in agreement.
	 */
	var expectedArray:Null<String> = null;

	/**
	 * The declared element type of the array literal being emitted, when one was written.
	 *
	 * `expectedArray` alone cannot carry this: every array of a non-primitive spells as
	 * `Array.Object`, so a nested literal has no way to recover what its own elements are.
	 */
	var expectedElem:Null<CType> = null;

	/**
	 * Paths in this batch that were declared as abstracts rather than classes.
	 *
	 * An abstract has no runtime form, so a value of one is its underlying value and a method on it
	 * is a static taking that value as a leading `this`. Knowing which paths those are is what lets
	 * a call be routed there, and what each one boxes is what lets a slot holding one be typed as
	 * the thing it really holds.
	 */
	var moduleAbstracts:StringMap<String> = new StringMap();

	/** Locals declared as an array of one of this batch's abstracts, by name, to that abstract. */
	var arrayElements:StringMap<String> = new StringMap();

	/** Abstracts in this batch that declare a constructor, which `new` has to be routed to. */
	var abstractCtors:StringMap<Bool> = new StringMap();

	/**
	 * Declared return types of a batch type's methods, by owner then method name.
	 *
	 * What a call evaluates to is otherwise unknown, and it has to be known for `m.plus(1).big()`:
	 * without it the second call has no idea it is still holding an abstract.
	 */
	var methodReturns:StringMap<StringMap<String>> = new StringMap();

	/**
	 * How many arguments the current class's host superclass constructor declares, or -1 when the
	 * superclass is in this batch and needs no padding.
	 */
	var superArgs:Int = -1;

	/**
	 * The element type to give the next temporary this emitter introduces.
	 *
	 * A local's array type comes from what it was declared as, and a temporary is declared with no
	 * type at all, so it would be built untyped however specific its contents are. That matters when
	 * the temporary is then read into a slot the loader believes holds a typed array: it reads the
	 * wrong shape and yields nothing useful. This carries the type across the one step where there is
	 * no declaration to take it from.
	 */
	var temporaryArray:Null<String> = null;

	/** Full path of the class being written. */
	var currentClass:String;

	/** Its superclass's path, or the empty string when it has none. */
	var currentSuper:String;

	/** Its instance fields, to whether each is a method rather than a var holding one. */
	var members:StringMap<Bool>;

	/** Its static fields, read the same way. */
	var statics:StringMap<Bool>;

	/** Declared types of its instance fields. */
	var memberTypes:StringMap<String>;

	/** Declared types of its statics. */
	var staticTypes:StringMap<String>;

	/** Constructor names of every enum this batch declares, by full type path. */
	var enumCtors:StringMap<StringMap<Bool>>;

	/** Assignments for the current class's member field initialisers. */
	var memberInits:Array<Expr>;

	/** Top-level field names, mapped to the synthetic class holding them. */
	var moduleFields:StringMap<String>;

	/** Classes from this batch that the emitted code names. */
	var refs:Array<String>;

	/** Scripted classes the host has elsewhere, which this batch cannot reach. */
	var external:StringMap<Bool>;

	/** Bare names the host answers with a static of its own, as `owner::field`. */
	var ambientMembers:StringMap<String>;

	/**
	 * `class.field` of every static property with a getter, which must be read through it.
	 *
	 * A static read links straight to the storage slot, so unlike a member property the accessor is
	 * never consulted and has to be called outright.
	 */
	var staticGetters:StringMap<Bool>;

	/** `class.field` of every static property with a setter, which must be written through it. */
	var staticSetters:StringMap<Bool>;

	/** Starts an empty batch. One emitter writes one module, however many classes it holds. */
	public function new() {
		w = new CppiaWriter();
		classCount = 0;
		nextVarId = 1;
		scopes = [];
		scopeTypes = [];
		typePaths = new StringMap();
		moduleClasses = new StringMap();
		classVars = new StringMap();
		members = new StringMap();
		statics = new StringMap();
		memberTypes = new StringMap();
		staticTypes = new StringMap();
		enumCtors = new StringMap();
		staticGetters = new StringMap();
		staticSetters = new StringMap();
		moduleFields = new StringMap();
		memberInits = [];
		refs = [];
		external = new StringMap();
		ambientMembers = new StringMap();
		currentClass = '';
		currentSuper = '';

		for (name in BUILTIN_TYPES)
			typePaths.set(name, name);
	}

	/**
	 * Registers types the host makes available to every script without an import.
	 *
	 * A script written against those names has no `DImport` to resolve them by, so without this the
	 * emitter cannot place them and refuses the module.
	 *
	 * @param paths Full type paths, each registered under its last segment. An entry written
	 *        `Name=full.path` registers under `Name` instead, for a host that binds a type to a name
	 *        of its own choosing.
	 */
	public function ambient(paths:Array<String>):Void {
		for (entry in paths) {
			var short:String;
			var path:String;

			var equals:Int = entry.indexOf('=');
			if (equals >= 0) {
				short = entry.substr(0, equals);
				path = entry.substr(equals + 1);
			} else {
				path = entry;
				var dot:Int = path.lastIndexOf('.');
				short = dot < 0 ? path : path.substr(dot + 1);
			}

			if (!typePaths.exists(short))
				typePaths.set(short, path);
		}
	}

	/**
	 * Records the types a module declares and imports, without emitting anything. Every module must
	 * be declared before any is emitted.
	 *
	 * @param decls The module's declarations.
	 * @param moduleName The module they came from, used to keep two batches' classes apart.
	 */
	public function declare(decls:Array<ModuleDecl>, moduleName:String = null):Void {
		var pack:String = '';

		for (decl in decls) {
			switch (decl.d) {
				case DField(m):
					var owner:String = fieldsClass(decls, moduleName);
					moduleFields.set(m.name, owner);
					switch (m.kind) {
						case KVar(v):
							if (v.get == 'get' || v.get == 'dynamic')
								staticGetters.set(owner + '.' + m.name, true);
							if (v.set == 'set' || v.set == 'dynamic') staticSetters.set(owner + '.' + m.name, true);
						case _:
					}
				case _:
			}
		}

		for (decl in decls) {
			switch (decl.d) {
				case DPackage(path):
					pack = path.join('.');
				case DImport(path, mode):
					var full:String = path.join('.');
					var short:String = switch (mode) {
						case IAsName(alias): alias;
						case _: path[path.length - 1];
					}
					typePaths.set(short, full);
				case DClass(c) | DInterface(c):
					var full:String = pack.length > 0 ? pack + '.' + c.name : c.name;
					typePaths.set(c.name, full);
					moduleClasses.set(full, true);

					var vars:StringMap<String> = new StringMap();
					for (f in c.fields) {
						if (hasAccess(f, AStatic))
							continue;
						switch (f.kind) {
							case KVar(v) if (plainAccess(v.get) && plainAccess(v.set)):
								vars.set(f.name, v.type == null ? '' : typeName(v.type));
							case _:
						}
					}
					classVars.set(full, vars);

					var rets:StringMap<String> = new StringMap();
					for (f in c.fields) {
						switch (f.kind) {
							case KFunction(fn) if (fn.ret != null):
								rets.set(f.name, typeName(fn.ret));
							case _:
						}
					}
					methodReturns.set(full, rets);

					for (f in c.fields) {
						if (!hasAccess(f, AStatic))
							continue;
						switch (f.kind) {
							case KVar(v):
								if (v.get == 'get' || v.get == 'dynamic')
									staticGetters.set(full + '.' + f.name, true);
								if (v.set == 'set' || v.set == 'dynamic') staticSetters.set(full + '.' + f.name, true);
							case _:
						}
					}
				case DAbstract(a):
					var full:String = pack.length > 0 ? pack + '.' + a.name : a.name;

					// Not set here when the host already offers the name: another module in this batch
					// resolving `Damage` almost certainly means the one it was given. The module that
					// declares it gets its own view applied in `ownView` before it is emitted.
					if (!typePaths.exists(a.name))
						typePaths.set(a.name, full);

					moduleClasses.set(full, true);
					moduleAbstracts.set(full, a.underlying == null ? '' : typeName(a.underlying));
					classVars.set(full, new StringMap());

					for (f in a.fields) {
						if (f.name == 'new')
							abstractCtors.set(full, true);
					}

					var returns:StringMap<String> = new StringMap();
					for (f in a.fields) {
						switch (f.kind) {
							case KFunction(fn) if (fn.ret != null):
								returns.set(f.name == 'new' ? '@new' : f.name, typeName(fn.ret));
							case _:
						}
					}
					methodReturns.set(full, returns);
				case DEnum(en):
					var full:String = pack.length > 0 ? pack + '.' + en.name : en.name;
					typePaths.set(en.name, full);
					moduleClasses.set(full, true);

					var ctors:StringMap<Bool> = new StringMap();
					for (name in en.names)
						ctors.set(name, true);
					enumCtors.set(full, ctors);
				case _:
			}
		}
	}

	/**
	 * Emits every type a module declares.
	 *
	 * @param decls The module's declarations.
	 * @param moduleName The module they came from, used to keep two batches' classes apart.
	 * @throws CppiaUnsupported If any declaration has no cppia spelling.
	 */
	public function emit(decls:Array<ModuleDecl>, moduleName:String = null):Void {
		ownView(decls);

		emitModuleFields(decls, moduleName);

		var pack:String = '';

		for (decl in decls) {
			switch (decl.d) {
				case DPackage(path):
					pack = path.join('.');
				case DClass(c):
					emitClass(c, pack, false, decl.pos);
				case DInterface(c):
					emitClass(c, pack, true, decl.pos);
				case DImport(_, _) | DUsing(_):
				case DEnum(en):
					emitEnum(en, pack);
				case DAbstract(a):
					emitClass(implementationOf(a, pack), pack, false, decl.pos);
				case DTypedef(_):
				case DField(_):
			}
		}
	}

	/**
	 * The synthetic class a module's top-level fields become statics of, matching the interpreter's
	 * own `<name>_Fields_` convention.
	 *
	 * @param decls The module's declarations, read for its package.
	 * @param moduleName The module's name.
	 * @return The class path, or null when the module has no top-level fields to hold.
	 */
	function fieldsClass(decls:Array<ModuleDecl>, moduleName:String):String {
		var pack:String = '';
		for (decl in decls) {
			switch (decl.d) {
				case DPackage(path):
					pack = path.join('.');
				case _:
			}
		}

		var short:String = moduleName == null ? 'Module' : moduleName;
		var dot:Int = short.lastIndexOf('.');
		if (dot >= 0)
			short = short.substr(dot + 1);

		return (pack.length > 0 ? pack + '.' : '') + short + '_Fields_';
	}

	/**
	 * Emits a module's top-level fields as statics of one synthetic class.
	 *
	 * @param decls The module's declarations.
	 * @param moduleName The module's name.
	 */
	function emitModuleFields(decls:Array<ModuleDecl>, moduleName:String):Void {
		var fields:Array<FieldDecl> = [];
		var pos:Position = null;

		for (decl in decls) {
			switch (decl.d) {
				case DField(m):
					if (pos == null)
						pos = decl.pos;
					fields.push({
						name: m.name,
						meta: m.meta,
						kind: m.kind,
						access: m.isPrivate ? [AStatic, APrivate] : [AStatic, APublic]
					});
				case _:
			}
		}

		if (fields.length == 0)
			return;

		emitClass({
			name: fieldsClass(decls, moduleName),
			params: [],
			meta: [],
			isPrivate: false,
			extend: null,
			implement: [],
			fields: fields,
			isExtern: false
		}, '', false, pos);
	}

	/** Assembles the finished module. */
	public function finish():Bytes {
		w.token('NOMAIN');
		w.newline();
		w.token('RESOURCES');
		w.int(0);
		w.newline();
		return w.finish(classCount);
	}

	/**
	 * Emits an enum declaration. Unlike a class record, no super type or interface list is written
	 * and the fields are constructors rather than `FUNCTION`/`VAR` records.
	 *
	 * @param en The enum to emit.
	 * @param pack Its package, or the empty string.
	 */
	function emitEnum(en:EnumDecl, pack:String):Void {
		var full:String = pack.length > 0 ? pack + '.' + en.name : en.name;

		w.newline();
		w.token('ENUM');
		w.type(full);
		w.int(en.names.length);

		for (name in en.names) {
			var ctor:EnumFieldDecl = en.constructs.get(name);
			var args:Array<Argument> = ctor.arguments == null ? [] : ctor.arguments;

			w.str(name);
			w.int(args.length);
			for (a in args) {
				w.str(a.name);
				w.type(a.t == null ? '' : typeName(a.t));
			}
		}

		w.bool(false);
		w.newline();

		classCount++;
	}

	/**
	 * Re-resolves short names the way the module being emitted sees them.
	 *
	 * Every module in the batch is declared into one table, so a name declared in one is visible from
	 * all of them, and a name the host also offers is decided by whichever was written last. Neither
	 * is how Haxe reads a module: its own declarations and its own imports come first, and another
	 * file's types are reachable only through an import.
	 *
	 * A fresh emitter is built for each module and declares the batch before emitting one of them, so
	 * applying that module's own view last is enough to get the precedence right -- without it a
	 * script declaring `Damage` beside a host `Damage` silently linked the wrong one.
	 *
	 * @param decls The declarations of the module about to be emitted.
	 */
	function ownView(decls:Array<ModuleDecl>):Void {
		var pack:String = '';

		for (decl in decls) {
			switch (decl.d) {
				case DPackage(path):
					pack = path.join('.');

				case DImport(path, mode):
					var full:String = path.join('.');
					typePaths.set(switch (mode) {
						case IAsName(alias): alias;
						case _: path[path.length - 1];
					}, full);

				case DClass(c) | DInterface(c):
					typePaths.set(c.name, pack.length > 0 ? pack + '.' + c.name : c.name);

				case DAbstract(a):
					typePaths.set(a.name, pack.length > 0 ? pack + '.' + a.name : a.name);

				case DEnum(en):
					typePaths.set(en.name, pack.length > 0 ? pack + '.' + en.name : en.name);

				case _:
			}
		}
	}

	/**
	 * An abstract's implementation class, in the same shape the interpreter builds.
	 *
	 * An abstract has no runtime form of its own -- in Haxe or here. What exists is a class of
	 * statics, each taking the boxed value as a leading `this`, and a box that carries which abstract
	 * it belongs to. The box, the operators and the `from`/`to` conversions stay with the
	 * interpreter, which is where the type information they need lives; the methods are an ordinary
	 * class and compile like one.
	 *
	 * Built through `ScriptedAbstract.staticForm` rather than a copy of it, so the compiled methods
	 * cannot drift from the interpreted ones.
	 *
	 * @param a The abstract's declaration.
	 * @param pack Its package, unused beyond matching `emitClass`'s shape.
	 * @return The class to emit in its place.
	 */
	function implementationOf(a:AbstractDecl, pack:String):ClassDecl {
		var fields:Array<FieldDecl> = [];
		for (f in a.fields) {
			var made:FieldDecl = f.access.contains(AStatic) ? f : hxscript.types.ScriptedAbstract.staticForm(f, a.name, a.underlying);

			// `staticForm` ends a constructor with a bare `this`, which the interpreter returns
			// because a scripted body yields its last expression. Compiled code does not: a
			// function returns only what it is told to, so the trailing value is made a return.
			if (made.name == '@new') {
				switch (made.kind) {
					case KFunction(fn):
						switch (fn.expr.e) {
							case EBlock(list) if (list.length > 0):
								var last:Expr = list[list.length - 1];
								list[list.length - 1] = {e: EReturn(last), pos: last.pos};
							case _:
						}
					case _:
				}
			}

			fields.push(made);
		}

		return {
			name: a.name,
			meta: a.meta,
			params: a.params,
			extend: null,
			implement: [],
			fields: fields,
			isPrivate: a.isPrivate,
			isExtern: false
		};
	}

	/**
	 * Writes one class or interface: its header, then every field it declares.
	 *
	 * @param c The declaration.
	 * @param pack Its package, empty for the root one.
	 * @param isInterface Whether it was declared as an interface, which changes the header and
	 *        leaves its methods without bodies.
	 * @param pos Where it appears.
	 */
	function emitClass(c:ClassDecl, pack:String, isInterface:Bool, pos:Position):Void {
		var full:String = pack.length > 0 ? pack + '.' + c.name : c.name;

		currentClass = full;
		currentSuper = c.extend == null ? '' : typeName(c.extend);

		// cppia links a call by its exact argument count, so a script's `super(a, b)` against a host
		// constructor whose third argument is optional is a count short -- which the loader accepts
		// and the runtime rejects, mid-call, as `CallHaxe: Invalid arg count`. The type table records
		// each class's constructor shape for exactly this, and `superArity` reads it. A host class
		// whose shape is not recorded cannot be padded, so it is refused instead: interpreting is
		// correct, and crashing is not.
		//
		// Extending another class from the same batch needs none of this: its constructor is here.
		superArgs = -1;

		if (currentSuper != '' && declaredClass(currentSuper) == null) {
			superArgs = hostConstructorArity(currentSuper);
			if (superArgs < 0)
				throw new CppiaUnsupported('extends ' + currentSuper + ', whose constructor shape is unknown', pos);
		}
		members = new StringMap();
		statics = new StringMap();
		memberTypes = new StringMap();
		staticTypes = new StringMap();

		for (f in c.fields) {
			var declared:String = switch (f.kind) {
				case KVar(v): v.type == null ? null : typeName(v.type);
				case KFunction(fn): fn.ret == null ? null : typeName(fn.ret);
			}

			// A rest-argument function is emitted as a var holding a closure, so it is called as a
			// value rather than linked as a method.
			var isMethod:Bool = f.kind.match(KFunction(_)) && restArg(f) == null;

			if (hasAccess(f, AStatic)) {
				statics.set(f.name, isMethod);
				if (declared != null)
					staticTypes.set(f.name, declared);
			} else {
				members.set(f.name, isMethod);
				if (declared != null)
					memberTypes.set(f.name, declared);
			}
		}

		memberInits = [];
		for (f in c.fields) {
			if (hasAccess(f, AStatic))
				continue;
			switch (f.kind) {
				case KVar(v) if (v.expr != null):
					var target:Expr = {e: EField({e: EIdent('this'), pos: pos}, f.name, false), pos: pos};
					memberInits.push({e: EBinop('=', target, v.expr), pos: pos});
				case _:
			}
		}

		w.newline();
		w.token(isInterface ? 'INTERFACE' : 'CLASS');
		w.type(full);
		useType(currentSuper);
		w.int(c.implement.length);
		for (i in c.implement)
			w.type(typeName(i));
		w.int(c.fields.length);
		w.newline();

		for (f in c.fields)
			emitField(f, isInterface, pos);

		classCount++;
	}

	/**
	 * Puts the class's member initialisers at the front of its constructor, after any `super` call.
	 *
	 * A member `VAR` record's initialiser is only run for statics, so a member field declared with a
	 * value would otherwise start zeroed.
	 *
	 * @param body The constructor body as written.
	 * @param pos Where the constructor is declared.
	 * @return The body with the initialisers prepended.
	 */
	function withMemberInits(body:Expr, pos:Position):Expr {
		if (memberInits.length == 0)
			return body;

		var out:Array<Expr> = [];
		var rest:Array<Expr> = switch (body.e) {
			case EBlock(list): list.copy();
			case _: [body];
		}

		if (rest.length > 0) {
			switch (rest[0].e) {
				case ECall({e: EIdent('super')}, _):
					out.push(rest.shift());
				case _:
			}
		}

		for (init in memberInits)
			out.push(init);
		for (item in rest)
			out.push(item);

		return {e: EBlock(out), pos: pos};
	}

	/**
	 * Writes one field of the class being emitted, as storage or as a method.
	 *
	 * @param f The declaration.
	 * @param isInterface Whether the owner is an interface, whose methods carry no body.
	 * @param pos Where it appears.
	 */
	function emitField(f:FieldDecl, isInterface:Bool, pos:Position):Void {
		var isStatic:Bool = hasAccess(f, AStatic);

		// A cppia function has a fixed number of arguments, so a rest parameter cannot be one. What
		// can is a field holding a closure built by `Reflect.makeVarArgs`, which every caller reaches
		// the same way -- compiled code, the interpreter and the host alike -- and which accepts
		// however many arguments it is given. Calls to it are already routed as value calls, since
		// what it is now is a var rather than a method.
		if (!isInterface && restArg(f) != null) {
			emitVarArgsField(f, isStatic, pos);
			return;
		}

		switch (f.kind) {
			case KFunction(fn):
				var isConstructor:Bool = f.name == 'new';

				if (echoTarget != null && echoTarget == currentClass + '.' + f.name) {
					w.echo = new StringBuf();
					echoing = true;
				}

				w.token('FUNCTION');
				w.bool(isStatic || isConstructor);
				w.bool(hasAccess(f, ADynamic));
				w.str(f.name);
				w.type(fn.ret == null ? '' : typeName(fn.ret));
				w.int(fn.args.length);
				for (a in fn.args) {
					w.str(a.name);
					w.bool(a.opt == true || a.value != null);
					w.type(a.t == null ? '' : typeName(a.t));
				}

				if (!isInterface)
					emitFunctionBody(fn, f.name == 'new', pos);
				w.newline();

			case KVar(v):
				w.token('VAR');
				w.bool(isStatic);
				w.token(accessCode(v.get, pos));
				w.token(accessCode(v.set, pos));
				w.bool(false);
				w.str(f.name);
				w.type(v.type == null ? '' : typeName(v.type));

				if (v.expr == null || !isStatic) {
					w.int(0);
				} else {
					w.int(1);
					pushScope();

					// Without this an array literal is built as `Array` while reads inside the
					// declaring class use the declared `Array.int`, so cppia reads object slots as
					// ints. Locals and instance fields already infer this; statics did not.
					expectedArray = elementArray(v.type == null ? null : typeName(v.type));
					expectedElem = arrayElemOf(v.type);
					expr(v.expr);
					expectedArray = null;
					expectedElem = null;

					popScope();
				}
				w.newline();

				if (echoing) {
					echoed = w.echo.toString();
					w.echo = null;
					echoing = false;
				}
		}
	}

	/**
	 * Writes a method's arguments and body.
	 *
	 * A constructor gets the member initialisers folded in ahead of its own body, which is where a
	 * field's `= value` is run.
	 *
	 * @param fn The declaration.
	 * @param isConstructor Whether it is the constructor.
	 * @param pos Where it appears.
	 */
	function emitFunctionBody(fn:FunctionDecl, isConstructor:Bool, pos:Position):Void {
		emitFun(fn.args, isConstructor ? withMemberInits(fn.expr, pos) : fn.expr, fn.ret, pos);
	}

	/**
	 * Emits a `FUN` expression: the signature in stack-variable form, then the body. Used for both
	 * methods and function values.
	 *
	 * Captures are left to the loader, which walks the enclosing stack layout; this only has to nest
	 * and to keep variable ids unique. Default argument values become null-checks prepended to the
	 * body, since cppia accepts only constants in the signature.
	 *
	 * @param args The function's arguments.
	 * @param body Its body.
	 * @param ret Its return type, if annotated.
	 * @param pos Where it was declared.
	 */
	function emitFun(args:Array<Argument>, body:Expr, ret:Null<CType>, pos:Position):Void {
		pushScope();

		w.pos(pos == null ? 0 : pos.line);
		w.token('FUN');
		w.type(ret == null ? '' : typeName(ret));
		w.int(args.length);

		for (a in args) {

			noteArrayElement(a.name, a.t);
			var id:Int = declareVar(a.name, a.t == null ? null : typeName(a.t));

			w.str(a.name);
			w.int(id);
			w.bool(false);
			storableType(a.t == null ? '' : typeName(a.t));
			w.bool(false);
		}

		var prologue:Array<Expr> = [];
		for (a in args) {
			if (a.value != null) {
				var target:Expr = {e: EIdent(a.name), pos: pos};
				var isNull:Expr = {e: EBinop('==', target, {e: EIdent('null'), pos: pos}), pos: pos};
				var assign:Expr = {e: EBinop('=', target, a.value), pos: pos};
				prologue.push({e: EIf(isNull, assign, null), pos: pos});
			}
		}

		var boxedBody:Expr = body;
		var boxing = CppiaCapture.transform(args, {e: EBlock(prologue.concat([body])), pos: pos});
		boxedBody = boxing.body;

		var entry:Array<Expr> = [];
		for (name in boxing.boxedArgs) {
			var ident:Expr = {e: EIdent(name), pos: pos};
			entry.push({e: EBinop('=', ident, {e: EArrayDecl([ident]), pos: pos}), pos: pos});
		}

		if (entry.length == 0)
			expr(boxedBody);
		else
			expr({e: EBlock(entry.concat([boxedBody])), pos: pos});

		popScope();
	}

	/**
	 * Writes one expression, and whatever it contains.
	 *
	 * The whole emitter hangs off this: every form the compiler accepts has a case here, and any
	 * form it does not throws `CppiaUnsupported`, which abandons the module rather than the batch.
	 *
	 * @param e The expression, or null for a literal absence.
	 * @throws CppiaUnsupported If it has no cppia spelling.
	 */
	function expr(e:Expr):Void {
		// The expected array type is meant for a literal standing directly where it was set, so
		// anything else consumes and discards it rather than letting it reach a nested literal that
		// has nothing to do with the target.
		if (e != null && !e.e.match(EArrayDecl(_)))
			expectedArray = null;

		if (e == null) {
			w.pos(0);
			w.token('NULL');
			return;
		}

		var line:Int = e.pos == null ? 0 : e.pos.line;

		switch (e.e) {
			case EConst(c):
				w.pos(line);
				switch (c) {
					case CInt(v):
						w.token('i');
						w.int(v);
					case CFloat(f):
						w.token('f');
						w.str(Std.string(f));
					case CString(s, _):
						w.token('s');
						w.str(s);
					case CReg(pattern, modifiers):
						w.token('NEW');
						w.type('EReg');
						w.int(2);
						w.pos(line);
						w.token('s');
						w.str(pattern);
						w.pos(line);
						w.token('s');
						w.str(modifiers == null ? '' : modifiers);
				}

			case EIdent(v):
				emitIdent(v, e.pos);

			case EParent(inner):
				expr(inner);

			case EBlock(list):
				w.pos(line);
				w.token('BLOCK');
				pushScope();
				emitBlockBody(list, e.pos);
				popScope();

			case EVar(_, _, _, _, _, _):
				w.pos(line);
				w.token('BLOCK');
				emitBlockBody([e], e.pos);

			case EIf(cond, e1, e2):
				w.pos(line);
				if (e2 == null) {
					w.token('IF');
					expr(cond);
					expr(e1);
				} else {
					w.token('IFELSE');
					expr(cond);
					expr(e1);
					expr(e2);
				}

			case ETernary(cond, e1, e2):
				w.pos(line);
				w.token('IFELSE');
				expr(cond);
				expr(e1);
				expr(e2);

			case EWhile(cond, body):
				w.pos(line);
				w.token('WHILE');
				w.int(1);
				expr(cond);
				expr(body);

			case EDoWhile(cond, body):
				w.pos(line);
				w.token('WHILE');
				w.int(0);
				expr(cond);
				expr(body);

			case EFor(v, it, body):
				expr(forAsWhile(v, it, body, e.pos));

			case EForGen(it, body):
				expr(keyValueLoop(it, body, e.pos));

			case EBreak:
				w.pos(line);
				w.token('BREAK');

			case EContinue:
				w.pos(line);
				w.token('CONTINUE');

			case EReturn(v):
				w.pos(line);
				if (v == null) {
					w.token('RETURN');
				} else {
					w.token('RETVAL');
					w.type('');
					expr(v);
				}

			case EThrow(v):
				w.pos(line);
				w.token('THROW');
				expr(v);

			case EBinop(op, e1, e2):
				emitBinop(op, e1, e2, e.pos);

			case EUnop(op, prefix, inner):
				w.pos(line);
				switch (op) {
					case '-':
						w.token('NEG');
					case '!':
						w.token('!');
					case '~':
						w.token('~');
					case '++' | '--':
						// Postfix must yield the value from before the change, so correct by one.
						if (repeatableField(inner)) {
							var step:String = op == '++' ? '+' : '-';
							var back:String = op == '++' ? '-' : '+';
							var one:Expr = {e: EConst(CInt(1)), pos: e.pos};

							var changed:Expr = {
								e: EBinop('=', inner, {e: EBinop(step, inner, one), pos: e.pos}),
								pos: e.pos
							};

							if (prefix) {
								expr(changed);
							} else {
								expr({e: EBinop(back, {e: EParent(changed), pos: e.pos}, one), pos: e.pos});
							}
							return;
						}

						w.token(op == '++' ? (prefix ? '++' : '+++') : (prefix ? '--' : '---'));
					default:
						throw new CppiaUnsupported('unary operator ' + op, e.pos);
				}
				expr(inner);

			case ECall(callee, params):
				emitCall(callee, params, e.pos);

			case EField(obj, f, maybe):
				if (maybe == true) {
					expr(nullSafe(obj, function(safe:Expr):Expr {
						return {e: EField(safe, f, false), pos: e.pos};
					}, e.pos));
					return;
				}
				emitField2(obj, f, e.pos);

			case EArray(arr, index):
				var known:Null<String> = inferType(arr);
				w.pos(line);
				w.token('ARRAYI');
				w.type(known != null && known.substr(0, 5) == 'Array' ? known : 'Dynamic');
				expr(arr);
				expr(index);

			case EArrayDecl(items):
				if (items.length > 0 && items[0].e.match(EBinop('=>', _, _))) {
					expr(mapLiteral(items, e.pos));
					return;
				}
				if (items.length == 1 && isComprehension(items[0])) {
					expr(comprehension(items[0], expectedArray, e.pos));
					return;
				}
				var want:Null<String> = expectedArray;
				var elem:Null<CType> = expectedElem;
				expectedArray = null;
				expectedElem = null;

				w.pos(line);
				w.token('ADEF');
				w.type(want == null ? 'Array' : want);
				w.int(items.length);

				// An array of arrays spells as `Array.Object`, which says nothing about what the
				// inner ones hold, so the element type has to be handed down from the declaration
				// rather than read back off the parent's spelling. Without it the inner literals are
				// built loose while every read of one goes through its declared spelling.
				var innerWant:Null<String> = arrayNameOf(elem);
				var innerElem:Null<CType> = arrayElemOf(elem);

				for (item in items) {
					expectedArray = innerWant;
					expectedElem = innerElem;
					expr(item);
				}

				expectedArray = null;
				expectedElem = null;

			case ENew(cl, params):
				// An abstract has nothing to allocate. Its constructor is a static whose leading
				// `this` starts out null and whose body assigns it, so calling that yields the
				// underlying value -- and an abstract with no constructor is simply its argument.
				var boxed:Null<String> = abstractPathOf(cl);
				if (boxed != null) {
					if (!abstractCtors.exists(boxed)) {
						expr(params.length > 0 ? params[0] : null);
						return;
					}

					w.pos(line);
					w.token('CALLSTATIC');
					useType(boxed);
					w.str('@new');
					w.int(params.length + 1);
					w.pos(line);
					w.token('NULL');
					for (p in params)
						expr(p);
					return;
				}

				w.pos(line);
				w.token('NEW');
				useType(resolveType(cl, e.pos));
				w.int(params.length);
				for (p in params)
					expr(p);

			case EObject(fields):
				w.pos(line);
				w.token('OBJDEF');
				w.int(fields.length);
				for (f in fields)
					w.str(f.name);
				for (f in fields)
					expr(f.e);

			case ETry(body, v, t, ecatch, extra):
				w.pos(line);
				w.token('TRY');
				w.int(1 + (extra == null ? 0 : extra.length));
				expr(body);

				emitCatch(v, t, ecatch);
				if (extra != null) {
					for (x in extra)
						emitCatch(x.v, x.t, x.expr);
				}

			case ESwitch(cond, cases, defaultExpr):
				emitSwitch(cond, cases, defaultExpr, e.pos);

			case ECast(inner, _):
				w.pos(line);
				w.token('CAST');
				expr(inner);

			case ECheckType(inner, _):
				expr(inner);

			case EMeta(_, _, inner):
				expr(inner);

			case EFunction(args, body, _, ret, _):
				emitFun(args, body, ret, e.pos);

			case EDecl(_):
				throw new CppiaUnsupported('inline type declarations', e.pos);

			case EImport(_, _) | EUsing(_):
				w.pos(line);
				w.token('NULL');
		}
	}

	/**
	 * Emits a block's contents, folding each `var` into the `TVARS` record cppia expects. Ids are
	 * taken in order and initialisers stay where they were written.
	 *
	 * @param list The block's expressions.
	 * @param pos Where the block starts.
	 */
	function emitBlockBody(list:Array<Expr>, pos:Position):Void {
		var out:Array<Expr> = [];
		for (item in list)
			out.push(discardedIncrement(item));

		w.int(out.length);
		w.newline();

		for (item in out) {
			switch (item.e) {
				case EFunction(fargs, fbody, fname, fret, _) if (fname != null):
					w.pos(item.pos == null ? 0 : item.pos.line);
					w.token('TVARS');
					w.int(1);

					var id:Int = declareVar(fname);
					w.token('VARDECLI');
					w.str(fname);
					w.int(id);
					w.bool(false);
					w.unknownType();
					w.unknownType();
					emitFun(fargs, fbody, fret, item.pos);
					w.newline();

				case EVar(n, t, init, get, set, _):
					if (get != null || set != null)
						throw new CppiaUnsupported('local property accessors', item.pos);

					w.pos(item.pos == null ? 0 : item.pos.line);
					w.token('TVARS');
					w.int(1);

					noteArrayElement(n, t);
					var id:Int = declareVar(n, t == null ? null : typeName(t));
					if (init == null) {
						w.token('VARDECL');
						w.str(n);
						w.int(id);
						w.bool(false);
						storableType(t == null ? '' : typeName(t));
					} else {
						w.token('VARDECLI');
						w.str(n);
						w.int(id);
						w.bool(false);
						storableType(t == null ? '' : typeName(t));
						w.type('');

						var declared:Null<String> = elementArray(t == null ? null : typeName(t));
						if (declared == null && temporaryArray != null) {
							declared = temporaryArray;
							temporaryArray = null;
						}

						expectedArray = declared;
						expr(init);
					}
					w.newline();

				case _:
					expr(item);
					w.newline();
			}
		}
	}

	/**
	 * Lowers a `for` into a `while` over an iterator.
	 *
	 * cppia's own loop expression has no JIT implementation: the base code generator traces the
	 * node's name and emits nothing, so with the JIT on the loop silently does not run at all. The
	 * Haxe compiler lowers `for` the same way and never produces one, which is why the gap goes
	 * unnoticed.
	 *
	 * The loop variable is declared inside the body so every pass rebinds it, which is what the loop
	 * expression did and what a closure made in the body expects.
	 *
	 * A range needs no iterator test; anything else is bound to a temporary and asked once whether it
	 * is already an iterator, since only a static type could answer that and there is none here.
	 *
	 * @param v The loop variable name.
	 * @param it The subject.
	 * @param body The loop body.
	 * @param pos Where the loop appears.
	 * @return An equivalent `while` loop.
	 */
	function forAsWhile(v:String, it:Expr, body:Expr, pos:Position):Expr {
		var outer:Array<Expr> = [];
		var name:String = tempName('it');
		var ref:Expr = {e: EIdent(name), pos: pos};

		switch (it.e) {
			case EBinop('...', low, high):
				outer.push({e: EVar(name, null, {e: ENew('IntIterator', [low, high]), pos: pos}, null, null, false), pos: pos});

			case _:
				var subject:String = tempName('sub');
				var subjectRef:Expr = {e: EIdent(subject), pos: pos};

				var probe:Expr = {
					e: ECall({e: EField({e: EIdent('Reflect'), pos: pos}, 'field'), pos: pos}, [subjectRef, {e: EConst(CString('hasNext')), pos: pos}]),
					pos: pos
				};
				var chosen:Expr = {
					e: ETernary({e: EBinop('!=', probe, {e: EIdent('null'), pos: pos}), pos: pos}, subjectRef,
						{e: ECall({e: EField(subjectRef, 'iterator'), pos: pos}, []), pos: pos}),
					pos: pos
				};

				outer.push({e: EVar(subject, null, it, null, null, false), pos: pos});
				outer.push({e: EVar(name, null, chosen, null, null, false), pos: pos});
		}

		var step:Expr = {e: ECall({e: EField(ref, 'next'), pos: pos}, []), pos: pos};
		var inner:Expr = {e: EBlock([{e: EVar(v, null, step, null, null, false), pos: pos}, body]), pos: pos};
		var test:Expr = {e: ECall({e: EField(ref, 'hasNext'), pos: pos}, []), pos: pos};

		outer.push({e: EWhile(test, inner), pos: pos});
		return {e: EBlock(outer), pos: pos};
	}

	/**
	 * Writes a binary operation.
	 *
	 * Assignment is not one operation among others: what it writes depends on what is being assigned
	 * to, since a property, a static and a local each take a different form.
	 *
	 * @param op The operator.
	 * @param e1 Its left side.
	 * @param e2 Its right side.
	 * @param pos Where it appears.
	 */
	function emitBinop(op:String, e1:Expr, e2:Expr, pos:Position):Void {
		var line:Int = pos == null ? 0 : pos.line;

		if (op == '=') {
			var setter:Null<String> = staticSetterFor(e1);
			if (setter != null) {
				w.pos(line);
				w.token('CALLSTATIC');
				w.type(setter.substr(0, setter.lastIndexOf('.')));
				w.str('set_' + setter.substr(setter.lastIndexOf('.') + 1));
				w.int(1);
				expr(e2);
				return;
			}

			if (hostField(e1)) {
				var target:Expr = null;
				var member:String = null;
				switch (e1.e) {
					case EField(o, f, _):
						target = o;
						member = f;
					case _:
				}

				w.pos(line);
				w.token('CALL');
				w.int(3);
				w.pos(line);
				w.token('FSTATIC');
				w.type('Reflect');
				w.str('setProperty');
				expr(target);
				w.pos(line);
				w.token('s');
				w.str(member);
				expectedArray = elementArray(inferType(e1));
				expr(e2);
				return;
			}

			w.pos(line);
			w.token('SET');
			expr(e1);
			expectedArray = elementArray(inferType(e1));
			expr(e2);
			return;
		}

		if (ASSIGN_OPS.indexOf(op) >= 0) {
			// cppia has no settable target for a field reached through anything but `this`, so write
			// the compound form out long-hand.
			if (repeatableField(e1)) {
				emitBinop('=', e1, {e: EBinop(op.substr(0, op.length - 1), e1, e2), pos: pos}, pos);
				return;
			}

			w.pos(line);
			w.token(op);
			expr(e1);
			expr(e2);
			return;
		}

		if (BINOPS.indexOf(op) >= 0) {
			w.pos(line);
			w.token(op);
			expr(e1);
			expr(e2);
			return;
		}

		if (op == '...') {
			w.pos(line);
			w.token('NEW');
			w.type('IntIterator');
			w.int(2);
			expr(e1);
			expr(e2);
			return;
		}

		throw new CppiaUnsupported('operator ' + op, pos);
	}

	/**
	 * Writes a `switch`.
	 *
	 * Only a switch over plain values has a cppia form. Guards, captures and destructuring do not, so
	 * those are rewritten into an if-else chain first and emitted as that instead.
	 *
	 * @param cond The value being matched.
	 * @param cases Its cases.
	 * @param defaultExpr Its default branch, if any.
	 * @param pos Where it appears.
	 */
	function emitSwitch(cond:Expr, cases:Array<{values:Array<Expr>, expr:Expr, ?guard:Expr}>, defaultExpr:Null<Expr>, pos:Position):Void {
		for (c in cases) {
			if (c.guard != null || captureName(c) != null || destructure(c) != null) {
				expr(switchAsChain(cond, cases, defaultExpr, pos));
				return;
			}
			for (v in c.values) {
				if (anyEnumCtor(v)) {
					expr(switchAsChain(cond, cases, defaultExpr, pos));
					return;
				}

				switch (v.e) {
					case EConst(_) | EIdent(_) | EField(_, _, _):
					case EObject(_) | EArrayDecl(_):
						// Shapes rather than values, which the chain can test and the instruction cannot.
						expr(switchAsChain(cond, cases, defaultExpr, pos));
						return;
					case _:
						throw new CppiaUnsupported('pattern matching in switch', pos);
				}
			}
		}

		w.pos(pos == null ? 0 : pos.line);
		w.token('SWITCH');
		w.int(cases.length);
		w.int(defaultExpr == null ? 0 : 1);
		expr(cond);

		for (c in cases) {
			w.int(c.values.length);
			for (v in c.values)
				expr(v);
			expr(c.expr);
		}

		if (defaultExpr != null)
			expr(defaultExpr);
	}

	/**
	 * Writes a call, choosing the form from what is being called.
	 *
	 * A static of a known class, a method on a known instance and a call through a value are three
	 * different instructions, and picking the most specific one is most of what makes compiled code
	 * faster than interpreted code.
	 *
	 * @param callee What is being called.
	 * @param params Its arguments.
	 * @param pos Where it appears.
	 */
	function emitCall(callee:Expr, params:Array<Expr>, pos:Position):Void {
		var line:Int = pos == null ? 0 : pos.line;

		switch (callee.e) {
			case EField(obj, name, maybe):
				if (maybe == true) {
					expr(nullSafe(obj, function(safe:Expr):Expr {
						return {e: ECall({e: EField(safe, name, false), pos: pos}, params), pos: pos};
					}, pos));
					return;
				}

				var asType:Null<String> = typeOf(obj);
				if (asType != null) {
					if (isEnumCtor(asType, name)) {
						w.pos(line);
						w.token('CREATEENUM');
						useType(asType);
						w.str(name);
						w.int(params.length);
						for (p in params)
							expr(p);
						return;
					}

					if (!moduleClasses.exists(asType)) {
						w.pos(line);
						w.token('CALL');
						w.int(params.length);
						w.pos(line);
						w.token('FSTATIC');
						useType(asType);
						w.str(name);
						for (p in params)
							expr(p);
						return;
					}

					w.pos(line);
					w.token('CALLSTATIC');
					useType(asType);
					w.str(name);
					w.int(params.length);
					for (p in params)
						expr(p);
					return;
				}

				// A method on an abstract-typed value is a static taking that value as its `this`,
				// which is the shape both this emitter and the interpreter build the implementation
				// in. Without this the call would go to the underlying value, which has no such
				// method.
				var boxed:Null<String> = abstractTypeOf(obj);
				if (boxed != null) {
					w.pos(line);
					w.token('CALLSTATIC');
					useType(boxed);
					w.str(name);
					w.int(params.length + 1);
					expr(obj);
					for (p in params)
						expr(p);
					return;
				}

				switch (obj.e) {
					case EIdent('super'):
						w.pos(line);
						w.token('CALLSUPER');
						w.type(currentSuper);
						w.str(name);
						w.int(params.length);
						for (p in params)
							expr(p);
						return;
					case _:
				}

				w.pos(line);
				w.token('CALLMEMBER');
				w.type('');
				w.str(name);
				w.int(params.length);
				expr(obj);
				for (p in params)
					expr(p);

			case EIdent('super'):
				// Padded up to what the host constructor declares. A script may leave optional
				// arguments off; the instruction may not.
				var supplied:Int = params.length;
				var wanted:Int = superArgs > supplied ? superArgs : supplied;

				w.pos(line);
				w.token('CALLSUPERNEW');
				w.type(currentSuper);
				w.int(wanted);
				for (p in params)
					expr(p);

				// Null rather than the declared default, which does not survive into the type table.
				// An omitted optional arrives as null in Haxe too, so the callee sees what it would
				// have seen: its own default handling takes over from there.
				for (i in supplied...wanted) {
					w.pos(line);
					w.token('NULL');
				}

			case EIdent(name) if (lookupVar(name) == null && enumOwning(name) != null):
				w.pos(line);
				w.token('CREATEENUM');
				useType(enumOwning(name));
				w.str(name);
				w.int(params.length);
				for (p in params)
					expr(p);

			case EIdent(name) if (lookupVar(name) == null && members.exists(name) && members.get(name) != true):
				// A var that holds a function: read the field, then call what came out. Linking to it
				// as a method fails, because there is no method of that name to link to.
				callValue({e: EField({e: EIdent('this'), pos: pos}, name), pos: pos}, params, line);

			case EIdent(name) if (lookupVar(name) == null && statics.exists(name) && statics.get(name) != true):
				w.pos(line);
				w.token('CALL');
				w.int(params.length);
				w.pos(line);
				w.token('FSTATIC');
				useType(currentClass);
				w.str(name);
				for (p in params)
					expr(p);

			case EIdent(name) if (lookupVar(name) == null && members.exists(name)):
				w.pos(line);
				w.token('CALLTHIS');
				w.type(currentClass);
				w.str(name);
				w.int(params.length);
				for (p in params)
					expr(p);

			case EIdent(name) if (lookupVar(name) == null && statics.exists(name)):
				w.pos(line);
				w.token('CALLSTATIC');
				w.type(currentClass);
				w.str(name);
				w.int(params.length);
				for (p in params)
					expr(p);

			case EIdent(name) if (lookupVar(name) == null && moduleFields.exists(name)):
				w.pos(line);
				w.token('CALLSTATIC');
				w.type(moduleFields.get(name));
				w.str(name);
				w.int(params.length);
				for (p in params)
					expr(p);

			case EIdent(name) if (lookupVar(name) == null && ambientMembers.exists(name)):
				var target:String = ambientMembers.get(name);
				var split:Int = target.indexOf('::');

				w.pos(line);
				w.token('CALL');
				w.int(params.length);
				w.pos(line);
				w.token('FSTATIC');
				w.type(target.substr(0, split));
				w.str(target.substr(split + 2));
				for (p in params)
					expr(p);

			case _:
				w.pos(line);
				w.token('CALL');
				w.int(params.length);
				expr(callee);
				for (p in params)
					expr(p);
		}
	}

	/**
	 * The rest parameter of a field, if it declares one.
	 *
	 * @param f The field.
	 * @return Its rest argument, or null when it has none.
	 */
	function restArg(f:FieldDecl):Null<Argument> {
		switch (f.kind) {
			case KFunction(fn):
				for (a in fn.args) {
					if (a.rest == true)
						return a;
				}
			case _:
		}

		return null;
	}

	/**
	 * Writes a rest-argument method as a field holding a variadic closure.
	 *
	 * The closure takes one array and unpacks it: each fixed parameter is bound to its position, and
	 * the rest parameter to whatever is left. That is what `Reflect.makeVarArgs` hands it, and it is
	 * what makes the arity of the call site irrelevant.
	 *
	 * @param f The declared field.
	 * @param isStatic Whether it belongs to the class rather than an instance.
	 * @param pos Where it appears.
	 */
	function emitVarArgsField(f:FieldDecl, isStatic:Bool, pos:Position):Void {
		var fn:FunctionDecl = switch (f.kind) {
			case KFunction(d): d;
			case _: null;
		}

		var packed:String = tempName('args');
		var bound:Array<Expr> = [];
		var fixed:Array<Argument> = [];

		for (a in fn.args) {
			if (a.rest == true)
				break;
			fixed.push(a);
		}

		for (i in 0...fixed.length) {
			bound.push({
				e: EVar(fixed[i].name, fixed[i].t,
					{e: EArray({e: EIdent(packed), pos: pos}, {e: EConst(CInt(i)), pos: pos}), pos: pos}, null, null, false),
				pos: pos
			});
		}

		// Everything past the fixed parameters is the rest, which `slice` hands over as an array.
		bound.push({
			e: EVar(fn.args[fn.args.length - 1].name, null, {
				e: ECall({e: EField({e: EIdent(packed), pos: pos}, 'slice'), pos: pos},
					[{e: EConst(CInt(fixed.length)), pos: pos}]),
				pos: pos
			}, null, null, false),
			pos: pos
		});

		bound.push(fn.expr);

		var inner:Expr = {
			e: EFunction([{name: packed, t: null}], {e: EBlock(bound), pos: pos}, null, fn.ret),
			pos: pos
		};

		var made:Expr = {
			e: ECall({e: EField({e: EIdent('Reflect'), pos: pos}, 'makeVarArgs'), pos: pos}, [inner]),
			pos: pos
		};

		// Written as an ordinary var whose initialiser builds the closure. Only a static carries one:
		// an instance field is initialised per instance, which the constructor does.
		w.token('VAR');
		w.bool(isStatic);
		w.token('N');
		w.token('N');
		w.bool(false);
		w.str(f.name);
		w.unknownType();

		if (isStatic) {
			w.int(1);
			pushScope();
			expr(made);
			popScope();
		} else {
			w.int(0);
			memberInits.push({e: EBinop('=', {e: EField({e: EIdent('this'), pos: pos}, f.name), pos: pos}, made), pos: pos});
		}

		w.newline();
	}

	/**
	 * Writes a call of whatever a value turns out to be.
	 *
	 * Used where the thing being called is a function held in a field or a local rather than a
	 * method declared on a class. cppia links a method call by name, which needs a method of that
	 * name to exist; this reads the value first and calls that.
	 *
	 * @param callee An expression for the function.
	 * @param params The arguments.
	 * @param line The source line.
	 */
	function callValue(callee:Expr, params:Array<Expr>, line:Int):Void {
		w.pos(line);
		w.token('CALL');
		w.int(params.length);
		expr(callee);
		for (p in params)
			expr(p);
	}

	/**
	 * Writes a field read.
	 *
	 * By offset when the object's class is known and the field is plain storage, by name otherwise.
	 * The offset form is the faster of the two and the reason the emitter tracks classes at all.
	 *
	 * @param obj The object.
	 * @param name The field.
	 * @param pos Where it appears.
	 */
	function emitField2(obj:Expr, name:String, pos:Position):Void {
		var line:Int = pos == null ? 0 : pos.line;

		var asType:Null<String> = typeOf(obj);
		if (asType != null) {
			if (isEnumCtor(asType, name)) {
				w.pos(line);
				w.token('FENUM');
				useType(asType);
				w.str(name);
				return;
			}

			if (staticGetters.exists(asType + '.' + name)) {
				w.pos(line);
				w.token('CALLSTATIC');
				useType(asType);
				w.str('get_' + name);
				w.int(0);
				return;
			}

			w.pos(line);
			w.token('FSTATIC');
			useType(asType);
			w.str(name);
			return;
		}

		// A known class turns the access into an offset the loader resolves once, instead of a lookup
		// by name on every evaluation. That is the difference between a field read costing what
		// arithmetic costs and costing twenty-five times more, which is the whole cost of anything
		// shaped like a renderer.
		var holder:Null<String> = (obj.e.match(EIdent('this'))) ? currentClass : instanceClassOf(obj);
		if (holder != null && instanceVar(holder, name) != null) {
			w.pos(line);
			w.token('FLINK');
			w.type(holder);
			w.str(name);
			expr(obj);
			return;
		}

		// Nothing here knows what `obj` is, so it is something the host owns, and on a host object a
		// name may be a property rather than a field. Reading it as a field returns null and writing
		// it does nothing -- silently, which is the worst way for it to be wrong. Going through
		// property access costs a call and is right for both.
		w.pos(line);
		w.token('CALL');
		w.int(2);
		w.pos(line);
		w.token('FSTATIC');
		w.type('Reflect');
		w.str('getProperty');
		expr(obj);
		w.pos(line);
		w.token('s');
		w.str(name);
	}

	/**
	 * Writes a bare identifier, which may be a local, a field of `this`, a type, or a host static.
	 *
	 * @param v The name.
	 * @param pos Where it appears.
	 * @throws CppiaUnsupported If it resolves to nothing this batch or the host can offer.
	 */
	function emitIdent(v:String, pos:Position):Void {
		var line:Int = pos == null ? 0 : pos.line;

		switch (v) {
			case 'true':
				w.pos(line);
				w.token('true');
				return;
			case 'false':
				w.pos(line);
				w.token('false');
				return;
			case 'null':
				w.pos(line);
				w.token('NULL');
				return;
			case 'this':
				// An abstract's methods are statics whose first parameter is literally named `this`,
				// which is how both this emitter and the interpreter give them the boxed value. In
				// one of those, `this` is that parameter and not an instance.
				var self:Null<Int> = lookupVar('this');
				if (self == null) {
					w.pos(line);
					w.token('THIS');
					return;
				}

				w.pos(line);
				w.token('VAR');
				w.int(self);
				return;
			default:
		}

		var owner:Null<String> = lookupVar(v) != null ? null : enumOwning(v);
		if (owner != null) {
			w.pos(line);
			w.token('CREATEENUM');
			useType(owner);
			w.str(v);
			w.int(0);
			return;
		}

		var local:Null<Int> = lookupVar(v);
		if (local != null) {
			w.pos(line);
			w.token('VAR');
			w.int(local);
			return;
		}

		if (members.exists(v)) {
			w.pos(line);
			w.token(instanceVar(currentClass, v) != null ? 'FTHISINST' : 'FTHISNAME');
			w.type(currentClass);
			w.str(v);
			return;
		}

		if (statics.exists(v)) {
			if (staticGetters.exists(currentClass + '.' + v)) {
				w.pos(line);
				w.token('CALLSTATIC');
				w.type(currentClass);
				w.str('get_' + v);
				w.int(0);
				return;
			}

			w.pos(line);
			w.token('FSTATIC');
			w.type(currentClass);
			w.str(v);
			return;
		}

		if (moduleFields.exists(v)) {
			var owner:String = moduleFields.get(v);
			w.pos(line);

			if (staticGetters.exists(owner + '.' + v)) {
				w.token('CALLSTATIC');
				w.type(owner);
				w.str('get_' + v);
				w.int(0);
				return;
			}

			w.token('FSTATIC');
			w.type(owner);
			w.str(v);
			return;
		}

		if (typePaths.exists(v)) {
			w.pos(line);
			w.token('CLASSOF');
			w.type(typePaths.get(v));
			return;
		}

		if (emitAmbient(v, pos))
			return;

		if (currentSuper.length > 0) {
			w.pos(line);
			w.token('FNAME');
			w.unknownType();
			w.str(v);
			w.pos(line);
			w.token('THIS');
			return;
		}

		throw new CppiaUnsupported('unresolved identifier ' + v, pos);
	}

	/**
	 * Rewrites a switch as an if/else chain, which is how a guard is expressed: cppia's switch has no
	 * guard slot, and a case whose guard fails must fall through to later cases rather than to the
	 * default.
	 *
	 * @param cond The switch subject.
	 * @param cases Its cases.
	 * @param defaultExpr Its default branch, if any.
	 * @param pos Where the switch appears.
	 * @return A block evaluating to the same branch the switch would have taken.
	 */
	function switchAsChain(cond:Expr, cases:Array<{values:Array<Expr>, expr:Expr, ?guard:Expr}>, defaultExpr:Null<Expr>, pos:Position):Expr {
		var name:String = tempName('sw');
		var ref:Expr = {e: EIdent(name), pos: pos};

		var chain:Expr = defaultExpr;
		var i:Int = cases.length - 1;
		while (i >= 0) {
			var c = cases[i];
			var capture:Null<String> = captureName(c);
			var pattern = destructure(c);

			var body:Expr = c.expr;
			var test:Expr = null;

			var shape:Null<{test:Expr, binds:Array<{name:String, value:Expr}>}> = shapeOf(c, ref, pos);

			if (shape != null) {
				var block:Array<Expr> = [];
				for (b in shape.binds)
					block.push({e: EVar(b.name, null, b.value, null, null, false), pos: pos});

				block.push(c.expr);

				body = {e: EBlock(block), pos: pos};
				test = shape.test;
			} else if (pattern != null) {
				var bound:Array<Expr> = [];
				for (b in 0...pattern.binds.length) {
					var bind:String = pattern.binds[b];
					if (bind == '_')
						continue;

					var params:Expr = {
						e: ECall({e: EField({e: EIdent('Type'), pos: pos}, 'enumParameters'), pos: pos}, [ref]),
						pos: pos
					};
					var element:Expr = {e: EArray(params, {e: EConst(CInt(b)), pos: pos}), pos: pos};
					bound.push({e: EVar(bind, null, element, null, null, false), pos: pos});
				}

				bound.push(c.expr);
				body = {e: EBlock(bound), pos: pos};

				var ctor:Expr = {
					e: ECall({e: EField({e: EIdent('Type'), pos: pos}, 'enumConstructor'), pos: pos}, [ref]),
					pos: pos
				};
				test = {e: EBinop('==', ctor, {e: EConst(CString(pattern.name)), pos: pos}), pos: pos};
			} else if (capture != null) {
				body = {
					e: EBlock([{e: EVar(capture, null, ref, null, null, false), pos: pos}, c.expr]),
					pos: pos
				};
				test = {e: EIdent('true'), pos: pos};
			} else {
				for (v in c.values) {
					// `case Blue:` on a scripted enum is a parameterless constructor, which cannot be
					// compared as a value: there is nothing named `Blue` to read. What identifies it is
					// its constructor name, the same way `case Red(n):` is identified.
					var eq:Expr = anyEnumCtor(v) ? {
						e: EBinop('==', {
							e: ECall({e: EField({e: EIdent('Type'), pos: pos}, 'enumConstructor'), pos: pos}, [ref]),
							pos: pos
						}, {e: EConst(CString(bareName(v))), pos: pos}),
						pos: pos
					} : {e: EBinop('==', ref, v), pos: pos};

					test = test == null ? eq : {e: EBinop('||', test, eq), pos: pos};
				}
				if (test == null)
					test = {e: EIdent('true'), pos: pos};
			}

			if (c.guard != null) {
				var guard:Expr = c.guard;

				if (shape != null) {
					// The guard runs before the body's declarations exist, so the names it uses are
					// written into it directly.
					for (b in shape.binds)
						guard = CppiaCapture.substitute(guard, b.name, b.value);
				} else if (capture != null) {
					guard = CppiaCapture.substitute(guard, capture, ref);
				} else if (pattern != null) {
					for (b in 0...pattern.binds.length) {
						var bind:String = pattern.binds[b];
						if (bind == '_')
							continue;

						var params:Expr = {
							e: ECall({e: EField({e: EIdent('Type'), pos: pos}, 'enumParameters'), pos: pos}, [ref]),
							pos: pos
						};
						guard = CppiaCapture.substitute(guard, bind, {e: EArray(params, {e: EConst(CInt(b)), pos: pos}), pos: pos});
					}
				}

				test = capture != null ? {e: EParent(guard), pos: pos} : {
					e: EBinop('&&', {e: EParent(test), pos: pos}, {e: EParent(guard), pos: pos}),
					pos: pos
				};
			}

			chain = {e: EIf(test, body, chain), pos: pos};
			i--;
		}

		return {
			e: EBlock([{e: EVar(name, null, cond, null, null, false), pos: pos}, chain]),
			pos: pos
		};
	}

	/**
	 * The enum pattern a case destructures, when it does.
	 *
	 * @param c The case to inspect.
	 * @return The constructor name and the names it binds, or null when the case is not a pattern.
	 */
	function destructure(c:{values:Array<Expr>, expr:Expr, ?guard:Expr}):Null<{name:String, binds:Array<String>}> {
		for (v in c.values) {
			switch (v.e) {
				case ECall(callee, args):
					var name:String = switch (callee.e) {
						case EIdent(n): n;
						case EField(_, n, _): n;
						case _: null;
					}
					if (name == null)
						return null;

					var binds:Array<String> = [];
					for (a in args) {
						switch (a.e) {
							case EIdent(bind): binds.push(bind);
							case _: return null;
						}
					}
					return {name: name, binds: binds};
				case _:
			}
		}
		return null;
	}

	/**
	 * The enum from this batch that declares a constructor of the given name.
	 *
	 * @param name The constructor name.
	 * @return Its enum's path, or null when no enum here declares it.
	 */
	function enumOwning(name:String):Null<String> {
		if (name == null || name.length == 0)
			return null;

		for (path in enumCtors.keys()) {
			if (isEnumCtor(path, name))
				return path;
		}

		return null;
	}

	/**
	 * Whether an expression names a constructor of some enum this batch declares.
	 *
	 * Any of them: a `case` gives no clue which enum is being matched, and two enums sharing a
	 * constructor name would answer the same either way.
	 *
	 * @param e The pattern.
	 * @return Whether it is a bare constructor name.
	 */
	function anyEnumCtor(e:Expr):Bool {
		return enumOwning(bareName(e)) != null;
	}

	/**
	 * @param e An expression.
	 * @return The identifier or trailing field name it writes, or the empty string.
	 */
	function bareName(e:Expr):String {
		return switch (e.e) {
			case EIdent(v): v;
			case EField(_, f, _): f;
			case EParent(inner): bareName(inner);
			case _: '';
		}
	}

	/**
	 * Reads a structure or array pattern out of a case, as a test and the bindings it makes.
	 *
	 * `case {n: v}` and `case [a, b]` describe a shape, which cppia's switch cannot express: it
	 * compares values. So they are lowered here into an ordinary condition and some declarations,
	 * and the chain the caller builds does the rest. A field is reached through `Reflect` because
	 * nothing about the matched value's type is known at this point.
	 *
	 * Nested patterns recurse, so `case {pos: [x, y]}` works; a name in a leaf position binds, and
	 * `_` matches without binding.
	 *
	 * @param c The case to read.
	 * @param ref The temporary holding the value being matched.
	 * @param pos Where the switch appears.
	 * @return The test and bindings, or null when the case is not a shape pattern.
	 */
	function shapeOf(c:{values:Array<Expr>, expr:Expr, ?guard:Expr}, ref:Expr,
			pos:Position):Null<{test:Expr, binds:Array<{name:String, value:Expr}>}> {
		for (v in c.values) {
			switch (v.e) {
				case EObject(_) | EArrayDecl(_):
					var binds:Array<{name:String, value:Expr}> = [];
					var test:Expr = matchShape(v, ref, binds, pos);
					return test == null ? null : {test: test, binds: binds};
				case _:
			}
		}

		return null;
	}

	/**
	 * Builds the condition that one pattern matches one value, collecting what it binds.
	 *
	 * @param pattern The pattern.
	 * @param value An expression for the value being tested against it.
	 * @param binds Names the pattern binds and where each reads from, appended to.
	 * @param pos Where the switch appears.
	 * @return The condition, or null when the pattern has a form this cannot express.
	 */
	function matchShape(pattern:Expr, value:Expr, binds:Array<{name:String, value:Expr}>, pos:Position):Null<Expr> {
		function and(a:Null<Expr>, b:Expr):Expr {
			return a == null ? b : {e: EBinop('&&', {e: EParent(a), pos: pos}, {e: EParent(b), pos: pos}), pos: pos};
		}

		switch (pattern.e) {
			case EObject(fields):
				var test:Null<Expr> = {
					e: ECall({e: EField({e: EIdent('Reflect'), pos: pos}, 'isObject'), pos: pos}, [value]),
					pos: pos
				};

				for (f in fields) {
					var read:Expr = {
						e: ECall({e: EField({e: EIdent('Reflect'), pos: pos}, 'field'), pos: pos},
							[value, {e: EConst(CString(f.name)), pos: pos}]),
						pos: pos
					};

					test = and(test, {
						e: ECall({e: EField({e: EIdent('Reflect'), pos: pos}, 'hasField'), pos: pos},
							[value, {e: EConst(CString(f.name)), pos: pos}]),
						pos: pos
					});

					var inner:Null<Expr> = matchShape(f.e, read, binds, pos);
					if (inner == null)
						return null;

					if (!inner.e.match(EIdent('true')))
						test = and(test, inner);
				}

				return test;

			case EArrayDecl(items):
				var length:Expr = {e: EField(value, 'length'), pos: pos};
				var test:Null<Expr> = {
					e: EBinop('==', length, {e: EConst(CInt(items.length)), pos: pos}),
					pos: pos
				};

				for (i in 0...items.length) {
					var element:Expr = {e: EArray(value, {e: EConst(CInt(i)), pos: pos}), pos: pos};

					var inner:Null<Expr> = matchShape(items[i], element, binds, pos);
					if (inner == null)
						return null;

					if (!inner.e.match(EIdent('true')))
						test = and(test, inner);
				}

				return test;

			case EIdent('_'):
				return {e: EIdent('true'), pos: pos};

			case EIdent(name) if (!hxscript.tools.Tools.isTypeIdentifier(name) && name != 'true' && name != 'false' && name != 'null'):
				// A lower-case name in a leaf position binds rather than compares. Kept as a pair
				// rather than a declaration, because a guard needs the value written into it and a
				// body needs it declared, and those want different shapes.
				binds.push({name: name, value: value});
				return {e: EIdent('true'), pos: pos};

			case EConst(_) | EIdent(_) | EField(_, _, _):
				return {e: EBinop('==', value, pattern), pos: pos};

			case _:
				return null;
		}
	}

	/**
	 * The name a case binds, when its pattern is a bare identifier rather than a value to match.
	 *
	 * hxscript treats any such identifier as a capture that always matches and rebinds, so it cannot
	 * be emitted as an equality test. `true`, `false` and `null` are literals, not captures.
	 *
	 * @param c The case to inspect.
	 * @return The bound name, or null when the case matches by value.
	 */
	function captureName(c:{values:Array<Expr>, expr:Expr, ?guard:Expr}):Null<String> {
		for (v in c.values) {
			switch (v.e) {
				case EIdent(name):
					if (name != 'true' && name != 'false' && name != 'null' && !typePaths.exists(name))
						return name;
				case _:
			}
		}
		return null;
	}

	/**
	 * Emits one catch clause. The loader picks the first whose declared type matches the thrown
	 * value, so an unannotated clause is written as `Dynamic` and catches everything.
	 *
	 * @param v The bound name.
	 * @param t Its declared type, if annotated.
	 * @param body The clause body.
	 */
	function emitCatch(v:String, t:Null<CType>, body:Expr):Void {
		pushScope();

		var declared:String = t == null ? '' : typeName(t);
		var id:Int = declareVar(v, declared);
		w.str(v);
		w.int(id);
		w.bool(false);
		w.type(declared);
		expr(body);

		popScope();
	}

	/**
	 * Wraps a `?.` access so the subject is evaluated once and only used when it is not null.
	 *
	 * @param obj The subject of the access.
	 * @param use Builds the access from the bound subject.
	 * @param pos Where the access appears.
	 * @return A block evaluating to the access, or to null.
	 */
	function nullSafe(obj:Expr, use:Expr->Expr, pos:Position):Expr {
		var name:String = tempName('safe');
		var ref:Expr = {e: EIdent(name), pos: pos};
		var isNull:Expr = {e: EBinop('==', ref, {e: EIdent('null'), pos: pos}), pos: pos};
		var guarded:Expr = {e: ETernary(isNull, {e: EIdent('null'), pos: pos}, use(ref)), pos: pos};

		return {
			e: EBlock([{e: EVar(name, null, obj, null, null, false), pos: pos}, guarded]),
			pos: pos
		};
	}

	/** A name no script can write, for a temporary the emitter introduces. */
	inline function tempName(prefix:String):String {
		return '`' + prefix + (nextVarId++);
	}

	/**
	 * Whether a lone array-literal element is a comprehension rather than a value.
	 *
	 * `[for (k in 0...5) k]` parses as an array literal holding one `EFor`, which is not the same
	 * shape as an array holding one value and must not be emitted as one. Parentheses and blocks are
	 * looked through because the parser keeps them.
	 *
	 * @param e The single element.
	 * @return Whether it drives a comprehension.
	 */
	function isComprehension(e:Expr):Bool {
		if (e == null)
			return false;

		return switch (e.e) {
			case EFor(_, _, _) | EForGen(_, _): true;
			case EParent(inner): isComprehension(inner);
			case EBlock(list): list.length > 0 && isComprehension(list[list.length - 1]);
			case _: false;
		}
	}

	/**
	 * Lowers a comprehension into a block that fills an array and yields it.
	 *
	 * Emitted as written, a comprehension becomes a one-element array whose element is a loop, which
	 * is why `[for (k in 0...5) k]` came out as `[0]`. What it means is an accumulator, so that is
	 * what it becomes:
	 *
	 *     { var tmp = []; for (k in 0...5) tmp.push(k); tmp; }
	 *
	 * The push goes at every position whose value the comprehension keeps, which is what makes a
	 * filtering `if` work without needing a value meaning "produced nothing": an `if` with no `else`
	 * simply has no push on the branch it does not take. The interpreter reaches the same answer by
	 * a different route, returning a void marker that its accumulator skips.
	 *
	 * The temporary is what the block yields, so it has to be the same kind of array the target
	 * asked for, which is what `temporaryArray` carries: it has no declaration of its own to take
	 * the type from.
	 *
	 * @param loop The comprehension's driving expression.
	 * @param want The array type the target asked for, if any.
	 * @param pos Where the literal appears.
	 * @return A block expression evaluating to the finished array.
	 */
	function comprehension(loop:Expr, want:Null<String>, pos:Position):Expr {
		var name:String = tempName('compr');
		var target:Expr = {e: EIdent(name), pos: pos};

		// `[for (k in ...) k => v]` fills a map and `[for (k in ...) v]` fills an array, and the two
		// are told apart the same way a plain literal is: by whether the first thing it yields is a
		// `=>` pair. The accumulator differs, the rewriting does not.
		var pairKey:Null<Expr> = yieldedPair(loop);
		var empty:Expr;

		if (pairKey != null) {
			var mapClass:String = switch (pairKey.e) {
				case EConst(CString(_, _)): 'haxe.ds.StringMap';
				case EConst(CInt(_)): 'haxe.ds.IntMap';
				case _: 'hxscript.runtime.AnyMap';
			}

			empty = {e: ENew(mapClass, []), pos: pos};
			temporaryArray = null;
		} else {
			empty = {e: EArrayDecl([]), pos: pos};
			temporaryArray = want;
		}

		expectedArray = null;

		var filled:Expr = accumulate(loop, target);

		return {
			e: EBlock([{e: EVar(name, null, empty, null, null, false), pos: pos}, filled, target]),
			pos: pos
		};
	}

	/**
	 * The key of the first `key => value` a comprehension yields, or null when it yields plain values.
	 *
	 * Only the shape is wanted, not the key itself, except that a literal key says which map to
	 * build -- the same reading a plain map literal gets. Looked for down the same positions
	 * `accumulate` rewrites, since those are the ones whose value the comprehension keeps.
	 *
	 * @param e The comprehension body or a part of it.
	 * @return The first pair's key expression, or null.
	 */
	function yieldedPair(e:Expr):Null<Expr> {
		if (e == null)
			return null;

		return switch (e.e) {
			case EBinop('=>', key, _): key;
			case EParent(inner): yieldedPair(inner);
			case EBlock(list): list.length == 0 ? null : yieldedPair(list[list.length - 1]);
			case EFor(_, _, body): yieldedPair(body);
			case EForGen(_, body): yieldedPair(body);
			case EIf(_, then, otherwise):
				var found:Null<Expr> = yieldedPair(then);
				found != null ? found : (otherwise == null ? null : yieldedPair(otherwise));
			case _: null;
		}
	}

	/**
	 * Rewrites a comprehension's body so every value it yields is pushed onto `target`.
	 *
	 * Only the positions whose value the comprehension keeps are rewritten. In a block that is the
	 * last expression and nothing before it; in a loop it is the body, so nesting accumulates into
	 * the same container; in an `if` it is each branch that exists.
	 *
	 * A `key => value` becomes a `set` rather than a `push`, which is what makes the map form work:
	 * the caller has already built `target` as a map when that is what the body yields.
	 *
	 * @param e The expression to rewrite.
	 * @param target The array being filled.
	 * @return The rewritten expression.
	 */
	function accumulate(e:Expr, target:Expr):Expr {
		if (e == null)
			return null;

		var pos:Position = e.pos;

		return switch (e.e) {
			case EParent(inner):
				{e: EParent(accumulate(inner, target)), pos: pos};

			case EBlock(list):
				if (list.length == 0) {
					e;
				} else {
					var out:Array<Expr> = list.slice(0, list.length - 1);
					out.push(accumulate(list[list.length - 1], target));
					{e: EBlock(out), pos: pos};
				}

			case EFor(v, it, body):
				{e: EFor(v, it, accumulate(body, target)), pos: pos};

			case EForGen(it, body):
				{e: EForGen(it, accumulate(body, target)), pos: pos};

			case EIf(cond, then, otherwise):
				{
					e: EIf(cond, accumulate(then, target), otherwise == null ? null : accumulate(otherwise, target)),
					pos: pos
				};

			case EBinop('=>', key, value):
				{e: ECall({e: EField(target, 'set'), pos: pos}, [key, value]), pos: pos};

			case _:
				{e: ECall({e: EField(target, 'push'), pos: pos}, [e]), pos: pos};
		}
	}

	/**
	 * Lowers a map literal into a block that builds the map and yields it.
	 *
	 * The concrete map is chosen from the key literals, falling back to `AnyMap`, which decides from
	 * the first key at runtime, when they are not all one kind.
	 *
	 * @param items The `key => value` entries.
	 * @param pos Where the literal appears.
	 * @return A block expression evaluating to the map.
	 */
	function mapLiteral(items:Array<Expr>, pos:Position):Expr {
		var allString:Bool = true;
		var allInt:Bool = true;

		for (item in items) {
			switch (item.e) {
				case EBinop('=>', key, _):
					switch (key.e) {
						case EConst(CString(_, _)): allInt = false;
						case EConst(CInt(_)): allString = false;
						case _:
							allString = false;
							allInt = false;
					}
				case _:
					throw new CppiaUnsupported('mixed array and map literal', pos);
			}
		}

		var mapClass:String = allString ? 'haxe.ds.StringMap' : (allInt ? 'haxe.ds.IntMap' : 'hxscript.runtime.AnyMap');

		var name:String = tempName('map');
		var target:Expr = {e: EIdent(name), pos: pos};
		var block:Array<Expr> = [
			{e: EVar(name, null, {e: ENew(mapClass, []), pos: pos}, null, null, false), pos: pos}
		];

		for (item in items) {
			switch (item.e) {
				case EBinop('=>', key, value):
					block.push({e: ECall({e: EField(target, 'set'), pos: pos}, [key, value]), pos: pos});
				case _:
			}
		}

		block.push(target);
		return {e: EBlock(block), pos: pos};
	}

	/**
	 * Lowers `for (k => v in it)` into a loop over the subject's key-value iterator.
	 *
	 * @param it The `k => v in subject` expression the parser produced.
	 * @param body The loop body.
	 * @param pos Where the loop appears.
	 * @return An equivalent plain `for` loop.
	 */
	function keyValueLoop(it:Expr, body:Expr, pos:Position):Expr {
		var key:String = null;
		var value:String = null;
		var subject:Expr = null;

		switch (it.e) {
			case EBinop('in', pair, iterable):
				switch (pair.e) {
					case EBinop('=>', k, v):
						switch [k.e, v.e] {
							case [EIdent(kn), EIdent(vn)]:
								key = kn;
								value = vn;
								subject = iterable;
							case _:
						}
					case _:
				}
			case _:
		}

		if (key == null)
			throw new CppiaUnsupported('key-value for loop', pos);

		var pairName:String = tempName('kv');
		var pairRef:Expr = {e: EIdent(pairName), pos: pos};

		var inner:Array<Expr> = [
			{e: EVar(key, null, {e: EField(pairRef, 'key'), pos: pos}, null, null, false), pos: pos},
			{e: EVar(value, null, {e: EField(pairRef, 'value'), pos: pos}, null, null, false), pos: pos},
			body
		];

		var iterator:Expr = {e: ECall({e: EField(subject, 'keyValueIterator'), pos: pos}, []), pos: pos};
		return {e: EFor(pairName, iterator, {e: EBlock(inner), pos: pos}), pos: pos};
	}

	/**
	 * Maps a property accessor to the cppia access code for it.
	 *
	 * Accessors are written as `V` rather than `C`. Both make the loader resolve `get_<name>` or
	 * `set_<name>` at link time, but only `V` also registers the field as a native property, and a
	 * by-name access -- which is how this emitter reads fields -- consults the accessor only for
	 * those. With `C` the read would silently return the storage slot instead.
	 *
	 * @param mode The accessor as written, or null for a plain field.
	 * @param pos Where the field is declared.
	 * @return The one-character access code.
	 */
	function accessCode(mode:Null<String>, pos:Position):String {
		return switch (mode) {
			case null | 'default' | 'null': 'N';
			case 'get' | 'set' | 'dynamic': 'V';
			case 'never': 'n';
			case _: throw new CppiaUnsupported('property accessor ' + mode, pos);
		}
	}

	/**
	 * The `class.field` of the static property an assignment targets, when it targets one.
	 *
	 * @param target The left side of the assignment.
	 * @return The qualified field, or null when the target is not a static property.
	 */
	function staticSetterFor(target:Expr):Null<String> {
		switch (target.e) {
			case EField(obj, name, _):
				var owner:Null<String> = typeOf(obj);
				if (owner == null)
					return null;
				var key:String = owner + '.' + name;
				return staticSetters.exists(key) ? key : null;

			case EIdent(name):
				if (lookupVar(name) != null || !statics.exists(name))
					return null;
				var key:String = currentClass + '.' + name;
				return staticSetters.exists(key) ? key : null;

			case _:
				return null;
		}
	}

	/**
	 * Writes the declared type of a variable slot.
	 *
	 * A slot is only ever stored as bool, int, float, string or object, and everything that is not
	 * one of the first four is an object -- so naming the exact class buys nothing, while naming one
	 * the loader cannot resolve leaves the slot with no store type at all and drops it to untyped
	 * access. Only the types that change the storage are written; the rest are `Dynamic`.
	 *
	 * @param path The declared type, or the empty string when there was none.
	 */
	function storableType(path:String):Void {
		if (path == null || path.length == 0) {
			w.unknownType();
			return;
		}

		// An abstract is not a runtime type: a slot declared as one holds what it boxes. Typing the
		// slot as the abstract instead leaves an Int slot expecting an object, and the value read
		// back is not the value written.
		var boxes:Null<String> = underlyingOf(path);
		if (boxes != null) {
			storableType(boxes);
			return;
		}

		switch (path) {
			case 'Int' | 'Float' | 'Bool' | 'String':
				w.type(path);
			case _:
				if (path.length >= 5 && path.substr(0, 5) == 'Array') {
					w.type(path);
					return;
				}

				var full:Null<String> = declaredClass(path);
				if (full != null)
					w.type(full);
				else
					w.unknownType();
		}
	}

	/**
	 * Whether an assignment target is a field on something the host owns.
	 *
	 * Only a field access qualifies, and only when its object cannot be shown to be a class from this
	 * batch: those have a known layout and are reached by offset. Everything else may be a property,
	 * and there is no way to tell from here which, so both are handled the one way that works for
	 * either.
	 *
	 * `this` is excluded because a scripted class's own fields are its own, whatever it extends.
	 *
	 * @param e The assignment target.
	 * @return Whether it needs property access.
	 */
	function hostField(e:Expr):Bool {
		switch (e.e) {
			case EField(obj, name, _):
				// A type on the left is a static, which has its own form and is not this question.
				if (typeOf(obj) != null) {
					return false;
				}

				// The same test the read side makes, and it has to be the same test: a read that goes
				// one way and a write that goes the other produces an assignment to a call, which the
				// loader rejects for the whole module. Belonging to a class from this batch is not
				// enough -- the field must be one that class declares, because a scripted class also
				// carries everything its host superclass has, and those are reached like any other
				// host field.
				var holder:Null<String> = obj.e.match(EIdent('this')) ? currentClass : instanceClassOf(obj);
				return holder == null || instanceVar(holder, name) == null;

			case _:
				return false;
		}
	}

	/** An array type carrying an element kind, or null for anything else. */
	/** The element type of an array type, or null when it is not a written array type. */
	static function arrayElemOf(t:Null<CType>):Null<CType> {
		if (t == null)
			return null;
		switch (t) {
			case CTPath(path, params):
				return (path.join('.') == 'Array' && params != null && params.length == 1) ? params[0] : null;
			case CTParent(inner) | CTOpt(inner) | CTNamed(_, inner):
				return arrayElemOf(inner);
			case _:
				return null;
		}
	}

	static function elementArray(name:Null<String>):Null<String> {
		return (name != null && name.length > 6 && name.substr(0, 6) == 'Array.') ? name : null;
	}

	/** Whether an accessor keyword leaves a field as ordinary storage. */
	static function plainAccess(access:String):Bool {
		return access == null || access == 'default' || access == 'null' || access == 'never';
	}

	/**
	 * The declared type of a plain instance variable, or null when the class has no such field.
	 *
	 * @param owner Full path of the class holding it.
	 * @param field The field name.
	 * @return Its declared type, the empty string when it had none, or null when it is not a plain
	 *         variable of that class.
	 */
	function instanceVar(owner:String, field:String):Null<String> {
		var vars:Null<StringMap<String>> = classVars.get(owner);
		return vars == null ? null : vars.get(field);
	}

	/** The class an expression is known to be an instance of, or null. */
	function instanceClassOf(e:Expr):Null<String> {
		var named:Null<String> = inferType(e);
		return named == null ? null : declaredClass(named);
	}

	/**
	 * How many arguments a host class's constructor declares.
	 *
	 * Read from the type table, which the build's own macro fills. Reflection cannot answer this: a
	 * constructor is not a field, and nothing at runtime carries its signature.
	 *
	 * @param path The host class's full path.
	 * @return Its declared argument count, 0 for a class with no constructor of its own, or -1 when
	 *         the table has nothing to say and the call therefore cannot be padded safely.
	 */
	function hostConstructorArity(path:String):Int {
		var infos:Array<hxscript.types.TypeCollection.TypeInfo> = hxscript.types.TypeCollection.main.fromCompilePath(path);
		if (infos == null || infos.length == 0)
			infos = hxscript.types.TypeCollection.main.fromPath(path);
		if (infos == null || infos.length == 0)
			return -1;

		var info = infos[0];
		if (info.ctorArgs == null)
			return info.kind == 'class' ? 0 : -1;

		return info.ctorArgs;
	}

	/**
	 * What an abstract from this batch boxes, given the type name as written.
	 *
	 * @param path The declared type name or path.
	 * @return The underlying type's spelling, or null when this is not an abstract of ours or it
	 *         declared no underlying type.
	 */
	function underlyingOf(path:String):Null<String> {
		var full:Null<String> = declaredClass(path);
		if (full == null)
			full = path;

		var boxes:Null<String> = moduleAbstracts.get(full);
		return (boxes == null || boxes.length == 0) ? null : boxes;
	}

	/**
	 * Remembers that a local holds an array of one of this batch's abstracts.
	 *
	 * The erased spelling cannot carry it: `Array<Meters>` becomes `Array.int`, which is right for
	 * storage and useless for working out what `a[0].big()` is called on.
	 *
	 * @param name The local's name.
	 * @param t Its declared type, if it had one.
	 */
	function noteArrayElement(name:String, t:Null<CType>):Void {
		if (t == null)
			return;

		switch (t) {
			case CTPath(['Array'], params) if (params != null && params.length == 1):
				switch (params[0]) {
					case CTPath(path, _):
						var full:Null<String> = abstractPathOf(path.join('.'));
						if (full != null)
							arrayElements.set(name, full);
					case _:
				}
			case _:
		}
	}

	/**
	 * The name a simple expression reads a local through, for looking that local up.
	 *
	 * @param e The expression.
	 * @return Its identifier, or the empty string when it is not one.
	 */
	function varNameOf(e:Expr):String {
		return switch (e.e) {
			case EIdent(v): v;
			case EParent(inner): varNameOf(inner);
			case _: '';
		}
	}

	/**
	 * The array spelling for an element type already resolved to its own spelling.
	 *
	 * @param element The element type's name.
	 * @return The cppia array spelling.
	 */
	function arraySpelling(element:String):String {
		return switch (element) {
			case 'Int': 'Array.int';
			case 'Bool': 'Array.bool';
			case 'Float': 'Array.Float';
			case 'String': 'Array.String';
			case 'Dynamic' | 'Any': 'Array';
			case _: 'Array.Object';
		}
	}

	/**
	 * The abstract a written type name refers to, when it is one from this batch.
	 *
	 * @param name The type name as written.
	 * @return Its full path, or null when it names something else.
	 */
	function abstractPathOf(name:String):Null<String> {
		var full:Null<String> = declaredClass(name);
		if (full == null)
			full = name;

		return moduleAbstracts.exists(full) ? full : null;
	}

	/**
	 * The abstract an expression's declared type names, when it is one from this batch.
	 *
	 * @param e The expression whose type to read.
	 * @return The abstract's path, or null when the value is not one.
	 */
	function abstractTypeOf(e:Expr):Null<String> {
		var declared:Null<String> = instanceClassOf(e);
		if (declared == null)
			declared = typeOf(e);
		if (declared == null)
			return null;

		var full:Null<String> = declaredClass(declared);
		if (full == null)
			full = declared;

		return moduleAbstracts.exists(full) ? full : null;
	}

	/**
	 * Resolves a name to a class this batch declares.
	 *
	 * Worth resolving because the alternative is `Dynamic`, and `Dynamic` decides how every later
	 * access to the value is performed: a field read becomes a lookup by name at runtime rather than
	 * a known offset, and so does every method call. For a value touched once that is nothing; for
	 * one touched per column or per frame it is the difference between a renderer that keeps up and
	 * one that does not.
	 *
	 * Only classes declared here qualify. A host class would have to be resolved through the glue,
	 * and one that turned out not to be there would fail to link and take the whole module with it.
	 *
	 * @param path A full path or a short name.
	 * @return The full path, or null when the batch declares no such class.
	 */
	function declaredClass(path:String):Null<String> {
		if (moduleClasses.exists(path))
			return path;

		var full:Null<String> = typePaths.get(path);
		return (full != null && moduleClasses.exists(full)) ? full : null;
	}

	/**
	 * Writes a type reference, noting it when it names a class from this batch.
	 *
	 * A reference to a class that ends up refused cannot link, and the loader rejects the WHOLE
	 * module for it, so the caller needs to know which of its own classes a module leans on.
	 *
	 * @param path The type being referenced.
	 */
	function useType(path:String):Void {
		if (moduleClasses.exists(path)) {
			if (refs.indexOf(path) < 0)
				refs.push(path);
		} else if (external.exists(path)) {
			throw new CppiaUnsupported('uses $path, which is compiled elsewhere', null);
		}

		w.type(path);
	}

	/**
	 * Registers scripted classes the host has elsewhere, which this batch cannot reach.
	 *
	 * cppia resolves a class either inside the module being loaded or as a host class. A scripted
	 * class living in another module is neither, so naming one produces a reference that fails to
	 * link and rejects the whole batch. Refusing here keeps the module interpreted instead.
	 *
	 * @param paths Full paths of those classes.
	 */
	public function externals(paths:Array<String>):Void {
		for (path in paths)
			external.set(path, true);
	}

	/**
	 * Registers bare names the host answers with a static of its own.
	 *
	 * A host may hand scripts a name that is neither a local, a field, nor a type -- a helper it
	 * injects into every interpreter. Compiled code has no interpreter to inject into, so the name
	 * has to be reached where it really lives.
	 *
	 * @param entries Each written `name=owner.path::field`.
	 */
	public function ambientStatics(entries:Array<String>):Void {
		for (entry in entries) {
			var equals:Int = entry.indexOf('=');
			if (equals < 0)
				continue;

			var target:String = entry.substr(equals + 1);
			if (target.indexOf('::') < 0)
				continue;

			ambientMembers.set(entry.substr(0, equals), target);
		}
	}

	/**
	 * Emits a read of a host-supplied bare name.
	 *
	 * @param name The bare name.
	 * @param pos Where it appears.
	 * @return Whether it was one, and has been emitted.
	 */
	function emitAmbient(name:String, pos:Position):Bool {
		var target:Null<String> = ambientMembers.get(name);
		if (target == null)
			return false;

		var split:Int = target.indexOf('::');
		w.pos(pos == null ? 0 : pos.line);
		w.token('FSTATIC');
		w.type(target.substr(0, split));
		w.str(target.substr(split + 2));
		return true;
	}

	/** Whether a field target can be evaluated twice, which the long-hand rewrite needs. */
	function repeatableField(e:Expr):Bool {
		switch (e.e) {
			case EField(obj, _, maybe):
				if (maybe == true || obj.e.match(EIdent('this'))) {
					return false;
				}
				return sideEffectFree(obj);

			case _:
				return false;
		}
	}

	/** Whether an expression can be evaluated again without changing anything. */
	function sideEffectFree(e:Expr):Bool {
		switch (e.e) {
			case EIdent(_):
				return true;

			case EConst(_):
				return true;

			case EField(obj, _, maybe):
				return maybe != true && sideEffectFree(obj);

			case EParent(inner):
				return sideEffectFree(inner);

			case _:
				return false;
		}
	}

	/** Turns a discarded `a.b++` into an assignment; only valid where the result is unused. */
	function discardedIncrement(e:Expr):Expr {
		switch (e.e) {
			case EUnop(op, _, inner) if ((op == '++' || op == '--') && repeatableField(inner)):
				var one:Expr = {e: EConst(CInt(1)), pos: e.pos};
				var sum:Expr = {e: EBinop(op == '++' ? '+' : '-', inner, one), pos: e.pos};
				return {e: EBinop('=', inner, sum), pos: e.pos};

			case _:
				return e;
		}
	}

	/** Classes from this batch that the emitted code names. */
	public function references():Array<String> {
		return refs;
	}

	/** Whether a name is a constructor of an enum this batch declares. */
	function isEnumCtor(path:String, name:String):Bool {
		var ctors:Null<StringMap<Bool>> = enumCtors.get(path);
		return ctors != null && ctors.exists(name);
	}

	/** The type an expression names, when it names one rather than producing a value. */
	function typeOf(e:Expr):Null<String> {
		switch (e.e) {
			case EIdent(v):
				if (lookupVar(v) != null || members.exists(v) || statics.exists(v))
					return null;
				if (typePaths.exists(v))
					return typePaths.get(v);
				return null;

			case EField(_, _, _):
				var path:Null<String> = dottedPath(e);
				if (path != null && moduleClasses.exists(path))
					return path;
				return null;

			case _:
				return null;
		}
	}

	/** The dotted name a field-access chain spells, or null if anything in it is not a plain name. */
	function dottedPath(e:Expr):Null<String> {
		switch (e.e) {
			case EIdent(v):
				return v;
			case EField(obj, f, maybe):
				if (maybe == true)
					return null;
				var head:Null<String> = dottedPath(obj);
				return head == null ? null : head + '.' + f;
			case _:
				return null;
		}
	}

	/**
	 * Resolves a written type name to the full path the loader will link against.
	 *
	 * @param name The name as written.
	 * @param pos Where it appears.
	 * @return Its full path.
	 * @throws CppiaUnsupported If nothing of that name can be found.
	 */
	function resolveType(name:String, pos:Position):String {
		if (typePaths.exists(name))
			return typePaths.get(name);
		if (name.indexOf('.') >= 0)
			return name;
		throw new CppiaUnsupported('unresolved type ' + name, pos);
	}

	/** The dotted path a type annotation names, or the empty string when it is not a plain path. */
	function typeName(t:CType):String {
		switch (t) {
			case CTPath(path, params):
				var joined:String = path.join('.');
				if (joined == 'Array')
					return arrayTypeName(params);
				if (path.length == 1 && typePaths.exists(joined))
					return typePaths.get(joined);
				return joined;
			case CTParent(inner):
				return typeName(inner);
			case CTOpt(inner):
				return typeName(inner);
			case CTNamed(_, inner):
				return typeName(inner);
			case _:
				return '';
		}
	}

	/**
	 * Spells an array type the way cppia names its specialisations, so element access reaches the
	 * typed builtin instead of the boxed one.
	 *
	 * Only the suffixes the loader knows may be produced; it throws on any other, so an element type
	 * it has no spelling for becomes `Array.Object`.
	 *
	 * @param params The array's type parameters, if written.
	 * @return The cppia type name.
	 */
	/** The cppia spelling for a written array type, or null when it is not one. */
	function arrayNameOf(t:Null<CType>):Null<String> {
		if (t == null)
			return null;
		switch (t) {
			case CTPath(path, params):
				return path.join('.') == 'Array' ? arrayTypeName(params) : null;
			case CTParent(inner) | CTOpt(inner) | CTNamed(_, inner):
				return arrayNameOf(inner);
			case _:
				return null;
		}
	}

	function arrayTypeName(params:Null<Array<CType>>):String {
		if (params == null || params.length != 1)
			return 'Array';

		// An array of an abstract is an array of what that abstract boxes, since a value of one IS
		// its underlying value. Reading the spelling off the abstract keeps `Array<Meters>` a real
		// `Array.int` rather than an array of objects that never holds one.
		switch (params[0]) {
			case CTPath(path, _):
				var boxes:Null<String> = underlyingOf(path.join('.'));
				if (boxes != null)
					return arraySpelling(boxes);
			case _:
		}

		return switch (params[0]) {
			case CTPath(['Int'], _): 'Array.int';
			case CTPath(['Bool'], _): 'Array.bool';
			case CTPath(['Float'], _): 'Array.Float';
			case CTPath(['String'], _): 'Array.String';
			case CTPath(['Dynamic'], _) | CTPath(['Any'], _): 'Array';
			case _: 'Array.Object';
		}
	}

	/**
	 * @param f The field.
	 * @param a The keyword to look for.
	 * @return Whether the field was declared with it.
	 */
	inline function hasAccess(f:FieldDecl, a:FieldAccess):Bool {
		return f.access.indexOf(a) >= 0;
	}

	/** Opens a scope. Locals declared from here are dropped when it closes. */
	inline function pushScope():Void {
		scopes.push(new StringMap());
		scopeTypes.push(new StringMap());
	}

	/** Closes the innermost scope. */
	inline function popScope():Void {
		scopes.pop();
		scopeTypes.pop();
	}

	/**
	 * Binds a name to a fresh variable id.
	 *
	 * @param name The variable name.
	 * @param type Its declared type, if annotated.
	 * @return The variable id.
	 */
	function declareVar(name:String, ?type:String):Int {
		var id:Int = nextVarId++;
		if (scopes.length == 0)
			pushScope();
		scopes[scopes.length - 1].set(name, id);
		if (type != null && type.length > 0)
			scopeTypes[scopeTypes.length - 1].set(name, type);
		return id;
	}

	/** The declared type of a local, or null when it had none. */
	function lookupVarType(name:String):Null<String> {
		var i:Int = scopeTypes.length - 1;
		while (i >= 0) {
			var found:Null<String> = scopeTypes[i].get(name);
			if (found != null)
				return found;
			i--;
		}
		return null;
	}

	/**
	 * The type an expression is known to produce, used to pick a specialised cppia form.
	 *
	 * @param e The expression.
	 * @return Its type path, or null when not known.
	 */
	function inferType(e:Expr):Null<String> {
		switch (e.e) {
			case EIdent(v):
				if (lookupVar(v) != null)
					return lookupVarType(v);
				if (members.exists(v))
					return memberTypes.get(v);
				if (statics.exists(v))
					return staticTypes.get(v);
				return null;

			case EParent(inner):
				return inferType(inner);

			case EField(obj, f, _):
				var owner:Null<String> = typeOf(obj);
				if (owner != null && owner == currentClass)
					return staticTypes.get(f);

				var holder:Null<String> = (obj.e.match(EIdent('this'))) ? currentClass : instanceClassOf(obj);
				if (holder != null) {
					var declared:Null<String> = instanceVar(holder, f);
					if (declared != null && declared.length > 0)
						return declared;
				}
				return null;

			case ENew(cl, _):
				return typePaths.exists(cl) ? typePaths.get(cl) : null;

			case EArray(arr, _):
				// The element type of an array of abstracts, which the erased spelling cannot carry.
				var named:Null<String> = arrayElements.get(varNameOf(arr));
				return named;

			case ECall(callee, _):
				switch (callee.e) {
					case EField(obj, name, _):
						// The owner is whatever the receiver is: an abstract routes to its
						// implementation, anything else to its own class.
						var owner:Null<String> = abstractTypeOf(obj);
						if (owner == null)
							owner = (obj.e.match(EIdent('this'))) ? currentClass : instanceClassOf(obj);
						if (owner == null)
							owner = typeOf(obj);
						if (owner == null)
							return null;

						var rets:Null<StringMap<String>> = methodReturns.get(owner);
						return rets == null ? null : rets.get(name);

					case EIdent(name):
						var rets:Null<StringMap<String>> = methodReturns.get(currentClass);
						return rets == null ? null : rets.get(name);

					case _:
						return null;
				}

			case _:
				return null;
		}
	}

	/**
	 * Finds a local by name, innermost scope first.
	 *
	 * @param name The local's name.
	 * @return Its slot id, or null when no scope in range declares it.
	 */
	function lookupVar(name:String):Null<Int> {
		var i:Int = scopes.length - 1;
		while (i >= 0) {
			var found:Null<Int> = scopes[i].get(name);
			if (found != null)
				return found;
			i--;
		}
		return null;
	}
}
#end
