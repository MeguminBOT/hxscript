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

package hxscript.cppia;

import hxscript.compile.Unsupported;

#if hxscript_cppia
import hxscript.compile.Capture;
import hxscript.compile.Accessors;
import hxscript.Config;
import haxe.ds.StringMap;
import haxe.io.Bytes;
import hxscript.syntax.Expr;

/**
 * Turns hxscript's syntax tree into a cppia module.
 */
class Emitter {
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
	static var ASSIGN_OPS:Array<String> = ['+=', '-=', '*=', '/=', '%=', '&=', '|=', '^=', '<<=', '>>=', '>>>='];

	/** Operators that produce a `Bool` whatever they were given. */
	static var COMPARISONS:Array<String> = ['==', '!=', '>=', '<=', '>', '<', '&&', '||'];

	/** The token stream being built. */
	var w:Writer;

	/** How many classes have been written, which the module header has to declare up front. */
	var classCount:Int;

	/** Next free local slot. Slots are numbered across the whole module, not per function. */
	var nextVarId:Int;

	/** Local slots by name, innermost scope last. */
	var scopes:Array<StringMap<Int>>;

	/** The declared type of each local, in step with `scopes`. */
	var scopeTypes:Array<StringMap<String>>;

	/**
	 * The type each local was WRITTEN as, in step with `scopes`, whatever its slot ended up holding.
	 *
	 * `scopeTypes` is what the emitted slot may be specialised to, and an argument the caller can
	 * leave off is deliberately not in it: a cppia `Int` slot reads a padded call's null as 0, so an
	 * optional keeps an untyped slot. That loses the annotation for everything else that wanted to
	 * READ it, and placing a short `super(...)` is exactly that: `?held:HostShaped` says which
	 * parameter the argument was meant for, and the slot table had thrown the answer away.
	 */
	var scopeWritten:Array<StringMap<String>>;

	/** Full path for each short type name in view, from imports, declarations and ambient types. */
	var typePaths:StringMap<String>;

	/** How many typedef hops to follow before giving up, so a cycle cannot spin. */
	static inline var TYPEDEF_DEPTH:Int = 8;

	/** How far up an extends chain to look before giving up on it. */
	static inline var SUPER_DEPTH:Int = 32;

	/** Paths this batch declares, which can be linked directly rather than resolved as host types. */
	var moduleClasses:StringMap<Bool>;

	/**
	 * Plain instance variables of every class in the batch, by class path then field name, holding each
	 * field's declared type or the empty string when it had none.
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
	 */
	var moduleAbstracts:StringMap<String> = new StringMap();

	/**
	 * The method serving each operator on one of this batch's abstracts, keyed `path op`.
	 *
	 * Without it an overloaded operator lowers to the arithmetic its underlying type happens to
	 * support, which silently agrees with the declared body whenever the body IS that arithmetic and
	 * silently disagrees the moment it is not.
	 */
	var abstractOps:StringMap<String> = new StringMap();

	/** What `nativeAbstract` has answered, misses included, so a repeat costs a map read. */
	var wrappers:StringMap<Class<Dynamic>> = new StringMap();

	/** What `resolvable` has answered, so a repeated reference costs a map read. */
	var resolvedTypes:StringMap<Bool> = new StringMap();

	/** What `worldType` has answered, misses written as the empty string, so a repeat costs a map read. */
	var worldTypes:StringMap<String> = new StringMap();

	/**
	 * Set while an assignment's target is being written, and cleared by whatever consumes it.
	 *
	 * A `Bool` field is read back through a comparison, which is not what the left of an assignment
	 * wants: there the field itself has to be named.
	 */
	var writingTo:Bool = false;

	/** Statics a `using` in this module puts in scope, by member name, to the type declaring them. */
	var usingStatics:StringMap<String> = new StringMap();

	/** Every `using` type declaring a given member name, in declaration order. */
	var usingOwners:StringMap<Array<String>> = new StringMap();

	/** Every member of the current class's host base, or null when reflection could not list them. */
	var inherited:StringMap<Bool> = null;

	/** Which base `inherited` was built for, so a class per batch does not rebuild it per name. */
	var inheritedFrom:String = null;

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
	 * How many arguments a batch type's methods declare, by `owner method`.
	 *
	 * A cppia call links by arity, so leaving an optional off is not a shorter call, it is a call to
	 * nothing and the loader raises `Arg count error`. The interpreter fills the gap with null, and
	 * so does the emitter now, which is why the count has to be known here.
	 */
	var methodArity:StringMap<Int> = new StringMap();

	/**
	 * How many arguments the current class's host superclass constructor declares, or -1 when the
	 * superclass is in this batch and needs no padding.
	 */
	var superArgs:Int = -1;

	/**
	 * The element type to give the next temporary this emitter introduces.
	 */
	var temporaryArray:Null<String> = null;

	/** Full path of the class being written. */
	var currentClass:String;

	/** Its superclass's path, or the empty string when it has none. */
	var currentSuper:String;

	/** The method being emitted, so a property accessor can reach its own field directly. */
	var currentMethod:String = '';

	/** `class field` of each member declared as a property, to whether it has a real slot behind it. */
	var props:StringMap<Bool> = new StringMap();

	/** `class field` of each member property whose writes go through a setter method. */
	var propSetters:StringMap<Bool> = new StringMap();

	/** `class field` of each member written `var x(null, ...)`, which only its own instance may read. */
	var restrictedFields:StringMap<Bool> = new StringMap();

	/** The bare names of those members, for a read whose receiver this cannot name. */
	var restrictedNames:StringMap<Bool> = new StringMap();

	/** Whether the member initialisers are being emitted, which assign the field rather than call the setter. */
	var emittingInits:Bool = false;

	/** Whether the method being emitted was declared to return `Bool`, which cppia cannot carry as one. */
	var returnsBool:Bool = false;

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
	 * Bare names an import bound to a field of the type it named, as the owning type's path.
	 *
	 * `import HostFlag;` puts `Add` in scope as well as `HostFlag`, and `import haxe.ds.Option;` puts
	 * `None` in scope: an enum's constructors and an enum abstract's constants are reachable
	 * unqualified once their type is imported, which is what the interpreter's own import table
	 * records and what this one did not.
	 */
	var importedFields:StringMap<String>;

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
		w = new Writer();
		classCount = 0;
		nextVarId = 1;
		scopes = [];
		scopeTypes = [];
		scopeWritten = [];
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
		importedFields = new StringMap();
		currentClass = '';
		currentSuper = '';

		for (name in BUILTIN_TYPES)
			typePaths.set(name, name);

