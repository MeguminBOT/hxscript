package hxscript.macro;

#if macro
import haxe.macro.Compiler;
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.Type;
import haxe.macro.TypeTools;
import haxe.macro.ExprTools;
import haxe.macro.TypedExprTools;
#end
import hxscript.types.TypeCollection;

/**
 * Compile-time builder of the global `TypeCollection`. After typing, it records a `TypeInfo` for
 * every type in the build (serialized into this class's metadata), then emits runtime code that
 * deserializes it into an indexed `TypeMap`. This is what lets scripts name any compiled type
 * without extra reflection cost.
 */
class Index {
	/** This macro class's own fully-qualified name (used to stash the serialized type table). */
	static var _name:String = 'hxscript.macro.Index';

	/**
	 * Records a class's constructor shape: how many arguments a call has to be padded to, and, for a
	 * constructor a call can be short in the middle of, what each parameter takes.
	 *
	 * @param info The entry being filled.
	 * @param d The class being described.
	 */
	#if macro
	static function recordConstructor(info:TypeInfo, d:Dynamic):Void {
		var ctor:Dynamic = d.constructor;
		if (ctor == null)
			return;

		switch (ctor.get().type) {
			case TFun(args, _):
				info.ctorArgs = args.length;

				var required:Int = 0;
				for (arg in args) {
					if (!arg.opt)
						required++;
				}

				info.ctorRequired = required;
				info.ctorSkip = skipShape(args);
			case _:
		}
	}

	/**
	 * The constructor's parameters, written down only when a call can be short in the middle.
	 *
	 * Haxe fits a short call to a longer signature by dropping an optional parameter whose type the
	 * argument does not have: `new Mesh(prim, parent)` against `(primitive, ?material, ?parent)` is
	 * three parameters, not two, and the compiler decides which one is missing by asking what each
	 * argument is. Nothing at runtime carries that question's inputs, so it is recorded here.
	 *
	 * A constructor whose optionals are all at the end is left out. Leaving the last one off is a
	 * shorter argument list and every target already pads that, so recording those would be paying
	 * for every class in the build to describe what nothing needs to ask.
	 *
	 * @param args The constructor's parameters.
	 * @return The shape, or null when no call of it can be short in the middle.
	 */
	static function skipShape(args:Array<{name:String, opt:Bool, t:haxe.macro.Type}>):Null<String> {
		var skippable:Bool = false;

		for (i in 0...args.length)
			if (args[i].opt && i < args.length - 1)
				skippable = true;

		if (!skippable)
			return null;

		var out:Array<String> = [];
		for (arg in args)
			out.push((arg.opt ? '?' : '') + testable(arg.t));

		return out.join('|');
	}

	/**
	 * What a value can be tested against to decide whether it is one of these.
	 *
	 * Deliberately narrow. A wrong answer here moves an argument into a parameter the caller did not
	 * mean, so anything the runtime cannot decide plainly is left blank and the argument stays where
	 * the call put it. That covers type parameters, functions, structures and `Dynamic`, and also
	 * every abstract but the basic ones: an abstract reaches a script as a wrapper around its value
	 * rather than as itself, so asking whether one is an `h3d.Vector` is a question about this
	 * library's wrappers rather than about the argument.
	 *
	 * @param t The parameter's declared type.
	 * @return A type path to resolve at runtime, or the empty string for a parameter that takes
	 *         whatever it is given.
	 */
	static function testable(t:haxe.macro.Type):String {
		return switch (t) {
			case TLazy(f):
				testable(f());
			case TType(_, _):
				testable(Context.follow(t));
			case TMono(r):
				r.get() == null ? '' : testable(r.get());
			case TInst(r, _):
				var c = r.get();
				switch (c.kind) {
					case KTypeParameter(_): '';
					case _: (c.pack.length > 0 ? c.pack.join('.') + '.' : '') + c.name;
				}
			case TEnum(r, _):
				var e = r.get();
				(e.pack.length > 0 ? e.pack.join('.') + '.' : '') + e.name;
			case TAbstract(r, params):
				var a = r.get();
				switch (a.name) {
					case 'Null': params.length == 1 ? testable(params[0]) : '';
					case 'Int' | 'Float' | 'Single' | 'Bool': a.name;
					case _: '';
				}
			case _:
				'';
		}
	}
	#end

	/**
	 * Records every build type's info at compile time and emits code to rebuild the indexed map at runtime.
	 *
	 * @return An expression evaluating to the populated `TypeMap`.
	 */
	public static macro function build() {
		Context.onAfterTyping(function(types) {
			var self = TypeTools.getClass(Context.getType(_name));
			if (self.meta.has('typed'))
				return;

			var _c:Map<String, Dynamic> = [];
			var map:Array<Dynamic> = [];

			/**
			 * Looks up an already-recorded type by module and name.
			 *
			 * @param m The module path.
			 * @param s The type name.
			 * @return The recorded info, or null.
			 */
			function findTypeInfo(m:String, s:String) {
				return _c['$m.$s'];
			}
			/**
			 * Records one module type in the table scripts resolve names against.
			 *
			 * @param type The type to record.
			 * @return Its entry.
			 */
			function getTypeInfo(type:haxe.macro.ModuleType) {
				/**
				 * Builds or updates a single type entry.
				 *
				 * @param k The kind (`class`, `enum`, `typedef`, `abstract`).
				 * @param d The type being described.
				 * @return The entry.
				 */
				function makeTypeInfo(k:String, d:Dynamic) {
					var info:TypeInfo = (findTypeInfo(d.module, d.name) ?? {
						kind: k,
						module: d.module,
						name: d.name,
						pack: d.pack
					});
					if (k == 'typedef') {
						info.typedefType = switch (d.type) {
							case TInst(r, _): makeTypeInfo('class', r.get());
							case TType(r, _): makeTypeInfo('typedef', r.get());
							case TEnum(r, _): makeTypeInfo('enum', r.get());
							case TAbstract(r, _): makeTypeInfo('abstract', r.get());
							default: null;
						}
					}
					if (d.isInterface) {
						info.isInterface = true;
					}
					if (k == 'class') {
						recordConstructor(info, d);
					}
					_c['${d.module}.${d.name}'] = info;
					return info;
				}

				return switch (type) {
					case TClassDecl(r): return makeTypeInfo('class', r.get());
					case TEnumDecl(r): return makeTypeInfo('enum', r.get());
					case TTypeDecl(r): return makeTypeInfo('typedef', r.get());
					case TAbstract(r): return makeTypeInfo('abstract', r.get());
				};
			}

			for (type in types)
				map.push(getTypeInfo(type));

			self.meta.add('typed', [macro $v{haxe.Serializer.run(map)}], self.pos);
		});

		return macro {
			var meta:Array<TypeInfo> = cast haxe.Unserializer.run(haxe.rtti.Meta.getType($p{_name.split('.')}).typed[0]);
			var map:TypeMap = {
				byPackage: [],
				byModule: [],
				byPath: [],
				byCompilePath: [],
				all: []
			};

			for (info in meta) {
				var tp:Array<String> = info.pack.copy();
				tp.push(info.name);
				var packPath:String = info.pack.join('.');

				map.all.push(info);

				map.byCompilePath[tp.join('.')] = [info];
				map.byPath[info.module + (info.module.length == 0 ? '' : '.') + info.name] = [info];

				map.byModule[info.module] ??= new Array<TypeInfo>();
				map.byPackage[packPath] ??= new Array<TypeInfo>();

				map.byModule[info.module].push(info);
				map.byPackage[packPath].push(info);
			}

			cast map;
		}
	}
}
