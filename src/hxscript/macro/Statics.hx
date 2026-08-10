package hxscript.macro;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.Type;

using haxe.macro.ExprTools;
using haxe.macro.TypeTools;

/**
 * Build macro that re-emits another class's statics as real forwarding members.
 *
 * For a class with no runtime representation on some target, such as `Math` on HashLink and on
 * python, reflection finds nothing to call, so a script gets `module has no field max` against a
 * member that is plainly there. The forwards give it something reflectable.
 */
class Statics {
	/**
	 * Generates forwarding statics mirroring another class's static fields.
	 *
	 * @param e An expression naming the source class.
	 * @return The generated fields to add to the building class.
	 */
	public static macro function build(e:Expr):Array<Field> {
		var pos = Context.currentPos();
		var fields:Array<Field> = Context.getBuildFields();

		var cls = switch (Context.getType(e.toString())) {
			case TInst(t, _):
				t.get();
			default:
				throw 'Not a class';
		}

		var statics:Array<ClassField> = cls.statics.get();
		for (field in statics) {
			var f:String = field.name;

			switch (field.kind) {
				case FVar(r, w):
					var t = field.type.toComplexType();
					fields.push({
						pos: pos,
						name: f,
						access: [APublic, AStatic],
						kind: FProp('get', 'never', t, null)
					});
					fields.push({
						pos: pos,
						name: 'get_$f',
						access: [APublic, AStatic],
						kind: FFun({
							args: [],
							ret: t,
							expr: macro return $e.$f
						})
					});

				case FMethod(m):
					var args = null, ret = null;

					switch (field.type) {
						default:
						case TFun(aargs, rret):
							args = aargs;
							ret = rret;
						case TLazy(lazy):
							switch (lazy()) {
								default: continue;
								case TFun(aargs, rret):
									args = aargs;
									ret = rret;
							}
					}

					var defaults:Array<Expr> = [];
					var typed:Null<TypedExpr> = field.expr();

					if (typed != null) {
						switch (typed.expr) {
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
					}

					var argsArray:Array<Expr> = [for (arg in args) macro $i{arg.name}];

					fields.push({
						pos: pos,
						name: f,
						access: [APublic, AStatic],
						kind: FFun({
							args: [
								for (i => arg in args) {
									var defaultValue:Expr = defaults[i];

									{
										name: arg.name,
										value: defaultValue,
										opt: (defaultValue == null ? arg.opt : null),
										type: (defaultValue == null ? arg.t.toComplexType() : null)
									}
								}
							],
							ret: ret.toComplexType(),
							expr: macro return $e.$f($a{argsArray})
						})
					});
			}
		}

		return fields;
	}
}
#end
