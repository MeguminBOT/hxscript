package hxscript.macro;

#if macro
import haxe.macro.Compiler;
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.Type;
import Type as HaxeType;

using haxe.macro.ExprTools;
using haxe.macro.TypeTools;
using haxe.macro.ComplexTypeTools;
#end

/**
 * Build macro applied to abstract implementation classes so scripts can use abstracts at runtime.
 * An abstract has no runtime representation of its own, so this emits an `AbstractValue_*` wrapper
 * class that boxes the underlying value and re-exposes the abstract's fields, operators, and
 * `from`/`to` conversions (and, for an `enum abstract`, its constants) in a reflectable form.
 * Standard-library and core-type abstracts are left untouched.
 */
class Abstract {
	/**
	 * Generates the runtime wrapper for the abstract being built.
	 *
	 * @return The fields of the generated wrapper (or the original fields for a skipped abstract).
	 */
	public static macro function build():Array<Field> {
		var pos = Context.currentPos();
		var type = Context.getLocalType();
		var fields = Context.getBuildFields();
		var imports = Context.getLocalImports();

		var ab = null;

		switch (type) {
			case TInst(r, _):
				var c = r.get();

				c.meta.add(':keep', [], pos);

				switch (c.kind) {
					case KAbstractImpl(a):
						ab = a.get();

						switch (ab.pack[0]) {
							case 'haxe', 'hl', 'cpp', 'neko', 'js', 'cs', 'lua', 'php', 'macro', 'java', 'flash', 'python':
								return fields;
							default:
						}

						if (ab.meta.has(':coreType') || ab.type == null || ab.pack[1] == 'Contraints') return fields;
					default:
						return fields;
				}
			default:
				return fields;
		}

		var fullPath = ab.pack.copy();
		fullPath.push(ab.name);
		var isEnum = ab.meta.has(':enum');

		var cls = macro class extends AbstractValue {
			public static var impl(default, never):String = $v{fullPath.join('.')};
		}
		cls.pack = ab.pack;
		cls.name = 'AbstractValue_${fullPath.join('_')}';
		cls.meta.push({name: ':keep', pos: pos});
		cls.fields.push({
			name: 'isEnum',
			pos: pos,
			access: [APublic, AStatic],
			kind: FProp('default', 'never', macro :Bool, macro $v{isEnum})
		});

		for (dep in ['hxscript.types.AbstractValue', 'hxscript.types.AbstractTools']) {
			imports.push({
				path: [for (v in dep.split('.')) {name: v, pos: pos}],
				mode: INormal
			});
		}
		/**
		 * The importable path of a sibling type, or null when it has none.
		 *
		 * A private type, a type parameter (a one-character name) and the abstract being built
		 * itself are all excluded: none of them can be named from the generated wrapper.
		 *
		 * @param tt The candidate type.
		 * @param ty The type whose module is being imported, so it does not import itself.
		 * @return The dotted path, or null.
		 */
		function getTypePath(tt:Dynamic, ?ty:Dynamic) {
			if (tt.isPrivate || tt.name.length <= 1 || tt.name == ty?.name)
				return null;

			return (tt.module + (tt.module.length > 0 ? '.' : '') + tt.name);
		}
		/**
		 * Imports every sibling type in a type's module, so the wrapper can name them unqualified.
		 *
		 * @param ty The type whose module is pulled in.
		 * @return Whether every sibling resolved to an importable path.
		 */
		function tryImport(ty:Dynamic):Bool {
			var pack:Array<String> = ty.module.split('.');
			for (t in Context.getModule(pack.join('.'))) {
				var p = null;

				switch (t) {
					case TEnum(r, _):
						p = getTypePath(r.get(), ty);
					case TInst(r, _):
						p = getTypePath(r.get(), ty);
					case TType(r, _):
						p = getTypePath(r.get(), ty);
					case TAbstract(r, _):
						p = getTypePath(r.get(), ty);
					default:
				}
				if (p == null)
					return false;

				imports.push({
					path: [for (v in p.split('.')) {name: v, pos: pos}],
					mode: INormal
				});
			}

			return true;
		}
		/**
		 * Drops type parameters from a type, since they are erased at runtime anyway.
		 *
		 * @param t The type to strip, or null.
		 * @return The parameterless type, or null.
		 */
		function stripComplex(?t:ComplexType):ComplexType {
			if (t == null)
				return null;
			return switch (t) {
				case TPath(p):
					if (p.name.length <= 1) macro :Dynamic; else TPath({name: p.name, pack: p.pack.copy(), sub: p.sub});
				case TOptional(t):
					TOptional(stripComplex(t));
				default:
					throw 'Invalid $t';
			}
		}
		/**
		 * Converts a typed `Type` back to a `ComplexType` the wrapper can declare.
		 *
		 * A single-character name is a type parameter, which has no runtime identity, so it degrades
		 * to `Dynamic` rather than being emitted as an unresolvable path.
		 *
		 * @param t The type to convert.
		 * @param includeParams Whether to carry type parameters across.
		 * @return The equivalent complex type.
		 */
		function toComplex(t:haxe.macro.Type, includeParams:Bool = false):ComplexType {
			/**
			 * Converts a type-parameter list for re-emission.
			 *
			 * @param params The parameters to convert.
			 * @return The converted parameters.
			 */
			function toTypeParam(params:Array<haxe.macro.Type>):Array<TypeParam> {
				return [for (t in params) TPType(toComplex(t))];
			}
			/**
			 * Builds the path for one referenced type, degrading a type parameter to `Dynamic`.
			 *
			 * @param r The type reference.
			 * @param p Its type parameters.
			 * @return The complex type to emit.
			 */
			function stuff(r:Dynamic, p:Array<haxe.macro.Type>) {
				var ct = r.get();
				if (ct.name.length <= 1) {
					return macro :Dynamic;
				} else {
					return TPath({name: ct.name, pack: ct.pack, params: (includeParams ? toTypeParam(p) : null)});
				}
			}

			return switch (t) {
				case TInst(r, p): stuff(r, p);
				case TType(r, p): stuff(r, p);
				case TEnum(r, p): stuff(r, p);
				case TAbstract(r, p): stuff(r, p);
				case TDynamic(_): macro :Dynamic;
				default: macro :Dynamic;
			}
		}
		/**
		 * Resolves a complex type through the typer and back, so aliases arrive fully qualified.
		 *
		 * @param t The type to resolve, or null.
		 * @param includeParams Whether to carry type parameters across.
		 * @return The resolved type, or null.
		 */
		function getFullComplex(t:ComplexType, includeParams:Bool = false):ComplexType {
			if (t == null)
				return null;
			return toComplex(t.toType(), includeParams);
		}
		/**
		 * Wraps an expression definition at the build position.
		 *
		 * @param expr The definition to position.
		 * @return The positioned expression.
		 */
		function ex(expr:ExprDef):Expr {
			return {pos: pos, expr: expr};
		}

		var tt = ab.type, t;
		tt = switch (tt) {
			case TType(r, _): r.get().type;
			default: tt;
		}
		var t = toComplex(tt);
		var st = macro $v{ComplexTypeTools.toString(t)};
		var castExpr = (isEnum ? macro if (!_enumValues.contains(v) && !_enumMap.exists(v))
			throw('Can\'t cast ' + AbstractTools.resolveName(v) + ' to ' + impl) : macro if (AbstractTools.resolveName(v) != $st) throw('Can\'t cast '
				+ AbstractTools.resolveName(v) + ' to ' + impl));

		var enumI = 0;
		var enumIndex:Array<Expr> = (isEnum ? [] : null);
		var enumMap:Map<String, Int> = (isEnum ? [] : null);
		var enumConstructors:Array<String> = (isEnum ? [] : null);
		cls.fields.push({
			name: 'tryCast',
			pos: pos,
			access: [AStatic],
			kind: FFun({
				args: [{name: 'v', type: macro :Dynamic}],
				params: [],
				ret: macro :Void,
				expr: castExpr
			})
		});

		var fromExpr = [macro return null];
		var toExpr = [macro return null];

		fromExpr.unshift(macro if (Type.getClass(v) == $p{[cls.name]}) return v.__a);
		toExpr.unshift(macro if (t == $v{fullPath.join('.')}) return __a);

		if (isEnum) {
			fromExpr.unshift(macro {
				if (_enumValues.contains(v))
					return v;
				else if (_enumMap.exists(v))
					return _enumValues[_enumMap.get(v)];
			});
		} else {
			for (from in ab.from) {
				if ((t = toComplex(from.t)) == null)
					continue;
				st = macro $v{ComplexTypeTools.toString(t)};
				fromExpr.unshift(macro if (AbstractTools.resolveName(v) == $st) return v);
			}
			for (to in ab.to) {
				if ((t = toComplex(to.t)) == null)
					continue;
				st = macro $v{ComplexTypeTools.toString(t)};
				toExpr.unshift(macro if (t == $st) return __a);
			}
		}

		var props = [];
		var implPath = ab.impl.get().pack.copy();
		implPath.push(ab.impl.get().name);
		var implStr = macro $v{implPath.join('.')};

		/**
		 * Where the abstract's own members really live, named so the runtime can reach them.
		 *
		 * `impl` above is the abstract's path, which is what a script writes and what nothing answers
		 * to at runtime. This is the class Haxe actually emitted the members onto, and the constructor
		 * is the reason it has to be reachable: assigning to `this` has no meaning as a method on a
		 * value, so `new` becomes a static `_new` here and there is nowhere else to find it.
		 */
		cls.fields.push({
			name: 'implClass',
			pos: pos,
			access: [APublic, AStatic],
			kind: FProp('default', 'never', macro :String, implStr)
		});

		var rabstractT = {name: ab.name, pack: ab.pack};
		var abstractT = {name: cls.name, pack: ab.pack};

		/**
		 * Boxes a field access back into the wrapper when the field's type is the abstract itself.
		 *
		 * @param expr The access to wrap.
		 * @param typeIsAbstract Whether the value needs boxing.
		 * @param ownReturn Whether to emit a `return` around it.
		 * @return The wrapped expression.
		 */
		function afield(expr, typeIsAbstract:Bool, ownReturn:Bool = false) {
			var newExpr;
			if (ownReturn) {
				newExpr = (typeIsAbstract ? macro {var r:Dynamic = $expr; return new $abstractT(r);} : macro {return $expr;});
			} else {
				newExpr = (typeIsAbstract ? macro new $abstractT($expr) : macro $expr);
			}

			return newExpr;
		}
		/**
		 * Builds a method body that returns `expr`, boxed when the return type is the abstract.
		 *
		 * @param expr The value to return.
		 * @param returnIsAbstract Whether the return value needs boxing.
		 * @param ownReturn Whether `expr` already carries its own `return`.
		 * @return The method body.
		 */
		function func(expr, returnIsAbstract:Bool, ownReturn:Bool = false) {
			return macro return ${afield(expr, returnIsAbstract, ownReturn)};
		}
		/**
		 * Whether a type names the abstract currently being built.
		 *
		 * @param t The type to test, or null.
		 * @return Whether it is this abstract.
		 */
		function matchAbstract(t:ComplexType) {
			if (t == null)
				return false;

			return switch (t) {
				case TPath(r): (r.name == ab.name);
				default: false;
			}
		}

		var opMap:Map<String, String> = [];
		var opPrinter = new haxe.macro.Printer();

		var dropped:Map<String, Bool> = new Map();
		for (field in fields) {
			if (field.access == null)
				continue;
			if (field.access.contains(AOverload) || field.access.contains(AExtern))
				dropped.set(field.name, true);
		}

		var underlying:Map<String, Bool> = new Map();
		switch (Context.follow(ab.type)) {
			case TInst(r, _):
				var c = r.get();
				while (c != null) {
					for (f in c.fields.get())
						underlying.set(f.name, true);
					c = (c.superClass != null) ? c.superClass.t.get() : null;
				}
			default:
		}

		var methodNames:Map<String, Bool> = [];
		for (field in fields) {
			switch (field.kind) {
				case FFun(_):
					methodNames.set(field.name.toUpperCase(), true);
				case FProp(get, set, _, _):
					if (get == 'get')
						methodNames.set('GET_' + field.name.toUpperCase(), true);
					if (set == 'set')
						methodNames.set('SET_' + field.name.toUpperCase(), true);
				default:
			}
		}

		for (field in fields) {
			var name = field.name;
			if (name == '__init__')
				continue;

			if (field.access.contains(AOverload)) {
				continue;
			}
			if (field.access.contains(AStatic)) {
				switch (field.kind) {
					case FFun(f):
						var custom = false;
						for (meta in field.meta) {
							if (meta.name == ':from') {
								var ss;

								switch (f.args[0].type) {
									case TPath(p):
										var st = p.pack.copy();
										st.push(p.name);
										ss = macro $v{st.join('.')};
									case TFunction(_, _):
										continue;
									default:
										throw 'Invalid ${f.args[0].type}';
								}

								var fc = macro return Reflect.getProperty(Type.resolveClass($implStr), $v{name})(v);
								fromExpr.unshift(macro if (AbstractTools.resolveName(v) == $ss) $fc);

								custom = true;
								continue;
							}
						}

						if (custom)
							continue;

						var args = [];
						var stuff = [];
						for (i => arg in f.args) {
							if (i == 0 && props.contains(name))
								continue;

							args.push({
								value: arg.value,
								type: macro :Dynamic,
								opt: arg.opt,
								name: arg.name,
								meta: arg.meta
							});
							stuff.push(macro $p{[arg.name]});
						}

						var isSetter = (props.contains(name) && StringTools.startsWith(name, 'set_'));
						var setterField = StringTools.replace(name, 'set_', '');

						cls.fields.push({
							name: name,
							pos: pos,
							access: [AStatic, APublic],
							kind: FFun({
								args: args,
								params: [],
								expr: func(isSetter ? macro {
									var cls = Type.resolveClass($implStr);
									$p{[setterField]} = Reflect.callMethod(cls, Reflect.field(cls, $v{name}), $a{stuff});
								} : macro {
									var cls = Type.resolveClass($implStr);
									Reflect.callMethod(cls, Reflect.field(cls, $v{name}), $a{stuff});
									}, matchAbstract(f.ret))
							})
						});

					case FVar(t, e):
						if (field.access.contains(APrivate) || !field.access.contains(APublic))
							continue;

						var typeIsMe:Bool = matchAbstract(t);
						/**
						 * Rewrites bare references to the abstract's own fields into private-access paths on the
						 * implementation class, so a re-emitted body still reaches them from the wrapper.
						 *
						 * @param e The expression to rewrite.
						 * @return The rewritten expression.
						 */
						function mapIdent(e:Expr) {
							return switch (e.expr) {
								case EConst(CIdent(f)):
									var ee = e;
									for (field in fields) {
										if (f == field.name) {
											ee = {pos: pos, expr: EMeta({pos: pos, name: ':privateAccess'}, macro $p{fullPath}.$f)};
											break;
										}
									}
									ee;
								default:
									e.map(mapIdent);
							}
						}

						if (typeIsMe && methodNames.exists('GET_' + name.toUpperCase())) {
							cls.fields.push({
								name: name,
								pos: pos,
								access: [AStatic, APublic],
								kind: FVar(TPath(abstractT), macro new $abstractT($e))
							});
						} else {
							cls.fields.push({
								name: name,
								pos: pos,
								access: [AStatic, APublic],
								kind: FProp(typeIsMe ? 'get' : 'default', 'never', typeIsMe ? TPath(abstractT) : macro :Dynamic, typeIsMe ? null : e?.map(mapIdent))
							});

							if (typeIsMe) {
								cls.fields.push({
									name: 'get_$name',
									pos: pos,
									access: [AStatic],
									kind: FFun({
										args: [],
										ret: TPath(abstractT),
										expr: macro return new $abstractT($e)
									})
								});
							}
						}

					default:
				}
			} else {
				switch (field.kind) {
					case FFun(f):
						var to = false;
						for (meta in field.meta) {
							if (meta.name == ':arrayAccess') {
								opMap.set(f.args.length > 1 ? '[]=' : '[]', name);
								continue;
							}
							if (meta.name == ':op') {
								if (meta.params != null && meta.params.length > 0) {
									switch (meta.params[0].expr) {
										case EBinop(binop, _, _):
											opMap.set(opPrinter.printBinop(binop), name);
										case EUnop(unop, _, _):
											opMap.set('u' + opPrinter.printUnop(unop), name);
										default:
									}
								}
								continue;
							}
							if (meta.name == ':to') {
								t = stripComplex(f.ret);
								if (t == null)
									continue;

								st = macro $v{ComplexTypeTools.toString(t)};
								var fc = macro return Reflect.getProperty(Type.resolveClass($implStr), $v{name})(__a);
								toExpr.unshift(macro if (t == $st) $fc);

								to = true;
								break;
							}
						}

						if (!to) {
							var args = [];
							var stuff = [macro __a];

							for (i => arg in f.args) {
								args.push({
									value: arg.value,
									type: macro :Dynamic,
									opt: arg.opt,
									name: arg.name,
									meta: arg.meta
								});
								stuff.push(macro $p{[arg.name]});
							}

							var setterExpr = null;
							var isSetter = StringTools.startsWith(name, 'set_');
							if (isSetter) {
								/**
								 * Rewrites a setter body for the wrapper: `this` becomes the boxed value `__a`, and local
								 * `var` types are erased because the wrapper does not carry the abstract's type parameters.
								 *
								 * @param expr The setter body.
								 * @return The rewritten body.
								 */
								function transformThis(expr) {
									return switch (expr.expr) {
										case EVars(a):
											var vars = macro $expr;
											switch (vars.expr) {
												case EVars(a):
													for (i => v in a) {
														a[i] = {
															type: macro :Dynamic,
															namePos: v.namePos,
															name: v.name,
															meta: v.meta,
															isStatic: v.isStatic,
															isFinal: v.isFinal,
															expr: v.expr
														}
													}
												default:
											}
											vars;
										case EConst(CIdent('this')):
											{expr: EConst(CIdent('__a')), pos: expr.pos};
										case EConst(CIdent(f)) if (dropped.exists(f) && underlying.exists(f)):
											{expr: EField({expr: EConst(CIdent('__a')), pos: expr.pos}, f), pos: expr.pos};
										default:
											ExprTools.map(expr, transformThis);
									}
								}

								setterExpr = macro ${f.expr};
								setterExpr = setterExpr.map(transformThis);
							}

							var returnsMe:Bool = matchAbstract(f.ret);
							cls.fields.push({
								name: name,
								pos: pos,
								access: [APublic],
								kind: FFun({
									args: args,
									params: [],
									expr: func(isSetter ? setterExpr : macro {
										var cls = Type.resolveClass($implStr);
										Reflect.callMethod(cls, Reflect.field(cls, $v{name}), $a{stuff});
									}, returnsMe, !isSetter),
									ret: (name == 'toString' ? macro :String : (returnsMe ? TPath(abstractT) : macro :Dynamic))
								})
							});
						}

					case FProp(get, set, _):
						props.push('get_$name');
						props.push('set_$name');

						cls.fields.push({
							name: name,
							pos: pos,
							kind: FProp(get, set, macro :Dynamic)
						});

					case FVar(t, e):
						if (isEnum) {
							enumConstructors.push(name);
							enumMap.set(name, enumI++);
							enumIndex.push(e);

							if (methodNames.exists('GET_' + name.toUpperCase())) {
								cls.fields.push({
									name: name,
									pos: pos,
									access: [APublic, AStatic],
									kind: FVar(TPath(abstractT), macro new $abstractT($e))
								});
							} else {
								cls.fields.push({
									name: name,
									pos: pos,
									access: [APublic, AStatic],
									kind: FProp('get', 'never', TPath(abstractT))
								});
								cls.fields.push({
									name: 'get_$name',
									pos: pos,
									access: [APublic, AStatic],
									kind: FFun({args: [], ret: TPath(abstractT), expr: macro return new $abstractT($e)})
								});
							}
						}

					default:
				}
			}
		}
		cls.fields.push({
			name: 'set_value',
			pos: pos,
			access: [APrivate, AOverride],
			kind: FFun({
				args: [{name: 'v', type: macro :Dynamic}],
				params: [],
				expr: macro {
					var r = resolveFrom(v);
					if (r == null)
						throw('Can\'t cast ' + AbstractTools.resolveName(v) + ' to ' + impl);
					return __a = r;
				}
			})
		});
		cls.fields.push({
			name: 'resolveFrom',
			pos: pos,
			access: [APublic, AStatic],
			kind: FFun({
				args: [{name: 'v', type: macro :Dynamic}],
				params: [],
				expr: macro $b{fromExpr},
				ret: macro :Dynamic
			})
		});
		cls.fields.push({
			name: 'resolveTo',
			pos: pos,
			access: [APublic, AOverride],
			kind: FFun({
				args: [{name: 't', type: macro :String}],
				params: [],
				expr: macro $b{toExpr},
				ret: macro :Dynamic
			})
		});

		var forwardAll:Bool = false;
		var forwards:Array<String> = [];

		for (m in ab.meta.extract(':forward')) {
			if (m.params == null || m.params.length == 0) {
				forwardAll = true;
				continue;
			}

			for (param in m.params)
				switch (param.expr) {
					case EConst(CIdent(n)):
						forwards.push(n);
					default:
				}
		}

		cls.fields.push({
			name: '_forwardAll',
			pos: pos,
			access: [APublic, AStatic],
			kind: FVar(macro :Bool, macro $v{forwardAll})
		});
		cls.fields.push({
			name: '_forwards',
			pos: pos,
			access: [APublic, AStatic],
			kind: FVar(macro :Array<String>, macro $v{forwards})
		});

		var opEntries:Array<Expr> = [];
		for (op => m in opMap)
			opEntries.push({pos: pos, expr: EBinop(OpArrow, macro $v{op}, macro $v{m})});

		cls.fields.push({
			name: '_ops',
			pos: pos,
			access: [APublic, AStatic],
			kind: FVar(macro :Map<String, String>, opEntries.length == 0 ? (macro new Map<String, String>()) : {
				pos: pos,
				expr: EArrayDecl(opEntries)
			})
		});
		cls.fields.push({
			name: '_enumMap',
			pos: pos,
			access: [APrivate, AStatic],
			kind: FProp('default', 'never', macro :Map<String, Int>, macro $v{enumMap})
		});
		cls.fields.push({
			name: '_enumConstructors',
			pos: pos,
			access: [APrivate, AStatic],
			kind: FProp('default', 'never', macro :Array<String>, macro $v{enumConstructors})
		});
		cls.fields.push({
			name: '_enumValues',
			pos: pos,
			access: [APrivate, AStatic],
			kind: FProp('default', 'never', macro :Array<Dynamic>, (isEnum ? macro $a{enumIndex} : null))
		});

		Context.defineModule(ab.pack.join('.') + (ab.pack.length > 0 ? '.' : '') + cls.name, [cls], imports);

		return fields;
	}
}