		typePaths.set(ENUMS, 'hxscript.proxy.TypeProxy');
	}

	/**
	 * The name a desugared enum switch reads its reflection helpers through.
	 *
	 * `Type.enumConstructor` is an unchecked cast on hxcpp, so compiled code that reached it with a
	 * value the INTERPRETER built ended the process rather than reporting anything. That happens
	 * whenever only part of a world is compiled, which is the arrangement partial substitution
	 * exists for. `TypeProxy` answers for both forms, and the leading `@` keeps the name out of
	 * reach of a script, which cannot write it.
	 */
	static inline var ENUMS:String = '@enums';

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
						case KFunction(fn):
							recordArity(owner, m.name, fn);
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
					recordImport(path, switch (mode) {
						case IAsName(alias): alias;
						case _: path[path.length - 1];
					});
				case DClass(c) | DInterface(c):
					var full:String = pack.length > 0 ? pack + '.' + c.name : c.name;
					typePaths.set(c.name, full);
					moduleClasses.set(full, true);

					var vars:StringMap<String> = new StringMap();
					for (f in c.fields) {
						if (hasAccess(f, AStatic))
							continue;
						switch (f.kind) {
							case KVar(v) if (v.get == 'null'):
								restrictedFields.set(full + ' ' + f.name, true);
								restrictedNames.set(f.name, true);
							case _:
						}

						switch (f.kind) {
							case KVar(v) if (plainAccess(v.get) && plainAccess(v.set)):
								vars.set(f.name, v.type == null ? '' : typeName(v.type));

							case KVar(v):
								var backed:Bool = physicalField(f, v);
								props.set(full + ' ' + f.name, backed);

								if (v.set == 'set' || v.set == 'dynamic')
									propSetters.set(full + ' ' + f.name, true);

								if (backed)
									vars.set(f.name, v.type == null ? '' : typeName(v.type));

							case _:
						}
					}
					classVars.set(full, vars);

					var rets:StringMap<String> = new StringMap();
					for (f in c.fields) {
						switch (f.kind) {
							case KFunction(fn):
								if (fn.ret != null)
									rets.set(f.name, typeName(fn.ret));
								recordArity(full, f.name, fn);
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

					if (!typePaths.exists(a.name))
						typePaths.set(a.name, full);

					moduleClasses.set(full, true);
					moduleAbstracts.set(full, a.underlying == null ? '' : typeName(a.underlying));
					classVars.set(full, new StringMap());

					for (f in a.fields) {
						if (f.name == 'new')
							abstractCtors.set(full, true);
						recordOperators(full, f);
					}

					var returns:StringMap<String> = new StringMap();
					for (f in a.fields) {
						switch (f.kind) {
							case KFunction(fn):
								var as:String = f.name == 'new' ? '@new' : f.name;
								if (fn.ret != null)
									returns.set(as, typeName(fn.ret));

								// One more than written for anything but a static: an abstract's instance
								// methods and its constructor compile to statics taking the boxed value
								// first, and its own statics do not.
								recordArity(full, as, fn, hasAccess(f, AStatic) ? 0 : 1);
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
	 * @throws Unsupported If any declaration has no cppia spelling.
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
				case DImport(_, _):
				case DUsing(path):
					recordUsing(path.join('.'));
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
	 * @param decls The declarations of the module about to be emitted.
	 */
	function ownView(decls:Array<ModuleDecl>):Void {
		var pack:String = '';

		for (decl in decls) {
			switch (decl.d) {
				case DPackage(path):
					pack = path.join('.');

				case DImport(path, mode):
					recordImport(path, switch (mode) {
						case IAsName(alias): alias;
						case _: path[path.length - 1];
					});

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
	 * @param a The abstract's declaration.
	 * @param pack Its package, unused beyond matching `emitClass`'s shape.
	 * @return The class to emit in its place.
	 */
	function implementationOf(a:AbstractDecl, pack:String):ClassDecl {
		var fields:Array<FieldDecl> = [];
		for (f in a.fields) {
			var made:FieldDecl = f.access.contains(AStatic) ? f : hxscript.types.ScriptedAbstract.staticForm(f, a.name, a.underlying);

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

		superArgs = -1;

		if (currentSuper != '' && declaredClass(currentSuper) == null) {
			superArgs = hostConstructorArity(currentSuper);
			if (superArgs < 0)
				throw new Unsupported('extends ' + currentSuper + ', whose constructor shape is unknown', pos);
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
					var assign:Expr = {e: EBinop('=', target, v.expr), pos: pos};
					memberInits.push({e: EMeta(':hxsFieldInit', [], assign), pos: pos});
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

		if (!isInterface && restArg(f) != null) {
			emitVarArgsField(f, isStatic, pos);
			return;
		}

		switch (f.kind) {
			case KFunction(fn):
				var isConstructor:Bool = f.name == 'new';
				currentMethod = f.name;

				if (echoTarget != null && echoTarget == currentClass + '.' + f.name) {
					w.echo = new StringBuf();
					echoing = true;
				}

				w.token('FUNCTION');
				w.bool(isStatic || isConstructor);
				w.bool(hasAccess(f, ADynamic));
				w.str(f.name);
				returnsBool = Backend.isBool(fn.ret);
				w.type(fn.ret == null || returnsBool ? '' : typeName(fn.ret));
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
				w.token(accessCode(v.get, true, pos));
				w.token(accessCode(v.set, false, pos));
				w.bool(!physicalField(f, v));
				w.str(f.name);
				w.type(fieldType(v));

				if (v.expr == null || !isStatic) {
					w.int(0);
				} else {
					w.int(1);
					pushScope();

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
	 * Emits a `FUN` expression: the signature in stack-variable form, then the body. Used for both methods
	 * and function values.
	 *
	 * @param args The function's arguments.
	 * @param body Its body.
	 * @param ret Its return type, if annotated.
	 * @param pos Where it was declared.
	 */
	function emitFun(args:Array<Argument>, body:Expr, ret:Null<CType>, pos:Position):Void {
		pushScope();

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
		var whole:Expr = Accessors.apply({e: EBlock(prologue.concat([body])), pos: pos});
		var boxing = Capture.transform(args, whole);
		boxedBody = boxing.body;

		w.pos(pos == null ? 0 : pos.line);
		w.token('FUN');

		/**
		 * A `Bool` return is written as untyped here, the way the `FUNCTION` above it already writes
		 * one, because the two have to agree about the same method and they did not.
		 *
		 * The declaration says a `Bool`-returning method returns nothing in particular, and the body
		 * said it returns a native boolean. What the body actually produces is neither: `RETVAL`
		 * writes its value untyped and boxes it, since cppia has no boolean of its own and an
		 * unboxed one is an integer. So the header was the only party claiming a native bool, and a
		 * caller that believed it read the integer 1 as an object and dereferenced it. That is a
		 * segmentation fault inside a virtual call, with no Haxe frame to catch it and nothing
		 * written down.
		 */
		w.type(ret == null || Backend.isBool(ret) ? '' : typeName(ret));
		w.int(args.length);

		for (a in args) {
			var box:Bool = boxing.boxedArgs.indexOf(a.name) >= 0;

			// An argument the caller may leave off cannot hold its declared type. A cppia `Int` slot
			// reads the null a padded call passes as 0, which is a value the argument never had: the
			// omitted case then looks supplied, and the prologue that applies the default never fires
			// because 0 is not null.
			var loose:Bool = box || a.t == null || a.opt == true || a.value != null;
			var spelling:String = loose ? '' : typeName(a.t);

			noteArrayElement(a.name, a.t);
			var id:Int = declareVar(a.name, loose ? null : spelling, a.t == null ? null : typeName(a.t));

			w.str(a.name);
			w.int(id);
			w.bool(false);
			storableType(spelling);
			w.bool(false);
		}

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
	 * form it does not throws `Unsupported`, which abandons the module rather than the batch.
	 *
	 * @param e The expression, or null for a literal absence.
	 * @throws Unsupported If it has no cppia spelling.
	 */
	function expr(e:Expr):Void {
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

				// Always the two-branch form, even with nothing to put in the second. The loader gives
				// `IF` no value at all, so an `if` read as a value was null however it went, while the
				// interpreter hands back the branch it took. Writing an empty else costs one token and
				// makes the two agree.
				w.token('IFELSE');
				expr(cond);
				expr(e1);

				if (e2 == null) {
					w.pos(line);
					w.token('NULL');
				} else {
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
					if (returnsBool)
						boolean(v, line);
					else
						expr(v);
				}

			case EThrow(v):
				w.pos(line);
				w.token('THROW');
				expr(v);

			case EBinop(op, e1, e2):
				emitBinop(op, e1, e2, e.pos);

			case EUnop(op, prefix, inner):
				if ((op == '++' || op == '--') && repeatableField(inner)) {
					var step:String = op == '++' ? '+' : '-';
					var back:String = op == '++' ? '-' : '+';
					var one:Expr = {e: EConst(CInt(1)), pos: e.pos};

					var changed:Expr = {
						e: EBinop('=', inner, {e: EBinop(step, inner, one), pos: e.pos}),
						pos: e.pos
					};

					if (prefix)
						expr(changed);
					else
						expr({e: EBinop(back, {e: EParent(changed), pos: e.pos}, one), pos: e.pos});

					return;
				}

				w.pos(line);
				switch (op) {
					case '-':
						w.token('NEG');
					case '!':
						w.token('!');
					case '~':
						w.token('~');
					case '++' | '--':
						w.token(op == '++' ? (prefix ? '++' : '+++') : (prefix ? '--' : '---'));
					default:
						throw new Unsupported('unary operator ' + op, e.pos);
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

				if (isMapType(known)) {
					w.pos(line);
					w.token('CALL');
					w.int(2);
					w.pos(line);
					w.token('FSTATIC');
					w.type('hxscript.runtime.Indexing');
					w.str('get');
					expr(arr);
					expr(index);
					return;
				}

				w.pos(line);
				w.token('ARRAYI');
				w.type(known != null && known.substr(0, 5) == 'Array' ? known : 'Dynamic');
				expr(arr);
				expr(index);

			case EArrayDecl(items):
				if (items.length > 0 && items[0].e.match(EBinop('=>', _, _))) {
					if (!allPairs(items)) {
						raising('Invalid map key=>value expression', line);
						return;
					}

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
				var boxed:Null<String> = abstractPathOf(cl);
				if (boxed != null) {
					if (!abstractCtors.exists(boxed)) {
						expr(params.length > 0 ? params[0] : null);
						return;
					}

					var wantedCtor:Int = padArgs(boxed, '@new', params.length + 1);
					w.pos(line);
					w.token('CALLSTATIC');
					useType(boxed);
					w.str('@new');
					w.int(wantedCtor);
					w.pos(line);
					w.token('NULL');
					emitArgs(params, wantedCtor, 1, line);
					return;
				}

				/**
				 * A host abstract has no runtime class to make, so there is no name a `NEW` could
				 * carry: the one it named resolved to null and the hxcpp process ended part way
				 * through, silently and with a success code. Built through the helper instead, which
				 * reaches the static the constructor became.
				 *
				 * Only a host one. An abstract a script declared is built above this, through the
				 * constructor the batch emitted for it.
				 */
				if (hxscript.types.AbstractTools.resolve(cl) != null) {
					emitConstruct(nativePath(typePaths.exists(cl) ? typePaths.get(cl) : cl), params, e.pos);
					return;
				}

				var built:String = (cl == 'Map' || cl == 'haxe.ds.Map') && !typePaths.exists(cl) ? 'hxscript.runtime.AnyMap' : resolveType(cl, e.pos);

				/**
				 * A call that may be leaving out an optional in the middle, which an arity cannot
				 * place: padding from the right would write the third argument into the second. The
				 * helper has the values in hand and places them by type, the way Haxe placed them.
				 */
				if (shortOfMiddle(built, params.length)) {
					emitConstruct(built, params, e.pos);
					return;
				}

				var wantedNew:Int = padArgs(declaredClass(built), 'new', params.length);
				w.pos(line);
				w.token('NEW');
				useType(built);
				w.int(wantedNew);
				emitArgs(params, wantedNew, 0, line);

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

			case EMeta(':hxsFieldInit', _, inner):
				emittingInits = true;
				expr(inner);
				emittingInits = false;

			case EMeta(_, _, inner):
				expr(inner);

			case EFunction(args, body, _, ret, _):
				emitFun(args, body, ret, e.pos);

			case EDecl(_):
				throw new Unsupported('inline type declarations', e.pos);

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
						throw new Unsupported('local property accessors', item.pos);

					w.pos(item.pos == null ? 0 : item.pos.line);
					w.token('TVARS');
					w.int(1);

					noteArrayElement(n, t);

					// Without an annotation the initialiser is asked what it produces, because a local
					// holding one of this batch's abstracts has to be known as one: its methods are
					// statics taking the boxed value, and a call it did not recognise was emitted as an
					// instance call on the type the abstract wraps, which the loader resolves to nothing.
					var id:Int = declareVar(n, t == null ? inferType(init) : typeName(t));
					var stored:String = t != null ? typeName(t) : literalType(init);

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
						storableType(stored);
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
			var member:Null<Expr> = memberSetterCall(e1, e2, pos);
			if (member != null) {
				expr(member);
				return;
			}

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
				boolean(e2, line);
				return;
			}

			w.pos(line);
			w.token('SET');
			writingTo = true;
			expr(e1);
			writingTo = false;
			expectedArray = elementArray(inferType(e1));
			boolean(e2, line);
			return;
		}

		var plain:String = ASSIGN_OPS.indexOf(op) >= 0 ? op.substr(0, op.length - 1) : op;

		// A `Bool` joined to a `String` is spelled out rather than added. cppia has no boolean of its
		// own, so the addition sees the integer behind it and writes `1`, and the JIT's own inline
		// conversion of a comparison to a string ends the process outright. `Std.string` is a call,
		// which both modes get right.
		if (plain == '+') {
			var left:Null<String> = inferType(e1);
			var right:Null<String> = inferType(e2);

			if (left == 'String' && right == 'Bool')
				e2 = spelled(e2, pos);
			else if (right == 'String' && left == 'Bool')
				e1 = spelled(e1, pos);
		}

		var over:Null<{owner:String, name:String}> = operatorFor(plain, e1, e2);
		if (over != null) {
			if (plain != op) {
				emitBinop('=', e1, {e: EBinop(plain, e1, e2), pos: pos}, pos);
				return;
			}

			w.pos(line);
			w.token('CALLSTATIC');
			useType(over.owner);
			w.str(over.name);
			w.int(2);
			expr(e1);
			expr(e2);
			return;
		}

		var hosted:Null<{receiver:Expr, other:Null<Expr>, name:String}> = hostOperatorFor(plain, e1, e2);
		if (hosted != null) {
			if (plain != op) {
				emitBinop('=', e1, {e: EBinop(plain, e1, e2), pos: pos}, pos);
				return;
			}

			/**
			 * A member call rather than a static one: a host abstract's operator is a method of the
			 * wrapper the host's build generated, which is the value in hand.
			 */
			w.pos(line);
			w.token('CALLMEMBER');
			w.type('');
			w.str(hosted.name);
			w.int(1);
			expr(hosted.receiver);
			expr(hosted.other);
			return;
		}

		if (ASSIGN_OPS.indexOf(op) >= 0) {
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

		if (op == '??') {
			expr(nullCoalesce(e1, e2, pos));
			return;
		}

		if (op == 'is') {
			expr({
				e: ECall({e: EField({e: EIdent('Std'), pos: pos}, 'isOfType'), pos: pos}, [e1, e2]),
				pos: pos
			});
			return;
		}

		throw new Unsupported('operator ' + op, pos);
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
			var flat:Array<Expr> = [];
			for (v in c.values)
				flattenOr(v, flat);
			c.values = flat;
		}

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
						expr(switchAsChain(cond, cases, defaultExpr, pos));
						return;
					case _:
						throw new Unsupported('pattern matching in switch', pos);
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

					if (nativeAbstract(asType) != null)
						throw new Unsupported('$asType.$name, which is a method of an abstract and has no class to be called on', pos);

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

					var wantedStatic:Int = padArgs(asType, name, params.length);
					w.pos(line);
					w.token('CALLSTATIC');
					useType(asType);
					w.str(name);
					w.int(wantedStatic);
					emitArgs(params, wantedStatic, 0, line);
					return;
				}

				var boxed:Null<String> = abstractTypeOf(obj);
				if (boxed != null) {
					var wantedBoxed:Int = padArgs(boxed, name, params.length + 1);
					w.pos(line);
					w.token('CALLSTATIC');
					useType(boxed);
					w.str(name);
					w.int(wantedBoxed);
					expr(obj);
					emitArgs(params, wantedBoxed, 1, line);
					return;
				}

				switch (obj.e) {
					case EIdent('super'):
						var wantedSuper:Int = padArgs(currentSuper, name, params.length);
						w.pos(line);
						w.token('CALLSUPER');
						w.type(currentSuper);
						w.str(name);
						w.int(wantedSuper);
						emitArgs(params, wantedSuper, 0, line);
						return;
					case _:
				}

				var extension:Null<Expr> = usingCall(obj, name, params, pos);
				if (extension != null) {
					expr(extension);
					return;
				}

				if (usingStatics.exists(name)) {
					var declaring:Array<String> = usingOwners.get(name);
					var named:Array<Expr> = [for (path in declaring) {e: EConst(CString(path, false)), pos: pos}];

					w.pos(line);
					w.token('CALL');
					w.int(4);
					w.pos(line);
					w.token('FSTATIC');
					w.type('hxscript.runtime.Using');
					w.str('call');
					expr(obj);
					expr({e: EArrayDecl(named), pos: pos});
					expr({e: EConst(CString(name, false)), pos: pos});
					expr({e: EArrayDecl(params), pos: pos});
					return;
				}

				var receiver:Null<String> = instanceClassOf(obj);
				var wantedMember:Int = padArgs(receiver, name, params.length);

				/**
				 * A member call is dispatched by name, because naming the class asks the loader for a
				 * vtable slot and this emitter does not number its functions the way that lookup
				 * expects. Dispatching by name loses what the method was declared to return, and a
				 * `Bool` declared return is the one case where that changes the value rather than only
				 * the type: it arrives boxed as an integer.
				 */
				if (returnsBoolOf(receiver, name)) {
					w.pos(line);
					w.token('CASTBOOL');
				}

				w.pos(line);
				w.token('CALLMEMBER');
				w.type('');
				w.str(name);
				w.int(wantedMember);
				expr(obj);
				emitArgs(params, wantedMember, 0, line);

			case EIdent('super'):
				var supplied:Int = params.length;

				if (superArgs >= 0 && shortOfMiddle(currentSuper, supplied)) {
					/**
					 * A base whose optional is not its last, reached with fewer arguments than it
					 * declares. `new` hands this to the runtime helper, which cannot be done here: a
					 * base is constructed onto the instance being built rather than made, so the
					 * arguments have to be in the instruction. They are placed against the recorded
					 * parameters instead, from the types the call site wrote.
					 */
					var placed:Null<Array<Expr>> = placeSuper(currentSuper, params, pos);

					if (placed == null)
						throw new Unsupported('super(...), which leaves out a parameter of ' + currentSuper
							+ ' that is not its last, and whose arguments do not say which', pos);

					params = placed;
					supplied = params.length;
				}

				var wanted:Int = superArgs > supplied ? superArgs : supplied;

				w.pos(line);
				w.token('CALLSUPERNEW');
				w.type(currentSuper);
				w.int(wanted);
				for (p in params)
					expr(p);

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
				var wantedThis:Int = padArgs(currentClass, name, params.length);
				w.pos(line);
				w.token('CALLTHIS');
				w.type(currentClass);
				w.str(name);
				w.int(wantedThis);
				emitArgs(params, wantedThis, 0, line);

			case EIdent(name) if (lookupVar(name) == null && statics.exists(name)):
				var wantedOwn:Int = padArgs(currentClass, name, params.length);
				w.pos(line);
				w.token('CALLSTATIC');
				w.type(currentClass);
				w.str(name);
				w.int(wantedOwn);
				emitArgs(params, wantedOwn, 0, line);

			case EIdent(name) if (lookupVar(name) == null && moduleFields.exists(name)):
				var owningModule:String = moduleFields.get(name);
				var wantedModule:Int = padArgs(owningModule, name, params.length);
				w.pos(line);
				w.token('CALLSTATIC');
				w.type(owningModule);
				w.str(name);
				w.int(wantedModule);
				emitArgs(params, wantedModule, 0, line);

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

		switch (obj.e) {
			case EIdent('super'):
				if (methodArity.exists(currentSuper + ' ' + name)) {
					expr(superClosure(name, methodArity.get(currentSuper + ' ' + name), pos));
					return;
				}

				emitField2({e: EIdent('this'), pos: pos}, name, pos);
				return;

			case _:
		}

		var asType:Null<String> = typeOf(obj);
		if (asType != null) {
			emitStaticField(asType, name, pos);
			return;
		}

		var writing:Bool = writingTo;
		writingTo = false;

		var holder:Null<String> = (obj.e.match(EIdent('this'))) ? currentClass : instanceClassOf(obj);
		if (holder != null)
			checkAccessorSelf(holder, name, pos);

		if (!writing && readRestricted(holder, name)) {
			expr({
				e: EThrow({e: EConst(CString('This expression cannot be accessed for reading', false)), pos: pos}),
				pos: pos
			});
			return;
		}

		if (holder != null && instanceVar(holder, name) != null && directField(holder, name)) {
			// An instance field declared `Bool` is laid out as cppia's integer type, so reading one
			// hands back 0 or 1: a condition and a comparison are still right, but `Std.string`,
			// concatenation and reflection all see the number. Comparing it produces a real boolean,
			// which is what every other spelling of a `Bool` already hands back. Not on the left of an
			// assignment, where the field itself is what is wanted.
			var readsBool:Bool = !writing && instanceVar(holder, name) == 'Bool';
			if (readsBool) {
				w.pos(line);
				w.token('==');
			}

			w.pos(line);
			w.token('FLINK');
			w.type(holder);
			w.str(name);
			expr(obj);

			if (readsBool) {
				w.pos(line);
				w.token('true');
			}
			return;
		}

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
	 * Writes a read of a field belonging to a type rather than to an instance.
	 *
	 * Its own function because two spellings arrive here: `HostFlag.Add`, which names the type, and
	 * a bare `Add` that an `import HostFlag;` bound to the same field. The two have to fold to the
	 * same instruction or the naming decides the value, which is the whole complaint behind the
	 * host-name refusals.
	 *
	 * @param asType The owning type's path.
	 * @param name The field.
	 * @param pos Where it appears.
	 * @throws Unsupported If it is a field of an abstract that is not a foldable constant.
	 */
	function emitStaticField(asType:String, name:String, pos:Position):Void {
		var line:Int = pos == null ? 0 : pos.line;

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

		var wrapper:Null<Class<Dynamic>> = nativeAbstract(asType);
		if (wrapper != null) {
			var constant:Null<Dynamic> = abstractConstant(wrapper, name);
			if (constant == null)
				throw new Unsupported('$asType.$name, which is a field of an abstract that is not a constant', pos);

			emitConstant(constant, line);
			return;
		}

		w.pos(line);
		w.token('FSTATIC');
		useType(asType);
		w.str(name);
	}

	/**
	 * Writes a bare identifier, which may be a local, a field of `this`, a type, or a host static.
	 *
	 * @param v The name.
	 * @param pos Where it appears.
	 * @throws Unsupported If it resolves to nothing this batch or the host can offer.
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
			if (!writingTo && restrictedFields.exists(currentClass + ' ' + v)) {
				expr({
					e: EThrow({e: EConst(CString('This expression cannot be accessed for reading', false)), pos: pos}),
					pos: pos
				});
				return;
			}

			checkAccessorSelf(currentClass, v, pos);
			w.pos(line);
			w.token(instanceVar(currentClass, v) != null && directField(currentClass, v) ? 'FTHISINST' : 'FTHISNAME');
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

		if (importedFields.exists(v)) {
			emitStaticField(importedFields.get(v), v, pos);
			return;
		}

		if (inheritedMember(v)) {
			w.pos(line);
			w.token('FNAME');
			w.unknownType();
			w.str(v);
			w.pos(line);
			w.token('THIS');
			return;
		}

		/**
		 * A type the world carries under this name, which the module never imported. Last of all, so
		 * every name a module binds itself has already answered.
		 */
		var world:Null<String> = worldType(v);
		if (world != null) {
			w.pos(line);
			w.token('CLASSOF');
			w.type(world);
			return;
		}

		throw new Unsupported('unresolved identifier ' + v, pos);
	}

	/**
	 * Whether a name a scripted class does not declare is one it inherits.
	 *
	 * @param name The unresolved name.
	 * @return Whether a class up the chain declares it.
	 */
	function inheritedMember(name:String):Bool {
		if (currentSuper.length == 0)
			return false;

		if (declaredClass(currentSuper) != null)
			return true;

		if (inheritedFrom != currentSuper) {
			inheritedFrom = currentSuper;
			inherited = new StringMap();

			var cls:Dynamic = Type.resolveClass(currentSuper);
			var seen:Bool = false;

			while (cls != null) {
				for (field in Type.getInstanceFields(cls)) {
					seen = true;
					inherited.set(field, true);
				}

				cls = Type.getSuperClass(cls);
			}

			if (!seen)
				inherited = null;
		}

		if (inherited == null)
			return true;

		return inherited.exists(name) || inherited.exists('get_$name') || inherited.exists('set_$name');
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

		// An explicit `null` rather than nothing, because the chain is often read as a value and the
		// loader gives an `if` with no else no value at all. A switch that matches nothing evaluates
		// to null, which is what the interpreter does, so writing the else says what was meant.
		var chain:Expr = defaultExpr ?? {e: EIdent('null'), pos: pos};
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
						e: ECall({e: EField({e: EIdent(ENUMS), pos: pos}, 'enumParameters'), pos: pos}, [ref]),
						pos: pos
					};
					var element:Expr = {e: EArray(params, {e: EConst(CInt(b)), pos: pos}), pos: pos};
					bound.push({e: EVar(bind, null, element, null, null, false), pos: pos});
				}

				bound.push(c.expr);
				body = {e: EBlock(bound), pos: pos};

				var ctor:Expr = {
					e: ECall({e: EField({e: EIdent(ENUMS), pos: pos}, 'enumConstructor'), pos: pos}, [ref]),
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
					var eq:Expr = anyEnumCtor(v) ? {
						e: EBinop('==', {
							e: ECall({e: EField({e: EIdent(ENUMS), pos: pos}, 'enumConstructor'), pos: pos}, [ref]),
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
					for (b in shape.binds)
						guard = Capture.substitute(guard, b.name, b.value);
				} else if (capture != null) {
					guard = Capture.substitute(guard, capture, ref);
				} else if (pattern != null) {
					for (b in 0...pattern.binds.length) {
						var bind:String = pattern.binds[b];
						if (bind == '_')
							continue;

						var params:Expr = {
							e: ECall({e: EField({e: EIdent(ENUMS), pos: pos}, 'enumParameters'), pos: pos}, [ref]),
							pos: pos
						};
						guard = Capture.substitute(guard, bind, {e: EArray(params, {e: EConst(CInt(b)), pos: pos}), pos: pos});
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

			case EIdent(name) if (!hxscript.types.TypeTools.isTypeIdentifier(name) && name != 'true' && name != 'false' && name != 'null'):
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
					if (name != 'true' && name != 'false' && name != 'null' && !typePaths.exists(name) && enumOwning(name) == null)
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
	 * @param loop The comprehension's driving expression.
	 * @param want The array type the target asked for, if any.
	 * @param pos Where the literal appears.
	 * @return A block expression evaluating to the finished array.
	 */
	function comprehension(loop:Expr, want:Null<String>, pos:Position):Expr {
		var name:String = tempName('compr');
		var target:Expr = {e: EIdent(name), pos: pos};

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
	 * build, which is the same reading a plain map literal gets. Looked for down the same positions
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
	 * Whether reading a member here is what the interpreter throws over.
	 *
	 * A field written `var x(null, ...)` is readable only by the instance holding it: the interpreter
	 * compares the interpreter doing the reading against the one owning the slot, and every instance
	 * has its own. `this` is the one case that passes, and the caller has already excluded it.
	 *
	 * @param holder The class holding it, or null when the receiver could not be named.
	 * @param name The member being read.
	 * @return Whether to raise rather than read.
	 */
	function readRestricted(holder:Null<String>, name:String):Bool {
		return holder != null ? restrictedFields.exists(holder + ' ' + name) : restrictedNames.exists(name);
	}

	/** @return Whether every entry of a literal is a `key => value` pair, which a map wants. */
	function allPairs(items:Array<Expr>):Bool {
		for (item in items) {
			if (!item.e.match(EBinop('=>', _, _)))
				return false;
		}

		return true;
	}

	/**
	 * Calls the runtime raiser, for a construct that fails when it runs rather than when it compiles.
	 *
	 * Written as a static against the helper's path rather than built as a field chain, because a
	 * chain is resolved by the generic path and the type it names has to be one a script may reach.
	 *
	 * @param message The text the interpreter carries.
	 * @param line Where the construct appears.
	 */
	function raising(message:String, line:Int):Void {
		w.pos(line);
		w.token('CALL');
		w.int(1);
		w.pos(line);
		w.token('FSTATIC');
		w.type('hxscript.runtime.Raise');
		w.str('custom');
		w.pos(line);
		w.token('s');
		w.str(message);
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
		var mapClass:String = mapClassOf(items);

		var name:String = tempName('map');
		var target:Expr = {e: EIdent(name), pos: pos};
		var block:Array<Expr> = [
			{e: EVar(name, CTPath([mapClass]), {e: ENew(mapClass, []), pos: pos}, null, null, false), pos: pos}
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
			throw new Unsupported('key-value for loop', pos);

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
	 * @param e The value.
	 * @param line Where the assignment is.
	 */
	function boolean(e:Expr, line:Int):Void {
		if (inferType(e) != 'Bool') {
			expr(e);
			return;
		}

		w.pos(line);
		w.token('CASTBOOL');
		expr(e);
	}

	/**
	 * Maps a property accessor to the cppia access code for it.
	 *
	 * @param mode The accessor as written, or null for a plain field.
	 * @param reading Whether this is the read side of the declaration.
	 * @param pos Where the field is declared.
	 * @return The one-character access code.
	 */
	function accessCode(mode:Null<String>, reading:Bool, pos:Position):String {
		return switch (mode) {
			case null | 'default' | 'null': 'N';
			case 'get' | 'set' | 'dynamic': 'V';
			case 'never': 'n';
			case _: throw new Unsupported('property accessor ' + mode, pos);
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
	 * The type an unannotated local gets from a literal it is initialised with.
	 *
	 * @param init The initialiser.
	 * @return `Int`, `Float`, `Bool`, or empty for anything else.
	 */
	function literalType(init:Null<Expr>):String {
		if (init == null)
			return '';

		return switch (init.e) {
			case EConst(CInt(_)): 'Int';
			case EConst(CFloat(_)): 'Float';
			case EIdent('true') | EIdent('false'): 'Bool';
			case EParent(inner): literalType(inner);
			case _: '';
		}
	}

	/**
	 * Writes the declared type of a variable slot.
	 *
	 * @param path The declared type, or the empty string when there was none.
	 */
	function storableType(path:String):Void {
		if (path == null || path.length == 0) {
			w.unknownType();
			return;
		}

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
	 * @param e The assignment target.
	 * @return Whether it needs property access.
	 */
	function hostField(e:Expr):Bool {
		switch (e.e) {
			case EField(obj, name, _):
				if (typeOf(obj) != null) {
					return false;
				}

				var holder:Null<String> = obj.e.match(EIdent('this')) ? currentClass : instanceClassOf(obj);
				return holder == null || instanceVar(holder, name) == null;

			case _:
				return false;
		}
	}

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

	/** An array type carrying an element kind, or null for anything else. */
	static function elementArray(name:Null<String>):Null<String> {
		return (name != null && name.length > 6 && name.substr(0, 6) == 'Array.') ? name : null;
	}

	/**
	 * The type to declare a field with, inferred from a literal initialiser when none was written.
	 *
	 * @param v The variable declaration.
	 * @return The type name, or empty for a slot that should hold anything.
	 */
	function fieldType(v:VarDecl):String {
		if (v.type == null)
			return Config.nativeBoolSlots ? literalType(v.expr) : '';

		if (Backend.isBool(v.type) && !Config.nativeBoolSlots)
			return '';

		return typeName(v.type);
	}

	/**
	 * @param owner The class holding it.
	 * @param name The member name.
	 * @return Whether to emit a direct slot access rather than a by-name one.
	 */
	function directField(owner:String, name:String):Bool {
		var key:String = owner + ' ' + name;
		if (!props.exists(key))
			return true;

		if (!props.get(key))
			return false;

		return owner == currentClass && (emittingInits || insideAccessor(name));
	}

	/**
	 * Rewrites a write to a property into the call it really is, because a by-name reference is not
	 * something the loader will assign to.
	 *
	 * @param target What is being assigned to.
	 * @param value What is being assigned.
	 * @param pos Where the assignment is.
	 * @return The setter call, or null when the target is not a property with one.
	 */
	function memberSetterCall(target:Expr, value:Expr, pos:Position):Null<Expr> {
		if (emittingInits)
			return null;

		switch (target.e) {
			case EIdent(name):
				if (lookupVar(name) != null || !members.exists(name) || !hasPropSetter(currentClass, name))
					return null;

				return call({e: EIdent('this'), pos: pos}, name, value, pos);

			case EField(obj, name, _):
				var owner:Null<String> = obj.e.match(EIdent('this')) ? currentClass : instanceClassOf(obj);
				if (owner == null || !hasPropSetter(owner, name))
					return null;

				return call(obj, name, value, pos);

			case _:
				return null;
		}
	}

	/**
	 * @param owner The class holding it.
	 * @param name The member name.
	 * @return Whether writing it means calling its setter here.
	 */
	function hasPropSetter(owner:String, name:String):Bool {
		return propSetters.exists(owner + ' ' + name) && !directField(owner, name);
	}

	/**
	 * @param obj The receiver.
	 * @param name The property.
	 * @param value What to store.
	 * @param pos Where the assignment is.
	 * @return `obj.set_name(value)`.
	 */
	function call(obj:Expr, name:String, value:Expr, pos:Position):Expr {
		return {e: ECall({e: EField(obj, 'set_' + name, false), pos: pos}, [value]), pos: pos};
	}

	/**
	 * @param owner The class holding the method, or null when it is not known.
	 * @param name The method name.
	 * @return Whether it was declared to return `Bool`.
	 */
	function returnsBoolOf(owner:Null<String>, name:String):Bool {
		if (owner == null)
			return false;

		var rets:Null<StringMap<String>> = methodReturns.get(owner);
		return rets != null && rets.get(name) == 'Bool';
	}

	/**
	 * @param name A property of the current class.
	 * @return Whether the method being emitted is one of its accessors.
	 */
	function insideAccessor(name:String):Bool {
		return currentMethod == 'get_' + name || currentMethod == 'set_' + name;
	}

	/**
	 * Refuses a property with no field behind it being named inside its own accessor, which Haxe
	 * rejects outright and which compiled would call the accessor from inside itself forever.
	 *
	 * @param owner The class holding it.
	 * @param name The member being named.
	 * @param pos Where it is named.
	 */
	function checkAccessorSelf(owner:String, name:String, pos:Position):Void {
		var key:String = owner + ' ' + name;
		if (props.exists(key) && !props.get(key) && owner == currentClass && insideAccessor(name))
			throw new Unsupported(name + ' named inside its own accessor with no field behind it; it wants @:isVar', pos);
	}

	/**
	 * Whether a declared field really has storage, following Haxe's `is_physical_var_field`.
	 *
	 * @param f The field.
	 * @param v Its variable declaration.
	 * @return Whether cppia should give it a slot.
	 */
	static function physicalField(f:FieldDecl, v:VarDecl):Bool {
		if (v.get == null || v.get == 'default' || v.get == 'null')
			return true;

		if (v.set == null || v.set == 'default' || v.set == 'null')
			return true;

		if (f.meta != null) {
			for (m in f.meta) {
				if (m.name == ':isVar')
					return true;
			}
		}

		return false;
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
	 * Writes a construction through the runtime helper rather than through `NEW`.
	 *
	 * For the two shapes an opcode cannot express: a host abstract, which has no class to name, and a
	 * call that may be leaving out an optional parameter in the middle, which an arity cannot place.
	 * `hxscript.runtime.Construct` answers both with the arguments in hand, which is what neither the
	 * opcode nor this emitter has.
	 *
	 * The path travels as a string rather than as a `CLASSOF`, because an abstract's wrapper is a
	 * class the host's own build generated and its name is not one the type table carries: a
	 * reference to it would fail `useType` for a type that is really there.
	 *
	 * @param path The type's compile path.
	 * @param params The arguments as the call wrote them.
	 * @param pos Where it appears.
	 */
	function emitConstruct(path:String, params:Array<Expr>, pos:Position):Void {
		var line:Int = pos == null ? 0 : pos.line;

		w.pos(line);
		w.token('CALLSTATIC');
		w.type('hxscript.runtime.Construct');
		w.str('make');
		w.int(2);

		w.pos(line);
		w.token('s');
		w.str(path);

		expr({e: EArrayDecl(params), pos: pos});
	}

	/**
	 * Places a short `super(...)` into the parameters the base really declares.
	 *
	 * The same walk `hxscript.types.ArgumentTools` performs at run time, done here because there is
	 * no run time to do it in: a base is constructed onto the instance being built, so the arguments
	 * are part of the instruction and cannot be handed to a helper first. What stands in for the
	 * values is what the call site wrote them as.
	 *
	 * **Certain, or nothing.** An argument whose type this cannot name leaves the whole call
	 * undecided and the module is refused, which is what it did for every such call before. A wrong
	 * placement would be worse than the refusal, because it would quietly construct the base with the
	 * parent in the material.
	 *
	 * @param path The base's path.
	 * @param params The arguments as the call wrote them.
	 * @param pos Where it appears.
	 * @return The arguments in their parameters with a `null` where one was skipped, or null when
	 *         nothing was skipped after all, or when the types in hand do not decide it.
	 */
	function placeSuper(path:String, params:Array<Expr>, pos:Position):Null<Array<Expr>> {
		var shape:Null<Array<String>> = ctorShape(path);
		if (shape == null)
			return null;

		var out:Array<Expr> = [];
		var at:Int = 0;
		var skipped:Bool = false;

		for (part in shape) {
			var optional:Bool = part.charAt(0) == '?';
			var key:String = optional ? part.substr(1) : part;

			if (at >= params.length) {
				/** A required parameter with nothing left to give it: not a call this can place. */
				if (!optional)
					return null;

				out.push({e: EIdent('null'), pos: pos});
				continue;
			}

			var takes:Null<Bool> = accepts(key, params[at]);

			if (takes == null)
				return null;

			if (takes) {
				out.push(params[at]);
				at++;
			} else if (optional) {
				out.push({e: EIdent('null'), pos: pos});
				skipped = true;
			} else {
				return null;
			}
		}

		/** Arguments left over means the walk put them somewhere they do not belong. */
		if (at < params.length)
			return null;

		/** Nothing skipped, so ordinary padding was right all along and is left to do it. */
		return skipped ? out : null;
	}

	/**
	 * Whether a parameter of this type takes what this argument was written as.
	 *
	 * @param key The parameter's recorded type, empty for one that takes anything.
	 * @param e The argument.
	 * @return True or false when that is certain, and null when it is not.
	 */
	function accepts(key:String, e:Expr):Null<Bool> {
		if (key.length == 0)
			return true;

		if (e.e.match(EIdent('null')))
			return true;

		var written:Null<String> = inferType(e);

		/**
		 * Falling back to what the local was written as, which is what an optional parameter has
		 * instead of a slot type: `?held:HostShaped` is untyped storage and still says plainly which
		 * parameter it was meant for.
		 */
		if (written == null || written.length == 0) {
			switch (e.e) {
				case EIdent(v) if (lookupVar(v) != null):
					written = writtenVarType(v);
				case _:
			}
		}

		if (written == null || written.length == 0)
			return null;

		switch (key) {
			case 'Int':
				return written == 'Int';
			case 'Float' | 'Single':
				return written == 'Int' || written == 'Float' || written == 'Single';
			case 'Bool':
				return written == 'Bool';
			case 'String':
				return written == 'String';
			case _:
		}

		switch (written) {
			case 'Int' | 'Float' | 'Single' | 'Bool' | 'String':
				return false;
			case _:
		}

		var value:String = typePaths.exists(written) ? typePaths.get(written) : written;
		var wanted:String = typePaths.exists(key) ? typePaths.get(key) : key;

		return value == wanted ? true : descends(value, wanted);
	}

	/**
	 * Whether one type is the other or is built on it, asked of the build rather than of a value.
	 *
	 * @param value The argument's type.
	 * @param wanted The parameter's type.
	 * @return True or false when the chain is known, and null when it is not.
	 */
	function descends(value:String, wanted:String):Null<Bool> {
		/**
		 * A class this batch declares has no runtime class to walk, and what it extends is a
		 * declaration rather than a chain, so whether it reaches the parameter's type is left
		 * undecided rather than guessed at.
		 */
		if (declaredClass(value) != null || !resolvable(value))
			return null;

		var cls:Class<Dynamic> = Type.resolveClass(value);
		if (cls == null)
			return null;

		var seen:Int = 0;

		while (cls != null && seen < SUPER_DEPTH) {
			if (Type.getClassName(cls) == wanted)
				return true;

			cls = Type.getSuperClass(cls);
			seen++;
		}

		return false;
	}

	/**
	 * @param path A class's path.
	 * @return Its constructor's recorded parameters, or null when a call of it cannot be short in
	 *         the middle and so none were recorded.
	 */
	function ctorShape(path:String):Null<Array<String>> {
		var infos:Array<hxscript.types.TypeCollection.TypeInfo> = hxscript.types.TypeCollection.main.fromCompilePath(path);
		if (infos == null || infos.length == 0)
			infos = hxscript.types.TypeCollection.main.fromPath(path);
		if (infos == null || infos.length == 0)
			return null;

		var written:Null<String> = infos[0].ctorSkip;
		return (written == null || written.length == 0) ? null : written.split('|');
	}

	/**
	 * Whether a call leaves out a parameter of a host constructor that is not the last one.
	 *
	 * Everything here pads from the right, and for most constructors that is what Haxe does too. It
	 * is not what Haxe does for one whose optional parameter has another parameter behind it: `new
	 * Mesh(prim, parent)` against `(primitive, ?material, ?parent)` is placed by asking what each
	 * argument is, and the answer is a `null` in the middle rather than one on the end. Padding it
	 * here writes the parent into the material.
	 *
	 * Nothing in an instruction can ask that question, and the interpreter can, so the module is
	 * refused and interpreted instead: slower, and the answer the script was written for.
	 *
	 * **Only where a skip is possible at all.** A call is placed in order for as long as the
	 * parameters it reaches are required ones, since a required parameter is never the one dropped.
	 * So `new Mesh(prim)` is padded here as it always was, and it is `new Mesh(prim, parent)`, whose
	 * second parameter may be skipped, that has to go elsewhere to be decided.
	 *
	 * @param path The host class's full path.
	 * @param given How many arguments the call wrote.
	 * @return Whether this call is one padding cannot complete.
	 */
	function shortOfMiddle(path:String, given:Int):Bool {
		var infos:Array<hxscript.types.TypeCollection.TypeInfo> = hxscript.types.TypeCollection.main.fromCompilePath(path);
		if (infos == null || infos.length == 0)
			infos = hxscript.types.TypeCollection.main.fromPath(path);
		if (infos == null || infos.length == 0)
			return false;

		var written:Null<String> = infos[0].ctorSkip;
		if (written == null)
			return false;

		var params:Array<String> = written.split('|');
		if (given >= params.length)
			return false;

		for (i in 0...given)
			if (params[i].charAt(0) == '?')
				return true;

		return false;
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
	 * Records how many arguments a batch method declares.
	 *
	 * A rest argument is not recorded: those compile to a variadic closure that takes one array, so
	 * the call site's arity is already irrelevant and padding one would add an argument the closure
	 * would read as data.
	 *
	 * @param owner The declaring type's full path.
	 * @param name The method name, as the emitter will write it.
	 * @param fn The declaration.
	 * @param extra Arguments the compiled form takes beyond the written ones.
	 */
	function recordArity(owner:String, name:String, fn:FunctionDecl, extra:Int = 0):Void {
		for (a in fn.args) {
			if (a.rest == true)
				return;
		}

		methodArity.set(owner + ' ' + name, fn.args.length + extra);
	}

	/**
	 * Wraps an expression in `Std.string`, for a value the addition would otherwise write as a number.
	 *
	 * @param e The value.
	 * @param pos Where it appears.
	 * @return The wrapped call.
	 */
	function spelled(e:Expr, pos:Position):Expr {
		return {
			e: ECall({e: EField({e: EIdent('Std'), pos: pos}, 'string'), pos: pos}, [e]),
			pos: pos
		};
	}

	/**
	 * The arity a call to a batch method has to be written with.
	 *
	 * @param owner The declaring type's full path, or null when it is not a batch type.
	 * @param name The method being called.
	 * @param given How many arguments the call site supplies, leading ones included.
	 * @return The declared arity when it is larger, otherwise what was given.
	 */
	function padArgs(owner:Null<String>, name:String, given:Int):Int {
		if (owner == null)
			return given;

		var declared:Null<Int> = methodArity.get(owner + ' ' + name);
		return (declared == null || declared <= given) ? given : declared;
	}

	/**
	 * Writes a call's arguments, then a null for each optional the call left off.
	 *
	 * @param params The arguments as written.
	 * @param wanted The arity being written.
	 * @param leading Arguments the caller writes itself before these.
	 * @param line The line to attribute the nulls to.
	 */
	function emitArgs(params:Array<Expr>, wanted:Int, leading:Int, line:Int):Void {
		for (p in params)
			expr(p);

		var i:Int = params.length + leading;
		while (i < wanted) {
			w.pos(line);
			w.token('NULL');
			i++;
		}
	}

	/**
	 * Records which method serves an operator on one of this batch's abstracts.
	 *
	 * Read the same way the interpreter reads it, from `@:op` and `@:arrayAccess`, so the two cannot
	 * drift apart on which field an operator lands in.
	 *
	 * @param owner The abstract's full path.
	 * @param f The field to inspect.
	 */
	function recordOperators(owner:String, f:FieldDecl):Void {
		if (f.meta == null)
			return;

		for (m in f.meta) {
			if (m.name == ':arrayAccess') {
				var args:Int = switch (f.kind) {
					case KFunction(fn): fn.args.length;
					case _: 0;
				}
				abstractOps.set(owner + ' ' + (args > 1 ? '[]=' : '[]'), f.name);
				continue;
			}

			if (m.name != ':op' || m.params == null || m.params.length == 0)
				continue;

			switch (hxscript.syntax.ExprTools.expr(m.params[0])) {
				case EBinop(op, _, _):
					abstractOps.set(owner + ' ' + op, f.name);
				case EUnop(op, _, _):
					abstractOps.set(owner + ' u' + op, f.name);
				case _:
			}
		}
	}

	/**
	 * The abstract method serving an operator, when either operand is one of this batch's abstracts.
	 *
	 * @param op The operator as written.
	 * @param a The left operand.
	 * @param b The right operand, or null for a unary operator.
	 * @return The owning abstract and the method name, or null when no overload applies.
	 */
	function operatorFor(op:String, a:Expr, b:Null<Expr>):Null<{owner:String, name:String}> {
		var owner:Null<String> = abstractTypeOf(a);
		var found:Null<String> = owner == null ? null : abstractOps.get(owner + ' ' + op);
		if (found != null)
			return {owner: owner, name: found};

		if (b == null)
			return null;

		owner = abstractTypeOf(b);
		found = owner == null ? null : abstractOps.get(owner + ' ' + op);
		return found == null ? null : {owner: owner, name: found};
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
	 * The host abstract an expression's type names, when it is one.
	 *
	 * The batch's own abstracts are `abstractTypeOf`'s answer and are reached as statics of the class
	 * this emitter wrote for them. A host one has no such class: what a script holds is the wrapper
	 * the build's macro generated, and its methods are members of that.
	 *
	 * @param e The expression whose type to read.
	 * @return The abstract's path, or null when the value is not one, or is one this batch declared.
	 */
	function hostAbstractOf(e:Expr):Null<String> {
		var declared:Null<String> = instanceClassOf(e);
		if (declared == null)
			declared = typeOf(e);
		if (declared == null)
			declared = inferType(e);
		if (declared == null)
			return null;

		var full:Null<String> = typePaths.exists(declared) ? typePaths.get(declared) : declared;
		if (moduleClasses.exists(full) || moduleAbstracts.exists(full))
			return null;

		return nativeAbstract(full) == null ? null : full;
	}

	/**
	 * The method a host abstract declares for an operator, and which operand it belongs to.
	 *
	 * A host abstract's `@:op` method is a real method of the wrapper class, recorded in the `_ops`
	 * table the interpreter reads through `AbstractTools.opMethod`. Without this the operator lowered
	 * to whatever arithmetic the wrapper happened to support, which is none: `v * 2` on a boxed
	 * vector answered 0 where every interpreter answered the scaled vector.
	 *
	 * Decided from the written types, the same way `operatorFor` decides it for the batch's own
	 * abstracts. A value whose type the emitter cannot name is left to the plain operator, which is
	 * what it was before any of this.
	 *
	 * @param op The operator symbol.
	 * @param a The left operand.
	 * @param b The right operand, or null for a unary one.
	 * @return What to call and on which side, or null when neither operand declares it.
	 */
	function hostOperatorFor(op:String, a:Expr, b:Null<Expr>):Null<{receiver:Expr, other:Null<Expr>, name:String}> {
		var owner:Null<String> = hostAbstractOf(a);
		var found:Null<String> = owner == null ? null : hostOpMethod(owner, op);
		if (found != null)
			return {receiver: a, other: b, name: found};

		/**
		 * The other operand only for a commutative one, because `1 + metres` is the same method as
		 * `metres + 1` and `2 - metres` is not `metres - 2`.
		 */
		if (b == null || (op != '+' && op != '*'))
			return null;

		owner = hostAbstractOf(b);
		found = owner == null ? null : hostOpMethod(owner, op);
		return found == null ? null : {receiver: b, other: a, name: found};
	}

	/**
	 * @param path A host abstract's path.
	 * @param op The operator symbol.
	 * @return The method its wrapper serves that operator with, or null when it declares none.
	 */
	function hostOpMethod(path:String, op:String):Null<String> {
		var wrapper:Null<Class<Dynamic>> = nativeAbstract(path);
		if (wrapper == null)
			return null;

		var ops:Map<String, String> = Reflect.field(wrapper, '_ops');
		return ops == null ? null : ops.get(op);
	}

	/**
	 * @param items A map literal's entries.
	 * @return The map class it builds, by what its keys are.
	 */
	function mapClassOf(items:Array<Expr>):String {
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
					allString = false;
					allInt = false;
			}
		}

		return allString ? 'haxe.ds.StringMap' : (allInt ? 'haxe.ds.IntMap' : 'hxscript.runtime.AnyMap');
	}

	/**
	 * @param known An inferred type name, or null.
	 * @return Whether it names something keyed rather than indexed.
	 */
	function isMapType(known:Null<String>):Bool {
		if (known == null)
			return false;

		return switch (known) {
			case 'Map' | 'haxe.ds.StringMap' | 'haxe.ds.IntMap' | 'haxe.ds.ObjectMap' | 'haxe.ds.EnumValueMap' | 'haxe.ds.WeakMap' |
				'hxscript.runtime.AnyMap': true;
			case _: false;
		}
	}

	/**
	 * The wrapper class standing in for a NATIVE abstract, when the path names one.
	 *
	 * @param path The full type path.
	 * @return The wrapper class, or null when the path is not a wrapped native abstract.
	 */
	function nativeAbstract(path:String):Null<Class<Dynamic>> {
		if (moduleClasses.exists(path) || moduleAbstracts.exists(path))
			return null;

		if (wrappers.exists(path))
			return wrappers.get(path);

		var wrapper:Class<Dynamic> = cast hxscript.types.AbstractTools.resolve(path);
		wrappers.set(path, wrapper);
		return wrapper;
	}

	/**
	 * Folds a constant of a native `enum abstract` into the value it really is.
	 *
	 * @param wrapper The abstract's wrapper class.
	 * @param name The constant.
	 * @return Its underlying value, or null when the field is not a foldable constant.
	 */
	function abstractConstant(wrapper:Class<Dynamic>, name:String):Null<Dynamic> {
		if (Reflect.field(wrapper, 'isEnum') != true)
			return null;

		var getter:Dynamic = Reflect.field(wrapper, 'get_' + name);
		if (!Reflect.isFunction(getter))
			return null;

		var boxed:Dynamic = null;

		try {
			boxed = Reflect.callMethod(wrapper, getter, []);
		} catch (e:haxe.Exception) {
			return null;
		}

		if (boxed == null)
			return null;

		var value:Dynamic = hxscript.types.AbstractTools.isAbstract(boxed) ? boxed.__a : boxed;

		return switch (Type.typeof(value)) {
			case TInt | TFloat | TBool: value;
			case TClass(cls) if (cls == String): value;
			case _: null;
		}
	}

	/**
	 * Writes a folded constant.
	 *
	 * @param value An `Int`, `Float`, `Bool` or `String`.
	 * @param line The source line to attribute it to.
	 */
	function emitConstant(value:Dynamic, line:Int):Void {
		w.pos(line);

		switch (Type.typeof(value)) {
			case TInt:
				w.token('i');
				w.int(value);
			case TFloat:
				w.token('f');
				w.str(Std.string(value));
			case TBool:
				w.token(value == true ? 'true' : 'false');
			case _:
				w.token('s');
				w.str(Std.string(value));
		}
	}

	/**
	 * Resolves a name to a class this batch declares.
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

			w.type(path);
			return;
		}

		var stands:String = proxied(path);

		if (external.exists(stands))
			throw new Unsupported('uses $stands, which is compiled elsewhere', null);
		if (!resolvable(stands))
			throw new Unsupported('uses $stands, which nothing at runtime answers to', null);

		w.type(stands);
	}

	/**
	 * The class that really answers for a name the host stands something else in for.
	 *
	 * `Config.typeProxy` binds `Std`, `Type` and `Reflect` to this library's own versions, and the
	 * interpreter resolves a script's use of those names through it. Compiled code linked the native
	 * class instead, so the two disagreed about the same call: `Std.string` of a boxed abstract
	 * printed the wrapper's class name where the interpreter printed the value, because opening the
	 * box is exactly what the proxy is for.
	 *
	 * @param path The name as the script wrote it.
	 * @return The class standing in for it, or the path unchanged when nothing does.
	 */
	function proxied(path:String):String {
		var stand:Dynamic = hxscript.Config.typeProxy.get(path);
		if (stand == null)
			return path;

		var name:Null<String> = Type.getClassName(stand);
		return name == null ? path : name;
	}

	/**
	 * Whether a name reaches a type that exists once the module is loaded.
	 *
	 * The host lists the scripted classes it keeps elsewhere, but it lists them by MODULE, and a
	 * module names only one of the types it declares: an abstract beside an enum in `w.Colour` was
	 * never on that list, so a reference to it passed every check and was written out. cppia resolves
	 * an unknown name to null and then uses it without looking, which is a crash rather than a
	 * refusal, so a name nothing answers to is refused here instead.
	 *
	 * Only the host build's own table is consulted. `Type.resolveClass` would also answer, but it
	 * answers for every class an EARLIER cppia load registered, and those are precisely the ones a
	 * new module cannot link against: the reference would look sound and reach a dead module's class.
	 *
	 * @param path The type being referenced.
	 * @return True when something at runtime carries that name.
	 */
	function resolvable(path:String):Bool {
		if (path == null || path.length == 0)
			return true;

		var known:Null<Bool> = resolvedTypes.get(path);
		if (known != null)
			return known;

		var infos:Array<hxscript.types.TypeCollection.TypeInfo> = hxscript.types.TypeCollection.main.fromCompilePath(path);
		if (infos == null || infos.length == 0)
			infos = hxscript.types.TypeCollection.main.fromPath(path);

		var found:Bool = infos != null && infos.length > 0;

		resolvedTypes.set(path, found);
		return found;
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
	 * A host may hand scripts a name that is neither a local, a field, nor a type, such as a helper
	 * it injects into every interpreter. Compiled code has no interpreter to inject into, so the name
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

	/**
	 * Records what an `import` puts in scope, which is a type or a static of one.
	 *
	 * `import pack.Type.field` binds a name that is a field of something rather than a type. Read as
	 * a type it named a path with no class behind it, and what was emitted for it was `CLASSOF` of
	 * that path, which evaluates to null: the script's name answered null with nothing said about it,
	 * where the interpreter answered the field's value.
	 *
	 * Resolving the shorter path is what separates the two. A path that answers nothing stays a type
	 * import, so a name that really is unknown is still refused where it is used rather than here.
	 *
	 * @param path The imported path's segments.
	 * @param short The name it binds.
	 */
	function recordImport(path:Array<String>, short:String):Void {
		var full:String = path.join('.');

		if (path.length > 1 && hxscript.types.TypeTools.resolve(full) == null) {
			var owner:String = path.slice(0, path.length - 1).join('.');
			var field:String = path[path.length - 1];
			var held:Dynamic = hxscript.types.TypeTools.resolve(owner);

			if (held != null && Type.getClassFields(held).indexOf(field) >= 0) {
				ambientMembers.set(short, owner + '::' + field);
				return;
			}
		}

		typePaths.set(short, full);
		bindConstructors(full);
	}

	/**
	 * Records the bare names an import puts in scope beyond the type's own.
	 *
	 * Importing an enum makes its constructors reachable unqualified, and importing an enum abstract
	 * does the same for its constants: `import haxe.ds.Option;` then `None`, `import HostFlag;` then
	 * `Add`. The interpreter binds both when it processes the import, and this table did not, so a
	 * module written the ordinary way was refused over `unresolved identifier None`.
	 *
	 * A name already bound is left alone, so an earlier import and a module's own declarations both
	 * keep the meaning they had.
	 *
	 * @param full The imported type's path.
	 */
	function bindConstructors(full:String):Void {
		var wrapper:Null<Class<Dynamic>> = hxscript.types.AbstractTools.resolve(full);

		if (wrapper != null) {
			if (Reflect.field(wrapper, 'isEnum') != true)
				return;

			for (name in hxscript.types.AbstractTools.getEnumConstructs(cast wrapper)) {
				if (!importedFields.exists(name))
					importedFields.set(name, full);
			}

			return;
		}

		/**
		 * The compile path rather than the written one, since an enum reached through a typedef
		 * answers to a different name than the import spells, and that is the name a `FSTATIC` on it
		 * has to carry.
		 */
		var path:String = nativePath(full);
		if (!resolvable(path))
			return;

		var en:Enum<Dynamic> = Type.resolveEnum(path);
		if (en == null)
			return;

		for (name in Type.getEnumConstructs(en)) {
			if (!importedFields.exists(name))
				importedFields.set(name, path);
		}
	}

	/**
	 * Records a `using` type, indexing the statics it puts in scope.
	 *
	 * @param path The type path named by the `using`.
	 */
	function recordUsing(path:String):Void {
		var owner:Dynamic = hxscript.types.TypeTools.resolve(path);
		if (owner == null)
			return;

		var full:String = Type.getClassName(owner);
		if (full == null)
			return;

		for (field in Type.getClassFields(owner)) {
			if (!usingStatics.exists(field))
				usingStatics.set(field, full);

			var declaring:Array<String> = usingOwners.get(field);
			if (declaring == null) {
				declaring = [];
				usingOwners.set(field, declaring);
			}

			if (declaring.indexOf(full) < 0)
				declaring.push(full);
		}
	}

	/**
	 * Rewrites a static-extension call into the plain static call it stands for.
	 *
	 * Only when the receiver's type is known and demonstrably has no such member. A refusal costs the
	 * module its bytecode and nothing else, while rewriting a call that was really a member call
	 * would change what the program does. Anything this cannot establish is left to the refusal.
	 *
	 * @param obj The receiver.
	 * @param name The method name.
	 * @param params The call arguments.
	 * @param pos Where it appears.
	 * @return The rewritten call, or null when the shape cannot be established.
	 */
	function usingCall(obj:Expr, name:String, params:Array<Expr>, pos:Position):Null<Expr> {
		if (!usingStatics.exists(name))
			return null;

		var declared:Null<String> = inferType(obj);
		if (declared == null)
			return null;

		if (declaredClass(declared) != null)
			return null;

		var host:Dynamic = hxscript.types.TypeTools.resolve(declared);
		if (host == null)
			return null;

		var fields:Array<String> = Type.getInstanceFields(host);
		if (fields == null || fields.length == 0 || fields.indexOf(name) >= 0)
			return null;

		var owner:Expr = {e: EIdent(usingStatics.get(name)), pos: pos};
		return {e: ECall({e: EField(owner, name, false), pos: pos}, [obj].concat(params)), pos: pos};
	}

	/**
	 * Rewrites `a ?? b` into a null test, which is the only form cppia has.
	 *
	 * The left side is bound to a temporary unless repeating it is free, because `??` evaluates it
	 * once and a naive `a != null ? a : b` would evaluate a call twice.
	 *
	 * @param e1 The value to prefer.
	 * @param e2 The fallback.
	 * @param pos Where it appears.
	 * @return The equivalent expression.
	 */
	function nullCoalesce(e1:Expr, e2:Expr, pos:Position):Expr {
		var nul:Expr = {e: EIdent('null'), pos: pos};

		if (sideEffectFree(e1))
			return {e: ETernary({e: EBinop('!=', e1, nul), pos: pos}, e1, e2), pos: pos};

		var name:String = tempName('nc');
		var ref:Expr = {e: EIdent(name), pos: pos};

		return {
			e: EBlock([
				{e: EVar(name, null, e1, null, null, false), pos: pos},
				{e: ETernary({e: EBinop('!=', ref, nul), pos: pos}, ref, e2), pos: pos}
			]),
			pos: pos
		};
	}

	/**
	 * Flattens an or-pattern into the alternatives it stands for.
	 *
	 * `case a | b:` parses as one `EBinop('|')`, which the interpreter reads as two patterns and
	 * cppia's `SWITCH` would read as a bitwise or. Splitting it here keeps the two in agreement.
	 *
	 * @param e The case value.
	 * @param out Collects each alternative.
	 */
	function flattenOr(e:Expr, out:Array<Expr>):Void {
		switch (e.e) {
			case EBinop('|', a, b):
				flattenOr(a, out);
				flattenOr(b, out);

			case _:
				out.push(e);
		}
	}

	/** Whether an increment target can be evaluated twice, which the long-hand rewrite needs. */
	function repeatableField(e:Expr):Bool {
		switch (e.e) {
			case EField(obj, _, maybe):
				if (maybe == true)
					return false;

				return obj.e.match(EIdent('this')) || sideEffectFree(obj);

			case EIdent(name):
				if (lookupVar(name) != null)
					return false;

				return members.exists(name) || statics.exists(name);

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
				if (lookupVar(v) != null || members.exists(v) || statics.exists(v) || moduleFields.exists(v))
					return null;
				if (typePaths.exists(v))
					return typePaths.get(v);
				return worldType(v);

			case EField(_, _, _):
				var path:Null<String> = dottedPath(e);
				if (path != null && moduleClasses.exists(path))
					return path;
				return hostTypePath(path);

			case _:
				return null;
		}
	}

	/**
	 * A closure that calls the base's method, which is what `super.m` means as a value.
	 *
	 * @param name The method.
	 * @param arity How many arguments it takes.
	 * @param pos Where it is named.
	 * @return A function expression wrapping the super call.
	 */
	function superClosure(name:String, arity:Int, pos:Position):Expr {
		var args:Array<Argument> = [for (i in 0...arity) {name: '__super' + i}];
		var passed:Array<Expr> = [for (a in args) {e: EIdent(a.name), pos: pos}];

		var call:Expr = {
			e: ECall({e: EField({e: EIdent('super'), pos: pos}, name, false), pos: pos}, passed),
			pos: pos
		};

		return {e: EFunction(args, {e: EReturn(call), pos: pos}, null, null), pos: pos};
	}

	/**
	 * @param path The dotted name, or null when the chain was not all plain names.
	 * @return The path when the host has that type, otherwise null.
	 */
	/**
	 * A bare name the world carries a type for, which this module's imports never mentioned.
	 *
	 * cppia placed a host name through **what the module imported** and nothing else, so anything the
	 * import table did not literally hold was unresolved. Two ordinary things fall in that gap: a
	 * secondary type of an imported module, since `import HostShaped;` brings in every type
	 * `HostShaped.hx` declares and the table only ever held the one it is named for; and a host type
	 * named without an import at all. The interpreter resolves both, out of the world's own type
	 * index, so a module doing either was refused over a name that was never in doubt.
	 *
	 * Only the host build's own table, for the reason `resolvable` gives: `Type.resolveClass` also
	 * answers for every class an EARLIER cppia load registered, and those are precisely the ones a
	 * new module cannot link against.
	 *
	 * **Asked last and never first.** A local, a member, a static, a module field and an import all
	 * answer ahead of this, so a name a module binds itself keeps the meaning that module gave it.
	 *
	 * @param name The bare name as written.
	 * @return Its compile path, or null when nothing in the world carries that name.
	 */
	function worldType(name:String):Null<String> {
		if (name == null || name.length == 0 || !hxscript.types.TypeTools.isTypeIdentifier(name))
			return null;

		var known:Null<String> = worldTypes.get(name);
		if (known != null)
			return known.length == 0 ? null : known;

		var infos:Array<hxscript.types.TypeCollection.TypeInfo> = hxscript.types.TypeCollection.main.fromPath(name);
		if (infos == null || infos.length == 0)
			infos = hxscript.types.TypeCollection.main.fromCompilePath(name);

		var found:String = (infos == null || infos.length == 0) ? '' : nativePath(name);
		worldTypes.set(name, found);
		return found.length == 0 ? null : found;
	}

	function hostTypePath(path:Null<String>):Null<String> {
		if (path == null || path.indexOf('.') < 0)
			return null;

		var root:String = path.substr(0, path.indexOf('.'));
		if (lookupVar(root) != null || members.exists(root) || statics.exists(root) || moduleFields.exists(root))
			return null;

		var infos:Array<hxscript.types.TypeCollection.TypeInfo> = hxscript.types.TypeCollection.main.fromPath(path);
		if (infos == null || infos.length == 0)
			infos = hxscript.types.TypeCollection.main.fromCompilePath(path);

		return (infos != null && infos.length > 0) ? path : null;
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
	 * @throws Unsupported If nothing of that name can be found.
	 */
	function resolveType(name:String, pos:Position):String {
		if (typePaths.exists(name))
			return nativePath(typePaths.get(name));
		if (name.indexOf('.') >= 0)
			return nativePath(name);

		var world:Null<String> = worldType(name);
		if (world != null)
			return world;

		throw new Unsupported('unresolved type ' + name, pos);
	}

	/**
	 * Follows a typedef to the class it aliases, which is the only spelling cppia can load.
	 *
	 * A typedef has no runtime class. `import flixel.group.FlxSpriteGroup` puts that path in the
	 * table, so `new FlxSpriteGroup()` emitted `NEW flixel.group.FlxSpriteGroup`, a name nothing
	 * answers to, and the loader resolved it to null. Interpreted that is a reported error; under
	 * the hxcpp JIT it was a null dereference during code generation, which ends the process with
	 * no message, because the JIT reads the resolved type without checking it.
	 *
	 * Aliases are followed to the end rather than one step, since a typedef may name another.
	 *
	 * @param path The path as written or imported.
	 * @return The aliased class's compile path, or the path unchanged when it is not a typedef.
	 */
	function nativePath(path:String):String {
		var seen:Int = 0;
		var current:String = path;

		while (seen < TYPEDEF_DEPTH) {
			var infos:Array<hxscript.types.TypeCollection.TypeInfo> = hxscript.types.TypeCollection.main.fromPath(current);
			if (infos == null || infos.length == 0)
				infos = hxscript.types.TypeCollection.main.fromCompilePath(current);
			if (infos == null || infos.length == 0)
				return current;

			var info = infos[0];
			if (info.typedefType == null)
				return hxscript.types.TypeCollection.compilePath(info);

			current = hxscript.types.TypeCollection.compilePath(info.typedefType);
			seen++;
		}

		return current;
	}

	/** The dotted path a type annotation names, or the empty string when it is not a plain path. */
	function typeName(t:CType):String {
		switch (t) {
			case CTPath(path, params):
				var joined:String = path.join('.');
				if (joined == 'Array')
					return arrayTypeName(params);

				if (joined == 'Null')
					return '';

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
	function arrayTypeName(params:Null<Array<CType>>):String {
		if (params == null || params.length != 1)
			return 'Array';

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
		scopeWritten.push(new StringMap());
	}

	/** Closes the innermost scope. */
	inline function popScope():Void {
		scopes.pop();
		scopeTypes.pop();
		scopeWritten.pop();
	}

	/**
	 * Binds a name to a fresh variable id.
	 *
	 * @param name The variable name.
	 * @param type Its declared type, if annotated.
	 * @return The variable id.
	 */
	function declareVar(name:String, ?type:String, ?written:String):Int {
		var id:Int = nextVarId++;
		if (scopes.length == 0)
			pushScope();
		scopes[scopes.length - 1].set(name, id);
		if (type != null && type.length > 0)
			scopeTypes[scopeTypes.length - 1].set(name, type);

		var said:Null<String> = (written != null && written.length > 0) ? written : type;
		if (said != null && said.length > 0)
			scopeWritten[scopeWritten.length - 1].set(name, said);

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

	/** The type a local was written as, whatever its slot holds, or null when it was written none. */
	function writtenVarType(name:String):Null<String> {
		var i:Int = scopeWritten.length - 1;
		while (i >= 0) {
			var found:Null<String> = scopeWritten[i].get(name);
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
		if (e == null)
			return null;

		switch (e.e) {
			case EConst(CString(_, _)):
				return 'String';

			case EConst(CInt(_)):
				return 'Int';

			case EConst(CFloat(_)):
				return 'Float';

			case EIdent('true') | EIdent('false'):
				return 'Bool';

			case EIdent(v):
				if (lookupVar(v) != null)
					return lookupVarType(v);
				if (members.exists(v))
					return memberTypes.get(v);
				if (statics.exists(v))
					return staticTypes.get(v);
				return null;

			case EArrayDecl(items) if (items.length > 0 && items[0].e.match(EBinop('=>', _, _))):
				return mapClassOf(items);

			case EUnop('!', _, _):
				return 'Bool';

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

			case EBinop(op, _, _) if (COMPARISONS.indexOf(op) >= 0):
				return 'Bool';

			case EBinop(op, a, b):
				var over:Null<{owner:String, name:String}> = operatorFor(op, a, b);
				if (over == null)
					return null;

				var rets:Null<StringMap<String>> = methodReturns.get(over.owner);
				return rets == null ? null : rets.get(over.name);

			case EArray(arr, _):
				var named:Null<String> = arrayElements.get(varNameOf(arr));
				return named;

			case ECall(callee, _):
				switch (callee.e) {
					case EField(obj, name, _):
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
