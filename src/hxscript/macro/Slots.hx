package hxscript.macro;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;
#end

/**
 * Declares the typed statics `GlobalSlots` hands out, and the switch that fills one.
 *
 * Written by a macro because there is nothing to decide per slot and several hundred of them: a pool
 * per type, each a plain static of that type, plus one `fill` per type dispatching an index to the
 * right field. Doing that by hand would be six hundred lines nobody would read and one typo away
 * from a slot that silently belongs to the wrong name.
 */
class Slots {
	/** The pools, as the prefix each slot's name takes and the type its fields hold. */
	public static var POOLS:Array<{prefix:String, type:String}> = [
		{prefix: 'i', type: 'Int'},
		{prefix: 'f', type: 'Float'},
		{prefix: 'b', type: 'Bool'},
		{prefix: 's', type: 'String'}
	];

	/**
	 * @param kind Which pool.
	 * @param index Which slot in it.
	 * @return The static's name, which is what the emitter writes into the bytecode.
	 */
	public static function nameOf(kind:Int, index:Int):String {
		return POOLS[kind].prefix + index;
	}

	#if macro
	/**
	 * Builds `GlobalSlots`: every pool's fields, and a `fill` per pool.
	 *
	 * @return The class's fields, the declared ones plus the generated ones.
	 */
	public static function build():Array<Field> {
		var fields:Array<Field> = Context.getBuildFields();
		var count:Int = 256;

		for (field in fields) {
			if (field.name != 'PER_TYPE')
				continue;

			switch (field.kind) {
				case FVar(_, {expr: EConst(CInt(v))}):
					count = Std.parseInt(v);
				case _:
			}
		}

		var pos:Position = Context.currentPos();

		for (kind => pool in POOLS) {
			var complex:ComplexType = TPath({pack: [], name: pool.type});
			var cases:Array<Case> = [];

			for (index in 0...count) {
				var name:String = pool.prefix + index;

				fields.push({
					name: name,
					access: [APublic, AStatic],
					kind: FVar(complex, null),
					pos: pos
				});

				cases.push({
					values: [macro $v{index}],
					expr: macro $i{name} = value
				});
			}

			/**
			 * An index the pool does not have is ignored rather than refused. Nothing can reach one:
			 * the emitter only writes an index it was handed, and it is handed one only while the pool
			 * has room. A throw here would turn a bookkeeping slip into a dead process.
			 */
			fields.push({
				name: 'fill' + pool.type,
				access: [APublic, AStatic],
				kind: FFun({
					args: [{name: 'index', type: macro :Int}, {name: 'value', type: complex}],
					ret: macro :Void,
					expr: {expr: ESwitch(macro index, cases, macro null), pos: pos}
				}),
				pos: pos
			});
		}

		return fields;
	}
	#end
}
