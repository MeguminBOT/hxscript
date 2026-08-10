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
				 * Repairs the three things `Context.getTypedExpr` cannot round-trip.
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
							case ENew(t, params) if (t.pack.length == 0 && t.sub == null && qualified.exists(t.name)):
								var q:TypePath = qualified.get(t.name);
								{pos: x.pos, expr: ENew({pack: q.pack, name: q.name, sub: q.sub, params: t.params}, [for (p in params) fix(p)])};

							case EField(owner, member, kind) if (implName(owner) != null && abstractOf.exists(implName(owner))):
								{pos: x.pos, expr: EField(macro $p{abstractOf.get(implName(owner))}, member, kind)};

							case EConst(CIdent(name)) if (name.indexOf('`') >= 0):
								{pos: x.pos, expr: EConst(CIdent(name.replace('`', '_')))};

							case EVars(vars):
								{
									pos: x.pos,
									expr: EVars([
										for (v in vars)
											{
												name: v.name.replace('`', '_'),
												type: v.type,
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
				function mapConstructor(type:ClassType):Expr {
					if (type.constructor == null) {
						var inits:Array<Expr> = fieldInits(type);

						if (type.superClass != null) {
							switch (mapConstructor(type.superClass.t.get()).expr) {
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
					if (refusal != null)
						Context.error('${cls.name}: ${typePath(type.module, type.name)} cannot be extended for scripting, because $refusal. Remove it from the bridged bases; scripts can still import and construct it.',
							pos);

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
											mapConstructor(type.superClass.t.get());
										default:
											e.map(mapSuper);
									}, [for (param in newParams) param.map(mapSuper)])
								}

							case EConst(CIdent('super')):
								mapConstructor(type.superClass.t.get());

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

				switch (mapConstructor(type).expr) {
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
							expr = macro {
								var fname:String = $v{f};
								if (__interp != null && __func != fname && __interp.locals.exists(fname)) {
									var prevFunc:String = __func;
									__func = fname;
									var r:Dynamic;
									if (__safe) {
										__interp.inTry = true;
										try {
											r = Reflect.callMethod(__interp, __interp.getLocal(fname), $a{argsArray});
										} catch (e:Dynamic) {
											__base.onInstanceError(e, fname, this);
											r = null;
										}
									} else {
										r = Reflect.callMethod(__interp, __interp.getLocal(fname), $a{argsArray});
									}
									__func = prevFunc;
									${isVoid?macro return:macro return cast r}
								}

								if (__safe) {
									try {
										${isVoid ? macro super.$f($a{superArgs}) : macro return super.$f($a{superArgs})}
									} catch (e:Dynamic) {
										__base.onInstanceError(e, fname, this);
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
						superLocals.set(field, {r: f});
				}

				__interp.locals.set('super', {r: hxscript.runtime.Reference.RSuper(superLocals, __constructSuper)});
			}
			/**
			 * Binds a scripted class's own fields as interpreter locals.
			 *
			 * @param t The scripted class.
			 * @param isSuper Whether it is being bound as an ancestor rather than the instance itself.
			 */
			function setFields(t:hxscript.types.ScriptedClass, isSuper:Bool = false) {
				for (field in t.decl.fields) {
					var f:String = field.name;

					if (f == 'new' || field.access.contains(AStatic))
						continue;

					switch (field.kind) {
						case KFunction(fun):
							__interp.locals.set(f, {r: null, access: field.access});

						case KVar(v):
							if (instanceFields.contains(f)) {
								Reflect.setField(this, f, __interp.exprReturn(v.expr));
							} else {
								var l:hxscript.runtime.Variable = {
									r: null,
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
							superLocals.set(field, {r: f});
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
								constructor = __interp.buildFunction(f, fun.args, fun.expr, fun.ret, superLocals, true);
								continue;
							}

							__interp.locals.get(f).r = __interp.buildFunction(f, fun.args, fun.expr, fun.ret, superLocals);

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

				if (isSuper)
					__interp.locals.set('super', {r: hxscript.runtime.Reference.RSuper(superLocals, constructor ?? __constructSuper)});
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
					expr: macro {
						var fields = [
							for (f in Reflect.fields(this))
								if (!hxscript.macro.Scripted.ignoreFields.contains(f)) f
						];
						for (f in __vars.keys()) {
							if (!hxscript.macro.Scripted.ignoreFields.contains(f) && !fields.contains(f))
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
