package hxscript.types;

import hxscript.Environment;
import hxscript.Module;
import hxscript.proxy.ReflectProxy;
import hxscript.runtime.Interp;
import hxscript.syntax.Expr;

using hxscript.types.TypeCollection;

/**
 * A script-declared `abstract`. The abstract boxes a value of its underlying type; its methods run against
 * that value rather than against an object.
 */
@:access(hxscript.runtime.Interp)
class ScriptedAbstract implements IScriptedType {
	/** The abstract's short name. */
	public var name:String;

	/** The module that declares this abstract. */
	public var module:Module;

	/** The abstract's package segments. */
	public var pack:Array<String>;

	/** The abstract's fully-qualified path. */
	public var path:String;

	/** The type the abstract boxes, if declared. */
	public var underlying:Null<CType>;

	/** Types accepted implicitly (`from`). */
	public var from:Array<CType> = [];

	/** Types converted to implicitly (`to`). */
	public var to:Array<CType> = [];

	/** Which method serves each operator, keyed as `@:op` and `@:arrayAccess` record them. */
	public var ops:Map<String, String> = [];

	/** For each `@:to` method, the name of the type it converts to. */
	public var toTargets:Map<String, String> = [];

	/** For each `@:from` method, the name of the type it converts from. */
	public var fromSources:Map<String, String> = [];

	/** Whether `@:forward` was declared without a field list, forwarding everything. */
	public var forwardsAll:Bool = false;

	/** The field names `@:forward` lists, when it lists any. */
	public var forwarded:Array<String> = [];

	/** The statics the abstract's fields compile to, including its methods. */
	public var impl:ScriptedClass;

	/**
	 * The name the rewritten constructor is stored under. A class skips any field called `new`,
	 * since that is its constructor, and an abstract's is an ordinary static like the rest. The `@`
	 * keeps it out of reach of a script, which cannot write that name.
	 */
	public static inline var CTOR:String = '@new';

	/** The parsed abstract declaration. */
	var decl:AbstractDecl;

	/** True if initialization failed. */
	public var failed:Bool = false;

	/** True once initialized. */
	public var initialized:Bool = false;

	/** True while initializing (guards re-entrancy). */
	public var initializing:Bool = false;

	/**
	 * Creates the runtime abstract from its declaration.
	 *
	 * @param decl The parsed abstract declaration.
	 * @param module The declaring module, if any.
	 */
	public function new(decl:AbstractDecl, ?module:Module) {
		this.name = decl.name;
		this.pack = (module?.pack ?? []);
		this.module = module;
		this.decl = decl;

		path = TypeTools.pathToString(name, pack);
	}

	/**
	 * Builds the implementation class: every field becomes a static, every method gains a leading
	 * `this` parameter, and the constructor returns the value it built.
	 *
	 * @param env The world used to resolve types, if any.
	 * @param baseInterp An interpreter whose imports help resolve types.
	 * @param restore Whether to restore a previous snapshot, passed through to the implementation.
	 */
	public function init(?env:Environment, ?baseInterp:Interp, restore:Bool = true):Void {
		underlying = decl.underlying;
		from = (decl.from ?? []);
		to = (decl.to ?? []);
		ops = [];
		toTargets = [];
		fromSources = [];
		forwardsAll = false;
		forwarded = [];
		readForwards();

		var printer = new Printer();
		var fields:Array<FieldDecl> = [];
		for (f in decl.fields) {
			recordOperators(f);
			recordCasts(f, printer);
			fields.push(f.access.contains(AStatic) ? f : asStatic(f));
		}

		impl = new ScriptedClass({
			name: name,
			meta: decl.meta,
			params: decl.params,
			extend: null,
			implement: [],
			fields: fields,
			isPrivate: decl.isPrivate,
			isExtern: false
		}, module);
		impl.init(env, baseInterp, restore);
		impl.initialized = true;

		if (impl.interp != null)
			impl.interp.imports.set(name, this);
	}

	/**
	 * Reads the abstract's `@:forward` metadata: bare it forwards every field of the underlying value,
	 * with arguments it forwards only those named.
	 */
	function readForwards():Void {
		if (decl.meta == null)
			return;

		for (m in decl.meta) {
			if (m.name != ':forward')
				continue;

			if (m.params == null || m.params.length == 0) {
				forwardsAll = true;
				continue;
			}

			for (p in m.params)
				switch (ExprTools.expr(p)) {
					case EIdent(n):
						forwarded.push(n);
					default:
				}
		}
	}

