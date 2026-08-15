package hxscript.macro;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.Type;

using Lambda;
using StringTools;
using haxe.macro.TypeTools;
using haxe.macro.ExprTools;
using haxe.macro.ComplexTypeTools;
#end

/**
 * The heart of the scripting bridge. Applied (via `@:autoBuild` on `IScriptedInstance`) to a generated bridge
 * class, it makes a native base class scriptable: it overrides each inherited, non-inline, non-final method
 * to route through the instance's interpreter when the script defines an override, records which fields are
 * inlined/unexposed, reconstructs the native constructor as `__constructSuper`, and implements the reflection
 * hooks. It also keeps a registry of every native class that has a bridge, exposed by `listScriptedClasses`.
 */
class Scripted {
	/** Field names reserved by the bridge machinery; a script may not declare them. */
	public static var ignoreFields:Array<String> = [
		'reflectHasField',
		'reflectGetField',
		'reflectSetField',
		'reflectListFields',
		'reflectGetProperty',
		'reflectSetProperty',
		'typeCreateInstance',
		'typeGetClass',
		'typeGetClassFields',
		'typeCreateEmptyInstance',
		'typeGetInstanceFields',
		'__scriptConstruct',
		'__constructSuper',
		'__interp',
		'__base',
		'__safe',
		'__func',
		'__fields',
		'__vars',
		'__slots',
		'instanceFields',
		'inlinedFields',
		'unexposedFields',
		'new',
		'super'
	];

	/** This macro class's own fully-qualified name (used to stash the scripted-class registry). */
	static var _name:String = 'hxscript.macro.Scripted';

