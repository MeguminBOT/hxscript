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
	 * Records a class's constructor shape, which the runtime compiler needs to pad a call.
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
			case _:
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