	/**
	 * Whether a field the abstract does not declare should be read from the value it boxes.
	 *
	 * @param field The field name.
	 * @return True if `@:forward` covers it.
	 */
	public inline function forwards(field:String):Bool {
		return forwardsAll || forwarded.contains(field);
	}

	/**
	 * Records the operators a field serves, so `a + b` can be dispatched to it. Keys match the ones
	 * the interpreter looks up: the operator symbol for a binary operator, `u` plus the symbol for a
	 * unary one, and `[]` / `[]=` for array access.
	 *
	 * @param f The field to inspect.
	 */
	function recordOperators(f:FieldDecl):Void {
		if (f.meta == null)
			return;

		for (m in f.meta) {
			if (m.name == ':arrayAccess') {
				var args:Int = switch (f.kind) {
					case KFunction(fn): fn.args.length;
					default: 0;
				}
				ops.set(args > 1 ? '[]=' : '[]', f.name);
				continue;
			}

			if (m.name != ':op' || m.params == null || m.params.length == 0)
				continue;

			switch (ExprTools.expr(m.params[0])) {
				case EBinop(op, _, _):
					ops.set(op, f.name);
				case EUnop(op, _, _):
					ops.set('u' + op, f.name);
				default:
			}
		}
	}

	/**
	 * Records the implicit conversions a field provides: `@:to` by the type it returns, `@:from` by
	 * the type of the value it accepts.
	 *
	 * @param f The field to inspect.
	 * @param printer Used to name the annotated types.
	 */
	function recordCasts(f:FieldDecl, printer:Printer):Void {
		if (f.meta == null)
			return;

		var fn:FunctionDecl = switch (f.kind) {
			case KFunction(fn): fn;
			default: null;
		}
		if (fn == null)
			return;

		for (m in f.meta) {
			if (m.name == ':to' && fn.ret != null)
				toTargets.set(f.name, printer.typeToString(fn.ret));
			else if (m.name == ':from' && fn.args.length > 0 && fn.args[0].t != null)
				fromSources.set(f.name, printer.typeToString(fn.args[0].t));
		}
	}

	/**
	 * Boxes a value coming from another type, through a matching `@:from` method when one is declared.
	 * Haxe requires a `from` for an implicit conversion; boxing directly when none matches keeps a
	 * scripted abstract usable as the thin wrapper it usually is.
	 *
	 * @param v The value to convert.
	 * @return The boxed value.
	 */
	public function fromValue(v:Dynamic):ScriptedAbstractValue {
		if (v is ScriptedAbstractValue && (cast v : ScriptedAbstractValue).owner == this)
			return v;

		var name:String = AbstractTools.resolveName(v);
		for (f => src in fromSources) {
			if (src != name)
				continue;
			var fn:Dynamic = impl.reflectGetField(f);
			if (fn != null && ReflectProxy.isFunction(fn))
				return new ScriptedAbstractValue(ReflectProxy.callMethod(null, fn, [v]), this);
		}

		return new ScriptedAbstractValue(AbstractTools.underlying(v), this);
	}

	/**
	 * Rewrites an instance field into the static it compiles to: a method takes the boxed value as a
	 * leading `this` argument, and a constructor returns the value it built, since that value is what
	 * the caller boxes.
	 *
	 * @param f The instance field.
	 * @return The equivalent static field.
	 */
	function asStatic(f:FieldDecl):FieldDecl {
		return staticForm(f, name, underlying);
	}