	/**
	 * Generates the scripting bridge for the class being built: overrides inherited methods to defer
	 * to the interpreter, reconstructs the native constructor, records inlined/unexposed fields, and
	 * adds the reflection hooks.
	 *
	 * @return The generated fields to add to the bridge class.
	 */
	public static macro function build():Array<Field> {
		var pos = Context.currentPos();
		var cls = Context.getLocalClass().get();
		var fields:Array<Field> = Context.getBuildFields();

		if (Context.defined('hxscript_verbose'))
			Context.info('Preparing ${cls.name}', pos);

		cls.meta.add(':access', [macro hxscript.Module], pos);
		cls.meta.add(':access', [macro hxscript.runtime.Interp], pos);
		cls.meta.add(':access', [macro hxscript.types.ScriptedClass], pos);

		var knownFields:Array<String> = [];
		var inlinedFields:Array<String> = [];
		var omittedFields:Array<String> = [];

		/**
		 * A type's readable path, without repeating the module when the type is its main one.
		 *
		 * @param module The module path.
		 * @param name The type's own name.
		 * @return `pack.Module` or `pack.Module.Name`.
		 */
		function typePath(module:String, name:String):String {
			return (module == name || module.endsWith('.$name')) ? module : '$module.$name';
		}

		/**
		 * Converts a typed `Type` to the `ComplexType` the bridge declares.
		 *
		 * `Type.toComplexType()` renders a sub-module type as `pack.SubType`, dropping the module that
		 * actually holds it (`pack.Module.SubType`), which then fails to resolve. Paths are rebuilt
		 * from the module so `sub` is filled in, recursing through type parameters.
		 *
		 * @param t The type to convert.
		 * @return The equivalent complex type.
		 */
		function toCT(t:Type):ComplexType {
			/**
			 * Builds a path from a type's MODULE rather than its package, so a sub-module type keeps its
			 * qualifier and does not collapse onto a same-named type at the package root.
			 *
			 * @param pack The type's package.
			 * @param module Its module path.
			 * @param name Its own name.
			 * @param params Its type parameters.
			 * @return The qualified path.
			 */
			function fromModule(pack:Array<String>, module:String, name:String, params:Array<Type>):ComplexType {
				var parts:Array<String> = module.split('.');
				var moduleName:String = parts.pop();

				return TPath({
					pack: parts,
					name: moduleName,
					sub: (moduleName == name ? null : name),
					params: [for (p in params) TPType(toCT(p))]
				});
			}

			return switch (t) {
				case TInst(r, params):
					var c = r.get();
					switch (c.kind) {
						case KTypeParameter(_): t.toComplexType();
						default: fromModule(c.pack, c.module, c.name, params);
					}
				case TEnum(r, params):
					var c = r.get();
					fromModule(c.pack, c.module, c.name, params);
				case TAbstract(r, params):
					var c = r.get();
					fromModule(c.pack, c.module, c.name, params);
				case TType(r, params):
					var c = r.get();
					fromModule(c.pack, c.module, c.name, params);
				case TFun(fargs, fret):
					TFunction([for (a in fargs) a.opt ? TOptional(toCT(a.t)) : toCT(a.t)], toCT(fret));
				default:
					t.toComplexType();
			}
		}

		/**
		 * Whether a type, and everything it is parameterised by, can be named from generated code.
		 *
		 * A `private` type (`openfl.events.EventDispatcher`'s internal `Listener`) cannot be referenced
		 * by path, so a method mentioning one cannot be overridden and falls through to super.
		 *
		 * @param t The type to test, or null.
		 * @return Whether it is nameable.
		 */
		function typeAccessible(t:Type):Bool {
			if (t == null)
				return true;

			return switch (t) {
				case TInst(r, params): !r.get().isPrivate && !params.exists(function(p) return !typeAccessible(p));
				case TEnum(r, params): !r.get().isPrivate && !params.exists(function(p) return !typeAccessible(p));
				case TAbstract(r, params): !r.get().isPrivate && !params.exists(function(p) return !typeAccessible(p));
				case TType(r, params): !r.get().isPrivate && !params.exists(function(p) return !typeAccessible(p));
				case TFun(fargs, fret): typeAccessible(fret) && !fargs.exists(function(a) return !typeAccessible(a.t));
				case TLazy(f): typeAccessible(f());
				default: true;
			}
		}

		var constructorExpr:Expr = null;
		var hasConstructor:Bool = false;

		/** Set when the base must be constructed by Haxe rather than rebuilt, and with what arguments. */
		var nativeSuper:Bool = false;
		var nativeSuperArgs:Array<{name:String, opt:Bool, t:Type}> = null;
		var hasToString:Bool = false;

		/**
		 * Emits the bridge fields for one class in the chain, binding its type parameters to the
		 * concrete types the subclass supplied.
		 *
		 * @param type The class being bridged.
		 * @param types The concrete type arguments, if any.
		 */
		function setFields(type:ClassType, ?types:Array<Type>) {
			var typeFields:Array<ClassField> = type.fields.get();

			var generics:Map<String, ComplexType> = [];
			if (types != null) {
				for (i => t in types) {
					var classParam = type.params[i];
					switch (t.follow()) {
						default:
						case TInst(t, p):
							switch (t.get().kind) {
								default:
								case KTypeParameter(t):
									generics.set(classParam.name, toCT(t[0].follow()));
									continue;
							}
					}
					generics.set(classParam.name, toCT(t.follow()));
				}
			}

			if (!hasConstructor && (type.constructor != null || type.superClass != null)) {
				/**
				 * The dotted path a static must be reached through, module-qualified so sub-module and
				 * abstract-impl types keep the right name (`flixel.math.FlxRect`, not `FlxRect_Impl_`).
				 *
				 * @param c The declaring class.
				 * @param fieldName The static's name.
				 * @return The path segments to emit.
				 */
				function staticOwnerPath(c:ClassType, fieldName:String):Array<String> {
					var parts:Array<String> = c.module.split('.');
					var moduleName:String = parts.pop();
					var n:String = c.name;
					if (n.endsWith('_Impl_'))
						n = moduleName;

					var path:Array<String> = parts.concat([moduleName]);
					if (moduleName != n)
						path.push(n);
					path.push(fieldName);
					return path;
				}

				/**
				 * Re-emits a typed expression as untyped syntax, requalifying every type it names so the
				 * result compiles in the generated bridge rather than in its original module.
				 *
				 * @param e The typed expression.
				 * @return The re-emittable expression.
				 */
				function mapTyped(e:TypedExpr):Expr {
					return switch (e.expr) {
						case TNew(c, tp, params):
							var c = c.get();

							var parts:Array<String> = c.module.split('.');
							var moduleName:String = parts.pop();
							var n:String = c.name;
							if (n.endsWith('_Impl_'))
								n = moduleName;

							{
								pos: pos,
								expr: ENew({
									pack: parts,
									name: moduleName,
									sub: (moduleName == n ? null : n),
									params: [for (p in tp) TPType(toCT(p))]
								}, [
									for (param in params) {
										switch (param.t) {
											case TAbstract(a, p):
												if (a.get().name != 'Null') {
													mapTyped(param);
												} else {
													continue;
												}
											default:
												mapTyped(param);
										}
									}
								])
							};
						case TCall({expr: TField(_, FStatic(c, cf))}, params):
							{
								pos: pos,
								expr: ECall(macro $p{staticOwnerPath(c.get(), cf.get().name)}, [for (p in params) mapTyped(p)])
							};
						default:
							Context.getTypedExpr(e);
					}
				}

				/**
				 * Puts the concrete type in place of a base's parameter, which a rebuilt body still names.
				 *
				 * `new FlxTypedGroup<T>(size)` in a constructor being re-emitted keeps its `T`, and the
				 * bridge is not generic, so the name means nothing there.
				 *
				 * @param t A type the rebuilt body mentions.
				 * @return It, with any parameter of the base replaced by what was bound for it.
				 */
				function boundFor(name:String):Null<ComplexType> {
					if (generics.exists(name))
						return generics.get(name);

					var short:String = name.substr(name.lastIndexOf('.') + 1);
					if (generics.exists(short))
						return generics.get(short);

					/** A parameter is keyed by whatever declared it, so `T` and `Owner.T` are one name. */
					for (key => bound in generics)
						if (key.substr(key.lastIndexOf('.') + 1) == short)
							return bound;

					return null;
				}

				function bindType(t:ComplexType):ComplexType {
					return switch (t) {
						case TPath(p):
							var bound:Null<ComplexType> = (p.pack.length == 0 && p.sub == null && p.params.length == 0) ? boundFor(p.name) : null;

							if (bound != null)
								bound;
							else
								TPath({
									pack: p.pack,
									name: p.name,
									sub: p.sub,
									params: [
										for (q in p.params)
											switch (q) {
												case TPType(inner): TPType(bindType(inner));
												default: q;
											}
									]
								});

						case TOptional(inner): TOptional(bindType(inner));
						case TNamed(n, inner): TNamed(n, bindType(inner));
						case TFunction(from, to): TFunction([for (a in from) bindType(a)], bindType(to));
						case TParent(inner): TParent(bindType(inner));
						default: t;
					}
				}

				/** @param params A type path's parameters. @return Them, with the base's bound. */
				function bindParams(params:Array<TypeParam>):Array<TypeParam> {
					return [
						for (q in params)
							switch (q) {
								case TPType(inner): TPType(bindType(inner));
								default: q;
							}
					];
				}

				/**
				 * Repairs the things `Context.getTypedExpr` cannot round-trip.
				 *
				 * @param typed The expression as the typer left it.
				 * @param e The same expression re-emitted as syntax.
				 * @return The syntax, repaired.
				 */
				function requalify(typed:TypedExpr, e:Expr):Expr {
					var qualified:Map<String, TypePath> = [];
					var abstractOf:Map<String, Array<String>> = [];

					function collect(t:TypedExpr):Void {
						if (t == null)
							return;

						switch (t.expr) {
							case TNew(c, _, _):
								var cls:ClassType = c.get();
								var parts:Array<String> = cls.module.split('.');
								var moduleName:String = parts.pop();

								var name:String = cls.name.endsWith('_Impl_') ? cls.name.substr(0, cls.name.length - 6) : cls.name;

								if (!qualified.exists(cls.name))
									qualified.set(cls.name, {pack: parts, name: moduleName, sub: (moduleName == name ? null : name)});

							case TField(_, FStatic(c, _)) | TTypeExpr(TClassDecl(c)):
								var cls:ClassType = c.get();

								if (cls.name.endsWith('_Impl_') && !abstractOf.exists(cls.name)) {
									switch (cls.kind) {
										case KAbstractImpl(a):
											var ab:AbstractType = a.get();
											var parts:Array<String> = ab.module.split('.');

											if (parts[parts.length - 1] != ab.name)
												parts.push(ab.name);

											abstractOf.set(cls.name, parts);
										default:
									}
								}

							default:
						}

						haxe.macro.TypedExprTools.iter(t, collect);
					}

					collect(typed);

					function implName(x:Expr):Null<String> {
						return switch (x.expr) {
							case EField(_, name, _) if (name.endsWith('_Impl_')): name;
							case EConst(CIdent(name)) if (name.endsWith('_Impl_')): name;
							default: null;
						}
					}

					function fix(x:Expr):Expr {
						return switch (x.expr) {
							case ENew(t, params):
								var q:TypePath = (t.pack.length == 0 && t.sub == null && qualified.exists(t.name)) ? qualified.get(t.name) : t;
								{
									pos: x.pos,
									expr: ENew({pack: q.pack, name: q.name, sub: q.sub, params: bindParams(t.params)}, [for (p in params) fix(p)])
								};

							case ECheckType(inner, t):
								{pos: x.pos, expr: ECheckType(fix(inner), bindType(t))};

							case ECast(inner, t) if (t != null):
								{pos: x.pos, expr: ECast(fix(inner), bindType(t))};

							case EField(owner, member, kind) if (implName(owner) != null && abstractOf.exists(implName(owner))):
								{pos: x.pos, expr: EField(macro $p{abstractOf.get(implName(owner))}, member, kind)};

							/**
							 * Puts back the `untyped` that typing took off a target's own magic.
							 *
							 * HashLink's `Std.int` is `untyped $int(x)`, and once inlined into a rebuilt
							 * constructor `$int` is a name no source outside `untyped` may write.
							 */
							case ECall({expr: EConst(CIdent(name))}, params) if (name.startsWith('$')):
								{
									pos: x.pos,
									expr: EUntyped({
										pos: x.pos,
										expr: ECall({pos: x.pos, expr: EConst(CIdent(name))}, [for (p in params) fix(p)])
									})
								};

							case EConst(CIdent(name)) if (name.indexOf('`') >= 0):
								{pos: x.pos, expr: EConst(CIdent(name.replace('`', '_')))};

							case EVars(vars):
								{
									pos: x.pos,
									expr: EVars([
										for (v in vars)
											{
												name: v.name.replace('`', '_'),
												type: v.type == null ? null : bindType(v.type),
												expr: v.expr == null ? null : fix(v.expr),
												isFinal: v.isFinal,
												isStatic: v.isStatic,
												meta: v.meta
											}
									])
								};

							default:
								x.map(fix);
						}
					}

					return fix(e);
				}

				/**
				 * @param type A class being bridged.
				 * @return The arguments of the nearest constructor at or above it, which is what a `super`
				 *         call written in its own bridge has to pass.
				 */
				function superArgumentsOf(type:ClassType):Array<{name:String, opt:Bool, t:Type}> {
					var at:Null<ClassType> = type;

					while (at != null) {
						if (at.constructor != null) {
							var found:Null<Array<{name:String, opt:Bool, t:Type}>> = switch (at.constructor.get().type) {
								case TFun(fargs, _): fargs;
								case TLazy(lazy):
									switch (lazy()) {
										case TFun(fargs, _): fargs;
										default: null;
									}
								default: null;
							}

							if (found != null)
								return found;
						}

						at = at.superClass == null ? null : at.superClass.t.get();
					}

					return [];
				}

				/**
				 * @param path A dotted type path.
				 * @return It with every segment capitalised and the dots dropped, as `Bridges` names them.
				 */
				function flatten(path:String):String {
					var out:String = '';

					for (part in path.split('.'))
						out += part.length == 0 ? '' : part.charAt(0).toUpperCase() + part.substr(1);

					return out;
				}

				/**
				 * @param type A base whose constructor cannot be rebuilt.
				 * @return The path of a hand-written initializer for it, or null when there is none.
				 */
				function shimFor(type:ClassType):Null<Array<String>> {
					var path:String = 'hxscript.shim.' + flatten(typePath(type.module, type.name));

					/**
					 * Asked inside a `try`, because a type that is not there is an error rather than a
					 * null, and having no shim is the ordinary case for every base that never needed one.
					 */
					try {
						switch (Context.getType(path)) {
							case TInst(c, _):
								for (field in c.get().statics.get())
									if (field.name == 'init')
										return path.split('.').concat(['init']);
							default:
						}
					} catch (e:Dynamic) {}

					return null;
				}

				/**
				 * Why a native constructor cannot be rebuilt in the bridge, or null when it can.
				 *
				 * @param e The typed constructor body.
				 * @return The reason, or null if the body is re-emittable.
				 */
				function reemittableConstructor(e:TypedExpr):Null<String> {
					if (e == null)
						return null;

					var reason:Null<String> = null;

					function why(cls:ClassType, verb:String):Null<String> {
						if (cls.name.endsWith('_Impl_'))
							return null;
						if (cls.isPrivate)
							return 'it $verb ${typePath(cls.module, cls.name)}, which is private';
						return null;
					}

					function look(t:TypedExpr):Void {
						if (t == null || reason != null)
							return;

						switch (t.expr) {
							case TNew(c, _, _):
								reason = why(c.get(), 'constructs');

							case TTypeExpr(TClassDecl(c)):
								var cls:ClassType = c.get();

								if (cls.name.endsWith('_Impl_'))
									reason = 'it names the implementation of abstract ${cls.module}, which is reachable under no name';
								else
									reason = why(cls, 'names');

							case TField(_, FStatic(c, cf)):
								var cls:ClassType = c.get();

								if (cls.name.endsWith('_Impl_')) {
									if (cf.get().meta.has(':impl'))
										reason = 'it calls ${cf.get().name} on abstract ${cls.module}, which has no form reachable from outside';

									return;
								}

								reason = why(cls, 'reads a static of');

							case TBinop(OpAssign | OpAssignOp(_), {expr: TLocal(v)}, _) if (v.name == 'this'):
								reason = 'it inlines an abstract\'s constructor, which assigns to `this`';

							default:
						}

						if (reason == null)
							haxe.macro.TypedExprTools.iter(t, look);
					}

					look(e);
					return reason;
				}

				/**
				 * Whether a typed initializer references `this` anywhere.
				 *
				 * Such an initializer cannot be re-emitted into the constructor: either it reads instance
				 * state that is not set up yet, or (for an inlined abstract like `FlxPoint.get`) its body
				 * assigns to `this`, which is illegal outside that abstract.
				 *
				 * @param e The expression to test, or null.
				 * @return Whether `this` is reached.
				 */
				function referencesThis(e:TypedExpr):Bool {
					if (e == null)
						return false;

					switch (e.expr) {
						case TConst(TThis):
							return true;
						case TLocal(v) if (v.name == 'this'):
							return true;
						default:
					}

					var found:Bool = false;
					haxe.macro.TypedExprTools.iter(e, function(sub) {
						if (referencesThis(sub))
							found = true;
					});
					return found;
				}

				/**
				 * Whether a field initializer can be lifted into the bridge as-is.
				 *
				 * A pooled initializer such as `_lastClipRect = FlxRect.get(Math.NaN)` inlines to a block
				 * calling PRIVATE pool helpers. Those must still run, or the field stays null and the sprite
				 * crashes in `draw`, so a re-emitted init is wrapped in `@:privateAccess`.
				 *
				 * @param e The initializer, or null.
				 * @return Whether it is safe to re-emit.
				 */
				function reemittable(e:TypedExpr):Bool {
					return e != null && !referencesThis(e);
				}

				/**
				 * Collects a class's member initializers, which run before its constructor body and would
				 * otherwise be lost when the constructor chain is rebuilt.
				 *
				 * @param type The class to collect from.
				 * @return The initializer assignments.
				 */
				function fieldInits(type:ClassType):Array<Expr> {
					var inits:Array<Expr> = [];

					if (type == cls)
						return inits;

					for (field in type.fields.get()) {
						switch (field.kind) {
							default:
							case FVar(_, write):
								switch (write) {
									case AccNormal, AccCall, AccInline, AccNo:
									default: continue;
								}

								var e = field.expr();
								if (!reemittable(e))
									continue;

								var value:Expr = mapTyped(e);
								inits.push(macro Reflect.setField(this, $v{field.name}, @:privateAccess $value));
						}
					}

					return inits;
				}

				/**
				 * Rebuilds a class's constructor as an anonymous function, walking up the superclass chain.
				 *
				 * @param type The class whose constructor is rebuilt.
				 * @return The constructor as a function expression.
				 */
				function mapConstructor(type:ClassType, ?types:Array<Type>):Expr {
					/**
					 * The `extends` clause's arguments, bound before this class's body is rebuilt.
					 *
					 * A chain is walked up one class at a time and only the class was carried, so a
					 * parameter bound two levels down was not in scope by the time the body naming it was
					 * reached: `new FlxTypedGroup<T>(size)` came back out as `T`.
					 */
					if (types != null)
						for (i => given in types)
							if (i < type.params.length)
								generics.set(type.params[i].name, bindType(toCT(given)));

					if (type.constructor == null) {
						var inits:Array<Expr> = fieldInits(type);

						if (type.superClass != null) {
							switch (mapConstructor(type.superClass.t.get(), type.superClass.params).expr) {
								case EFunction(_, fun):
									inits.push(fun.expr);
									return {pos: pos, expr: EFunction(FAnonymous, {args: fun.args, expr: macro $b{inits}, ret: fun.ret})};
								default:
							}
						}

						return {pos: pos, expr: EFunction(FAnonymous, {args: [], expr: macro $b{inits}, ret: macro :Void})};
					}
					var constr = type.constructor.get();

					var args = null, ret = null;
					switch (constr.type) {
						default:
						case TFun(aargs, rret):
							args = aargs;
							ret = rret;
						case TLazy(lazy):
							switch (lazy()) {
								default:
								case TFun(aargs, rret):
									args = aargs;
									ret = rret;
							}
					}

					var typedConstr:TypedExpr = constr.expr();

					var refusal:Null<String> = reemittableConstructor(typedConstr);

					if (refusal != null) {
						/**
						 * A base whose constructor cannot be rebuilt may still be written out by hand.
						 *
						 * Rebuilding turns the compiler's own output back into source, and some of that
						 * does not survive the trip: `h3d.scene.Object` sets its flags through an abstract
						 * whose methods mutate `this`, so every flag property inlines to arithmetic on the
						 * underlying `Int` against a field typed as the abstract, which no source may
						 * write. None of that is a fact about the class. The same constructor written out
						 * in ordinary source types perfectly well, because at source level those
						 * operations are ordinary.
						 *
						 * So a base may carry a shim: `hxscript.shim.<its path, flattened>` with a static
						 * `init` taking the instance and the base constructor's arguments. When one is
						 * there it becomes the body of `__constructSuper`, and everything downstream is
						 * unchanged: `super(...)` in a script still calls that, on an instance allocated
						 * the same way, so nothing about how a bridge is built or constructed moves.
						 *
						 * A base with no shim is refused exactly as before, with the reason and the
						 * remedy.
						 */
						var shim:Null<Array<String>> = shimFor(type);

						if (shim == null) {
							/**
							 * Nothing to rebuild it from, so it is not rebuilt: Haxe constructs it.
							 *
							 * The bridge gets a real constructor calling a real `super`, and the instance
							 * is allocated through it rather than emptily. What that costs is that the
							 * base's arguments must be known before the instance exists, which is why
							 * `ScriptedClass` evaluates the script's `super(...)` arguments first and
							 * runs the rest of its constructor after.
							 */
							nativeSuper = true;
							nativeSuperArgs = args;

							return {
								pos: pos,
								expr: EFunction(FAnonymous, {
									args: [for (arg in args) {name: arg.name, opt: arg.opt, type: toCT(arg.t)}],
									expr: macro throw $v{typePath(type.module, type.name)}
										+ ' is constructed by Haxe, so its rebuilt constructor must not be called',
									ret: macro :Void
								})
							};
						}

						var passed:Array<Expr> = [macro this];
						for (arg in args)
							passed.push(macro $i{arg.name});

						return {
							pos: pos,
							expr: EFunction(FAnonymous, {
								args: [for (arg in args) {name: arg.name, opt: arg.opt, type: toCT(arg.t)}],
								expr: {pos: pos, expr: ECall(macro $p{shim}, passed)},
								ret: macro :Void
							})
						};
					}

					var expr = requalify(typedConstr, Context.getTypedExpr(typedConstr));
					switch (expr.expr) {
						default:
						case EFunction(_, fun):
							expr = fun.expr;
					}

					/**
					 * Rewrites a `super(...)` call for the bridge, dropping trailing nulls so an optional argument
					 * keeps its default instead of being overwritten.
					 *
					 * @param e The expression to rewrite.
					 * @return The rewritten expression.
					 */
					function mapSuper(e:Expr) {
						return switch (e.expr) {
							case ENew(t, params):
								var newParams:Array<Expr> = [];
								for (param in params) {
									switch (param.expr) {
										case EConst(CIdent('null')):
										default:
											newParams.push(param);
									}
								}

								if (StringTools.endsWith(t.name, '_Impl_'))
									t.name = t.name.replace('_Impl_', '');

								{
									pos: pos,
									expr: ENew(t, [for (param in newParams) param.map(mapSuper)])
								}

							case ECall(e, params):
								var newParams:Array<Expr> = [];
								for (param in params) {
									switch (param.expr) {
										case EConst(CIdent('null')):
										default:
											newParams.push(param);
									}
								}

								{
									pos: pos,
									expr: ECall(switch (e.expr) {
										case EConst(CIdent('super')):
											mapConstructor(type.superClass.t.get(), type.superClass.params);
										default:
											e.map(mapSuper);
									}, [for (param in newParams) param.map(mapSuper)])
								}

							case EConst(CIdent('super')):
								mapConstructor(type.superClass.t.get(), type.superClass.params);

							default:
								e.map(mapSuper);
						}
					}

					var constrExpr = expr.map(mapSuper);
					var body:Array<Expr> = switch (constrExpr) {
						case {pos: _, expr: EBlock(a)}: a;
						case e: [e];
					}

					body = fieldInits(type).concat(body);
					constrExpr = macro $b{body};

					var defaults:Array<Expr> = [];
					switch (constr.expr().expr) {
						default:
						case TFunction(fun):
							for (arg in fun.args) {
								if (arg.value == null) {
									defaults.push(null);
									continue;
								}
								var expr = Context.getTypedExpr(arg.value);
								defaults.push(macro cast $expr);
							}
					}
					return {
						pos: pos,
						expr: EFunction(FAnonymous, {
							args: [
								for (i => arg in args) {
									var defaultValue:Expr = defaults[i];

									{
										name: arg.name,
										value: defaultValue,
										opt: (defaultValue == null ? arg.opt : null),
										type: (defaultValue == null ? toCT(arg.t) : null)
									}
								}
							],
							expr: constrExpr,
							ret: toCT(ret)
						})
					};
				}

				switch (mapConstructor(type, types).expr) {
					default:
					case EFunction(_, fun):
						hasConstructor = true;

						fields.push({
							pos: pos,
							meta: [{pos: pos, name: ':privateAccess'}],
							name: '__constructSuper',
							kind: FFun({
								args: fun.args,
								expr: {pos: pos, expr: EMeta({pos: pos, name: ':privateAccess'}, fun.expr)},
								ret: fun.ret
							})
						});
				}

				/**
				 * A real constructor, for a base whose own could not be rebuilt.
				 *
				 * This is what makes the base run as Haxe compiled it rather than as something turned
				 * back into source, so nothing about it has to survive that trip. Allocation moves with
				 * it: `ScriptedClass` builds one of these through `Type.createInstance` instead of
				 * emptily, which is why it needs the base's arguments before the instance exists.
				 */
				if (nativeSuper && !fields.exists(function(f:Field):Bool return f.name == 'new')) {
					/**
					 * The signature is the immediate base's, not that of whichever ancestor could not be
					 * rebuilt. Those are often different: `h3d.scene.Interactive` takes a collider and a
					 * parent while the `h3d.scene.Object` below it takes only a parent, and generating
					 * the ancestor's signature made `super(parent)` pass a parent where a collider goes.
					 */
					var direct:Array<{name:String, opt:Bool, t:Type}> = superArgumentsOf(type);

					fields.push({
						pos: pos,
						access: [APublic],
						name: 'new',
						kind: FFun({
							args: [for (arg in direct) {name: arg.name, opt: arg.opt, type: toCT(arg.t)}],
							expr: {
								pos: pos,
								expr: ECall({pos: pos, expr: EConst(CIdent('super'))}, [for (arg in direct) macro $i{arg.name}])
							},
							ret: macro :Void
						})
					});

					fields.push({
						pos: pos,
						access: [APublic, AStatic],
						name: '__nativeSuper',
						kind: FVar(macro :Bool, macro true)
					});
				}
			}

			for (field in typeFields) {
				if (ignoreFields.contains(field.name))
					continue;

				if (!knownFields.contains(field.name))
					knownFields.push(field.name);

				switch (field.kind) {
					case FMethod(kind):
						if (omittedFields.contains(field.name))
							continue;

						if (field.meta.has(':generic')) {
							omittedFields.push(field.name);
							continue;
						}

						if (kind.match(MethDynamic)) {
							omittedFields.push(field.name);
							continue;
						}

						switch (kind) {
							case MethInline:
								if (!inlinedFields.contains(field.name))
									inlinedFields.push(field.name);
								omittedFields.push(field.name);
								continue;
							case MethMacro:
								omittedFields.push(field.name);
								continue;
							default:
								if (field.isFinal) {
									omittedFields.push(field.name);
									continue;
								}
						}

						if (field.name == 'toString') {
							hasToString = true;
						} else {
							var args:Array<{t:Type, opt:Bool, name:String}> = null, ret = null, expr = Context.getTypedExpr(field.expr());
							switch (field.type) {
								default:
								case TFun(aargs, rret):
									args = aargs;
									ret = rret;
								case TLazy(lazy):
									switch (lazy()) {
										default:
										case TFun(aargs, rret):
											args = aargs;
											ret = rret;
									}
							}
							switch (expr.expr) {
								default:
								case EFunction(_, fun):
									expr = fun.expr;
							}
							expr = {pos: pos, expr: EMeta({pos: pos, name: ':privateAccess'}, expr)};

							var argsArray:Array<Expr> = new Array<Expr>();
							for (arg in args)
								argsArray.push(macro cast $i{arg.name});

							var superArgs:Array<Expr> = [for (arg in args) macro $i{arg.name}];

							var isVoid:Bool = switch (ret) {
								case TAbstract(t, _): (t.get().name == 'Void');
								default: false;
							}
							var f:String = field.name;
							/**
							 * Every local here is `__` prefixed, because this body is written around a
							 * method whose parameters it does not choose. One of them was called `r`,
							 * which is what `h3d.scene.Object` names a colour component, and the
							 * generated `var r:Dynamic` then shadowed the argument: the call passed the
							 * uninitialised temp instead of the value, and Haxe caught it as `Local
							 * variable r used without being initialized`. A name a base cannot plausibly
							 * use is the whole fix.
							 */
							expr = macro {
								var __name:String = $v{f};
								if (__interp != null && __func != __name && __interp.locals.exists(__name)) {
									var __previous:String = __func;
									__func = __name;
									var __result:Dynamic;
									if (__safe) {
										__interp.inTry = true;
										try {
											__result = Reflect.callMethod(__interp, __interp.getLocal(__name), $a{argsArray});
										} catch (__e:Dynamic) {
											__base.onInstanceError(__e, __name, this);
											__result = null;
										}
									} else {
										__result = Reflect.callMethod(__interp, __interp.getLocal(__name), $a{argsArray});
									}
									__func = __previous;
									${isVoid?macro return:macro return cast __result}
								}

								if (__safe) {
									try {
										${isVoid ? macro super.$f($a{superArgs}) : macro return super.$f($a{superArgs})}
									} catch (__e:Dynamic) {
										__base.onInstanceError(__e, __name, this);
										${isVoid?macro return:macro return cast null}
									}
								} else {
									${isVoid ? macro super.$f($a{superArgs}) : macro return super.$f($a{superArgs})}
								}
							};

							var buildField:Field = fields.find(function(f:Field) return (f.name == field.name));
							if (buildField == null) {
								var access:Array<Access> = [AOverride];
								if (field.isPublic)
									access.push(APublic);
								if (field.isExtern)
									access.push(AExtern);
								if (field.isAbstract)
									access.push(AAbstract);

								var ownParams:Array<TypeParamDecl> = [
									for (p in field.params) {
										var constraints:Array<ComplexType> = switch (p.t) {
											case TInst(t, _):
												switch (t.get().kind) {
													case KTypeParameter(cs): [for (c in cs) toCT(c)];
													default: [];
												}
											default: [];
										}

										{name: p.name.substr(p.name.lastIndexOf('.') + 1), constraints: constraints};
									}
								];
								var ownParamNames:Array<String> = [for (p in ownParams) p.name];

								var cantInfer:Bool = false;
								/**
								 * Substitutes a bound concrete type for a type parameter.
								 *
								 * @param t The type to substitute in.
								 * @return The type with parameters resolved.
								 */
								function mapGeneric(t:ComplexType) {
									switch (t) {
										case TPath(p):
											var short:String = p.name.substr(p.name.lastIndexOf('.') + 1);

											if (generics.exists(p.name)) {
												return generics.get(p.name);
											} else if (generics.exists(short) && p.name != short) {
												return generics.get(short);
											} else if (ownParamNames.indexOf(short) >= 0) {
												return TPath({pack: [], name: short, params: p.params});
											} else if (short.length == 1) {
												cantInfer = true;
												return t;
											} else {
												if (p != null) {
													for (i => param in p.params)
														p.params[i] = switch (param) {
															case TPType(p): TPType(mapGeneric(p));
															default: param;
														}
												}
												return t;
											}
										case TOptional(t):
											return TOptional(mapGeneric(t));
										case TNamed(n, t):
											return TNamed(n, mapGeneric(t));
										case TFunction(args, ret):
											return TFunction([for (arg in args) mapGeneric(arg)], mapGeneric(ret));
										case TParent(t):
											return TParent(mapGeneric(t));
										default:
											return t;
									}
								}

								var accessible:Bool = typeAccessible(ret);
								for (arg in args)
									if (!typeAccessible(arg.t))
										accessible = false;
								if (!accessible) {
									omittedFields.push(f);
									if (Context.defined('hxscript_verbose'))
										Context.info('Skipping $f of ${cls.name}: signature uses an inaccessible type', pos);
									continue;
								}

								var defaults:Array<Expr> = [];
								switch (field.expr().expr) {
									default:
									case TFunction(fun):
										for (arg in fun.args) {
											if (arg.value == null) {
												defaults.push(null);
												continue;
											}
											var expr = Context.getTypedExpr(arg.value);
											defaults.push(macro cast $expr);
										}
								}
								var args = [
									for (i => arg in args) {
										var defaultValue:Expr = defaults[i];

										var t = mapGeneric(toCT(arg.t));

										{
											name: arg.name,
											value: defaultValue,
											type: (defaultValue == null ? t : null),
											opt: (defaultValue == null ? arg.opt : null)
										}
									}
								];
								var ret = mapGeneric(toCT(ret));

								if (cantInfer) {
									omittedFields.push(f);
									if (Context.defined('hxscript_verbose'))
										Context.info('Couldn\'t override field $f of ${cls.name}', pos);
									continue;
								}

								fields.push({
									pos: pos,
									access: access,
									name: f,
									kind: FFun({
										args: args,
										expr: expr,
										ret: ret,
										params: ownParams
									})
								});
							}
						}

					case FVar(_, _):
				}
			}

			if (type.superClass != null)
				setFields(type.superClass.t.get(), type.superClass.params);
		}
		setFields(cls /*, [for (param in cls.params) param.t]*/);

		if (!hasToString) {
			fields.push({
				pos: pos,
				access: [APublic],
				name: 'toString',
				kind: FFun({
					args: [],
					expr: macro {
						if (__interp.locals.exists('toString'))
							return __interp.locals.get('toString').r();

						return __base.path;
					},
					ret: macro :String
				})
			});
		}
		if (!hasConstructor) {
			fields.push({
				pos: pos,
				name: '__constructSuper',
				kind: FFun({
					args: [],
					expr: macro throw '${__base.path} does not have a constructor',
					ret: macro :Void
				})
			});
		}

		var newExpr = macro {
			__vars = new Map();
			__func = '';

			__base = base;
			__safe = base.safe;
			__interp = Type.createInstance(hxscript.Config.interpClass, [base.interp.environment, this]);
			__interp.ownerClass = base;
			__interp.pushStack(hxscript.runtime.ScriptStack.StackItem.SModule(base.module?.path ?? base.name));

			__interp.setDefaults(true, false);
			__interp.variables.set('this', this);
			__interp.variables.set('interp', __interp);

			for (u in base.interp.usings)
				__interp.usings.push(u);
			for (k => i in base.interp.imports)
				__interp.imports.set(k, i);
			for (k => v in base.interp.variables)
				if (!__interp.variables.exists(k))
					__interp.variables.set(k, v);

			for (k => v in base.__vars)
				if (!__interp.locals.exists(k))
					__interp.locals.set(k, v);

			if (base.name != null && !__interp.variables.exists(base.name))
				__interp.variables.set(base.name, base);

			__fields = [];
			var constructor:Dynamic = null;
			/**
			 * Binds a native superclass instance's fields as interpreter locals, so a scripted override
			 * reads and writes the real object rather than a shadow copy.
			 *
			 * @param i The native instance.
			 */
			function setInstanceFields(i:Dynamic) {
				var instanceFields:Array<String> = i.instanceFields;
				if (instanceFields == null)
					return;

				var superLocals:Map<String, hxscript.runtime.Variable> = __interp.duplicate(__interp.locals);

				for (field in instanceFields) {
					if (hxscript.macro.Scripted.ignoreFields.contains(field))
						continue;

					if (!__interp.variables.exists(field))
						__interp.variables.set(field, hxscript.runtime.Reference.RProperty(this, field));

					var f = Reflect.field(this, field);
					if (Reflect.isFunction(f))
						superLocals.set(field, {ref: f});
				}

				/** Kept in `__vars` too, since a compiled body asks from outside any frame of the interpreter's. */
				var __superRef:hxscript.runtime.Variable = {ref: hxscript.runtime.Reference.RSuper(superLocals, __constructSuper)};
				__interp.locals.set('super', __superRef);
				__vars.set('super', __superRef);
			}
			/**
			 * Binds a scripted class's own fields as interpreter locals.
			 *
			 * @param t The scripted class.
			 * @param isSuper Whether it is being bound as an ancestor rather than the instance itself.
			 */
			function setFields(t:hxscript.types.ScriptedClass, isSuper:Bool = false) {
				/**
				 * What `super` means inside this class's own bodies, taken before the scope holds
				 * this class's methods. A compiled body has no closure carrying a lexical `super` and
				 * has to ask the instance, and asking without saying which class is asking finds the
				 * nearest answer and calls itself forever.
				 */
				if (__interp.locals.exists('super'))
					__vars.set('super@' + t.path, __interp.locals.get('super'));

				for (field in t.decl.fields) {
					var f:String = field.name;

					if (f == 'new' || field.access.contains(AStatic))
						continue;

					switch (field.kind) {
						case KFunction(fun):
							__interp.locals.set(f, {ref: null, access: field.access});

						case KVar(v):
							if (instanceFields.contains(f)) {
								Reflect.setField(this, f, __interp.exprReturn(v.expr));
							} else {
								var l:hxscript.runtime.Variable = {
									ref: null,
									access: field.access,
									get: v.get,
									set: v.set
								};
								if (v.get != null)
									l.get = v.get;
								if (v.set != null)
									l.set = v.set;

								__interp.locals.set(f, l);
							}
					}
				}

				var superLocals:Map<String, hxscript.runtime.Variable> = __interp.duplicate(__interp.locals);
				for (loc => v in t.__vars)
					superLocals.set(loc, v);

				var instanceFields:Array<String> = t.extending?.instanceFields;
				if (instanceFields != null) {
					for (field in instanceFields) {
						if (hxscript.macro.Scripted.ignoreFields.contains(field))
							continue;

						if (!__interp.variables.exists(field))
							__interp.variables.set(field, hxscript.runtime.Reference.RProperty(this, field));

						var f = Reflect.field(this, field);
						if (Reflect.isFunction(f))
							superLocals.set(field, {ref: f});
					}
				}

				for (field in t.decl.fields) {
					var f:String = field.name;

					if (field.access.contains(AStatic))
						continue;
					if (f != 'new')
						__fields.push(f);

					switch (field.kind) {
						case KFunction(fun):
							if (f == 'new') {
								/**
								 * Without its `super(...)` when Haxe already ran the base's constructor,
								 * so the arguments it passes are evaluated once rather than twice. They
								 * were evaluated before the instance existed, to make it.
								 */
								var body:hxscript.syntax.Expr = Reflect.field(Type.getClass(this), '__nativeSuper') == true
									? hxscript.types.ScriptedTools.withoutSuper(fun.expr) : fun.expr;

								constructor = __interp.buildFunction(f, fun.args, body, fun.ret, superLocals, true);
								continue;
							}

							/** A backend that compiled this method hands back a closure bound to this instance. */
							var __compiled:Dynamic = t.boundMember(f, this);
							__interp.locals.get(f).r = __compiled != null ? __compiled : __interp.buildFunction(f, fun.args, fun.expr, fun.ret,
								superLocals);

						case KVar(v):
							if (__interp.locals.exists(f)) {
								var __value:Dynamic = (v.expr == null) ? null : __interp.exprReturn(v.expr, v.type);
								var __slot:hxscript.runtime.Variable = __interp.locals.get(f);
								var __bound:hxscript.runtime.Variable = __interp.bindDeclared(__value, v.type);
								__slot.r = __bound.r;
								__slot.a = __bound.a;
								if (__bound.t != null)
									__slot.t = __bound.t;
							}
					}

					__vars.set(f, __interp.locals.get(f));
					superLocals.set(f, __interp.locals.get(f));
				}

				if (isSuper) {
					var __superRef:hxscript.runtime.Variable = {ref: hxscript.runtime.Reference.RSuper(superLocals, constructor ?? __constructSuper)};
					__interp.locals.set('super', __superRef);
					__vars.set('super', __superRef);
				}
			}

			/**
			 * Walks the inheritance chain from the top down, binding each ancestor's fields so a subclass
			 * override shadows the ancestor's rather than the other way round.
			 *
			 * @param extending The class or instance being extended.
			 */
			function setSuperFields(extending:Dynamic) {
				if (extending is hxscript.types.ScriptedClass) {
					var extend:hxscript.types.ScriptedClass = cast extending;

					if (extend.extending != null)
						setSuperFields(extend.extending);

					setFields(extend, true);
				} else if (extending != null) {
					setInstanceFields(extending);
				}
			}

			setSuperFields(base.extending);
			setFields(base);

			/** Built before the constructor runs, so a compiled constructor body can reach a slot too. */
			if (hxscript.types.ScriptedTools.wantsSlots)
				__slots = hxscript.types.ScriptedTools.slotsFor(base, __vars);

			var entry:Dynamic = (constructor ?? __constructSuper);

			if (__safe) {
				try {
					Reflect.callMethod(this, entry, arguments);
				} catch (e:Dynamic) {
					base.onInstanceError(e, 'new', this);
				}
			} else {
				Reflect.callMethod(this, entry, arguments);
			}
		};
		fields.push({
			pos: pos,
			name: '__scriptConstruct',
			kind: FFun({
				args: [
					{name: 'base', type: macro :hxscript.types.ScriptedClass},
					{name: 'arguments', type: macro :Array<Dynamic>}
				],
				expr: newExpr,
				ret: macro :Void
			})
		});

		var superClass = cls.superClass?.t.get();
		var path:Array<String>;

		if (superClass != null) {
			path = superClass.pack.copy();
			path.push(superClass.name);
		} else {
			path = cls.pack.copy();
			path.push(cls.name);
		}

		fields = fields.concat([
			{
				pos: pos,
				name: '__base',
				kind: FVar(macro :hxscript.types.ScriptedClass),
			},
			{
				pos: pos,
				name: '__safe',
				kind: FVar(macro :Bool),
			},
			{
				pos: pos,
				access: [AStatic, APublic],
				name: 'instanceFields',
				kind: FVar(macro :Array<String>, macro $v{knownFields}),
			},
			{
				pos: pos,
				access: [AStatic, APublic],
				name: 'inlinedFields',
				kind: FVar(macro :Array<String>, macro $v{inlinedFields}),
			},
			{
				pos: pos,
				access: [AStatic, APublic],
				name: 'unexposedFields',
				kind: FVar(macro :Array<String>, macro $v{omittedFields}),
			},
			{
				pos: pos,
				name: '__vars',
				kind: FVar(macro :Map<String, hxscript.runtime.Variable>),
			},
			{
				pos: pos,
				name: '__slots',
				kind: FVar(macro :haxe.ds.Vector<hxscript.runtime.Variable>),
			},
			{
				pos: pos,
				name: '__fields',
				kind: FVar(macro :Array<String>),
			},
			{
				pos: pos,
				name: '__func',
				kind: FVar(macro :String),
			},
			{
				pos: pos,
				name: '__interp',
				kind: FVar(macro :hxscript.runtime.Interp),
			},
			{
				pos: pos,
				access: [APublic, AStatic],
				name: 'getBaseClass',
				kind: FFun({
					args: [],
					expr: macro return $v{path.join('.')},
					ret: macro :String
				})
			},
			{
				pos: pos,
				access: [APublic],
				name: 'reflectHasField',
				kind: FFun({
					args: [{name: 'field', type: macro :String}],
					expr: macro {
						if (hxscript.macro.Scripted.ignoreFields.contains(field))
							return false;
						return (instanceFields.contains(field) || Reflect.hasField(this, field) || __vars.exists(field));
					},
					ret: macro :Bool
				})
			},
			{
				pos: pos,
				access: [APublic],
				name: 'reflectGetField',
				kind: FFun({
					args: [{name: 'field', type: macro :String}],
					expr: macro {
						if (hxscript.macro.Scripted.ignoreFields.contains(field))
							return null;
						if (instanceFields.contains(field) || Reflect.hasField(this, field)) {
							return Reflect.field(this, field);
						} else if (__vars.exists(field)) {
							return __vars.get(field).r;
						}
						return null;
					},
					ret: macro :Dynamic
				})
			},
			{
				pos: pos,
				access: [APublic],
				name: 'reflectSetField',
				kind: FFun({
					args: [{name: 'field', type: macro :String}, {name: 'value', type: macro :Dynamic}],
					expr: macro {
						if (hxscript.macro.Scripted.ignoreFields.contains(field))
							return null;
						if (instanceFields.contains(field) || Reflect.hasField(this, field)) {
							Reflect.setField(this, field, value);
							return Reflect.field(this, field);
						} else if (__vars.exists(field)) {
							return __vars.get(field).r = value;
						}
						return null;
					},
					ret: macro :Dynamic
				})
			},
			{
				pos: pos,
				access: [APublic],
				name: 'reflectGetProperty',
				kind: FFun({
					args: [{name: 'property', type: macro :String}],
					expr: macro {
						if (hxscript.macro.Scripted.ignoreFields.contains(property))
							return null;
						if (instanceFields.contains(property) || Reflect.hasField(this, property)) {
							return Reflect.getProperty(this, property);
						} else if (__vars.exists(property)) {
							return __interp.getLocal(property, __vars);
						}
						return null;
					},
					ret: macro :Dynamic
				})
			},
			{
				pos: pos,
				access: [APublic],
				name: 'reflectSetProperty',
				kind: FFun({
					args: [{name: 'property', type: macro :String}, {name: 'value', type: macro :Dynamic}],
					expr: macro {
						if (hxscript.macro.Scripted.ignoreFields.contains(property))
							return null;
						if (instanceFields.contains(property) || Reflect.hasField(this, property)) {
							Reflect.setProperty(this, property, value);
							return Reflect.field(this, property);
						} else if (__vars.exists(property)) {
							return __interp.setLocal(property, value, __vars);
						}
						return null;
					},
					ret: macro :Dynamic
				})
			},
			{
				pos: pos,
				access: [APublic],
				name: 'reflectListFields',
				kind: FFun({
					args: [],
					/**
						A method is not a field. `Reflect.fields` answers with what an instance
						stores, and the slots carry a class's methods beside its variables, so
						listing every slot named methods that no other spelling of the same question
						has ever listed. A backend that replaces the class agrees with `Reflect`
						rather than with the slots, which is how this was found.
					**/
					expr: macro {
						var fields = [
							for (f in Reflect.fields(this))
								if (!hxscript.macro.Scripted.ignoreFields.contains(f)) f
						];
						for (f in __vars.keys()) {
							if (hxscript.macro.Scripted.ignoreFields.contains(f) || fields.contains(f))
								continue;
							if (__base != null && __base.declaresMethod(f))
								continue;
							fields.push(f);
						}
						return fields;
					},
					ret: macro :Array<String>
				})
			},
			{
				pos: pos,
				access: [APublic],
				name: 'typeGetClass',
				kind: FFun({
					args: [],
					expr: macro {return __base;},
					ret: macro :hxscript.types.ScriptedClass
				})
			},
			{
				pos: pos,
				access: [APublic],
				name: 'typeCreateInstance',
				kind: FFun({
					args: [{name: 'args', type: macro :Array<Dynamic>}],
					expr: macro {throw 'Invalid'; return null;},
					ret: macro :Dynamic
				})
			},
			{
				pos: pos,
				access: [APublic],
				name: 'typeCreateEmptyInstance',
				kind: FFun({
					args: [],
					expr: macro {throw 'Invalid'; return null;},
					ret: macro :Dynamic
				})
			},
			{
				pos: pos,
				access: [APublic],
				name: 'typeGetInstanceFields',
				kind: FFun({
					args: [],
					expr: macro {return [];},
					ret: macro :Array<String>
				})
			},
			{
				pos: pos,
				access: [APublic],
				name: 'typeGetClassFields',
				kind: FFun({
					args: [],
					expr: macro {return [];},
					ret: macro :Array<String>
				})
			}
		]);

		return fields;
	}

	/**
	 * Collects every generated bridge class at compile time and emits runtime code that maps each
	 * native base class to the bridge that makes it scriptable.
	 *
	 * @return An expression evaluating to a `Map` from native base class to its bridge class.
	 */
	public static macro function listScriptedClasses() {
		Context.onAfterTyping(function(types) {
			var self = TypeTools.getClass(Context.getType(_name));
			if (self.meta.has('typedScripted'))
				return;

			var map:Array<String> = [];

			for (type in types) {
				switch (type) {
					case TClassDecl(r):
						var c = r.get();
						if (c.interfaces.length > 0 && c.interfaces[0].t.get().name == 'IScriptedInstance') {
							var p = c.pack.copy();
							p.push(c.name);
							map.push(p.join('.'));
						}
					default:
				}
			}

			self.meta.add('typedScripted', [macro $v{haxe.Serializer.run(map)}], self.pos);
		});

		return macro {
			var meta:Array<String> = cast haxe.Unserializer.run(haxe.rtti.Meta.getType($p{_name.split('.')}).typedScripted[0]);
			var map:Map<String, Dynamic> = [];

			for (cls in meta) {
				var scripted:Dynamic = Type.resolveClass(cls);
				map.set(scripted.getBaseClass(), cast scripted);
			}

			cast map;
		}
	}
}