	/**
	 * The implementation form of one of an abstract's fields, independent of any instance.
	 *
	 * @param f The declared field.
	 * @param name The abstract's own name, for spotting self-typed parameters.
	 * @param underlying The type the abstract boxes.
	 * @return The field as it appears on the implementation class.
	 */
	public static function staticForm(f:FieldDecl, name:String, underlying:Null<CType>):FieldDecl {
		function unbox(t:Null<CType>):Null<CType> {
			return switch (t) {
				case CTPath(p, _) if (p.length > 0 && p[p.length - 1] == name): underlying;
				default: t;
			}
		}

		var kind:FieldKind = switch (f.kind) {
			case KFunction(fn):
				var args:Array<Argument> = [{name: 'this', t: underlying}];
				for (a in fn.args)
					args.push({
						name: a.name,
						t: unbox(a.t),
						opt: a.opt,
						value: a.value,
						rest: a.rest
					});
				var body:Expr = fn.expr;

				if (f.name == 'new') {
					var self:Expr = {e: EIdent('this'), pos: body.pos};
					body = {e: EBlock([fn.expr, self]), pos: body.pos};
				}

				KFunction({args: args, expr: body, ret: (f.name == 'new') ? underlying : fn.ret});
			default:
				f.kind;
		}

		return {
			name: (f.name == 'new') ? CTOR : f.name,
			meta: f.meta,
			kind: kind,
			access: f.access.concat([AStatic])
		};
	}

	/**
	 * Replaces a reference to this abstract with the type it boxes, the way Haxe types the arguments
	 * of an abstract's implementation methods. Inside the body a parameter of the abstract's own type
	 * is the underlying value, exactly like `this`, so arithmetic against `this` works and does not
	 * dispatch straight back into the operator method that is running.
	 *
	 * @param t The declared argument type.
	 * @return The type to bind the argument with.
	 */
	function unbox(t:Null<CType>):Null<CType> {
		return switch (t) {
			case CTPath(p, _) if (p.length > 0 && p[p.length - 1] == name): underlying;
			default: t;
		}
	}

	/**
	 * Boxes a value as an instance of this abstract, running the constructor when one is declared.
	 *
	 * @param args The constructor arguments, or the single value to box when there is no constructor.
	 * @return The boxed value.
	 */
	public function create(args:Array<Dynamic>):ScriptedAbstractValue {
		var ctor:Dynamic = impl.reflectGetField(CTOR);
		if (ctor == null)
			return new ScriptedAbstractValue(args[0], this);

		return new ScriptedAbstractValue(ReflectProxy.callMethod(null, ctor, [null].concat(args)), this);
	}

	/**
	 * Whether this abstract declares a field.
	 *
	 * @param field The field name.
	 * @return True if the field exists.
	 */
	public function hasField(field:String):Bool {
		return impl != null && impl.reflectHasField(field);
	}

	/**
	 * Calls one of this abstract's methods against a boxed value.
	 *
	 * @param value The boxed underlying value, passed as the method's `this`.
	 * @param field The method name.
	 * @param args The call arguments.
	 * @return The method's result.
	 */
	public function callField(value:Dynamic, field:String, args:Array<Dynamic>):Dynamic {
		var f:Dynamic = impl.reflectGetField(field);
		if (f == null || !ReflectProxy.isFunction(f))
			return f;
		return ReflectProxy.callMethod(null, f, [value].concat(args ?? []));
	}

	/**
	 * Reads one of this abstract's fields against a boxed value: a property runs its getter, a method
	 * is returned bound to the value, and anything else is the static itself.
	 *
	 * @param value The boxed underlying value.
	 * @param field The field name.
	 * @return The field's value.
	 */
	public function getField(value:Dynamic, field:String):Dynamic {
		if (impl.reflectHasField('get_$field'))
			return callField(value, 'get_$field', []);

		var f:Dynamic = impl.reflectGetField(field);
		if (f != null && ReflectProxy.isFunction(f))
			return ReflectProxy.makeVarArgs(function(args:Array<Dynamic>):Dynamic return callField(value, field, args));

		if (f == null && !impl.reflectHasField(field) && forwards(field))
			return ReflectProxy.getProperty(value, field);

		return f;
	}

	/**
	 * Writes one of this abstract's fields against a boxed value, running a setter when declared.
	 *
	 * @param value The boxed underlying value.
	 * @param field The field name.
	 * @param v The value to write.
	 * @return The written value.
	 */
	public function setField(value:Dynamic, field:String, v:Dynamic):Dynamic {
		if (impl.reflectHasField('set_$field'))
			return callField(value, 'set_$field', [v]);

		if (!impl.reflectHasField(field) && forwards(field)) {
			ReflectProxy.setProperty(value, field, v);
			return v;
		}

		return impl.reflectSetField(field, v);
	}

	/** @return The abstract's path. */
	public function toString():String {
		return path;
	}

	/** Delegates to the implementation, which owns the state. */
	public function snapshot():Void {
		if (impl != null)
			impl.snapshot();
	}
}
