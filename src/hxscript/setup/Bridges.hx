package hxscript.setup;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;

/**
 * Step 2: generates one bridge per base scripts may extend.
 */
class Bridges {
	/** The package generated bridges are defined in. */
	static inline var PACK:String = 'hxscript.wired';

	/**
	 * Defines one bridge per base across every active library.
	 *
	 * A `final` class cannot be bridged at all, which is occasionally the right trade: keeping a
	 * hot-path class `final` lets hxcpp devirtualise calls to it.
	 *
	 * @param libs The active libraries.
	 * @return Expressions referencing each generated bridge, for the manifest to hold.
	 */
	public static function generate(libs:Array<Library>):Array<Expr> {
		var refs:Array<Expr> = [];

		if (Context.defined('hxscript_no_bridges'))
			return refs;

		var pos:Position = Context.currentPos();
		var pack:Array<String> = PACK.split('.');
		var taken:Map<String, String> = [];

		for (lib in libs) {
			for (base in lib.bases) {
				var parts:Array<String> = base.split('.');
				var superPath:TypePath = {name: parts[parts.length - 1], pack: parts.slice(0, parts.length - 1)};
				var name:String = 'Scripted' + superPath.name;

				if (Autowire.resolve(base) == null) {
					if (!Autowire.declared(base))
						Context.warning('hxscript: no module found for bridged base $base; scripts cannot extend it', pos);

					continue;
				}

				if (taken.exists(name)) {
					Context.warning('hxscript: bridge name $name already taken by ${taken.get(name)}; skipping $base', pos);
					continue;
				}
				taken.set(name, base);

				Context.defineModule('$PACK.$name', [
					{
						pack: pack,
						name: name,
						pos: pos,
						meta: [{name: ':keep', pos: pos}],
						kind: TDClass(superPath, [{pack: ['hxscript'], name: 'IScripted'}], false, false, false),
						fields: []
					}
				]);

				refs.push(macro $p{pack.concat([name])});
			}
		}

		if (Context.defined('hxscript_verbose')) {
			Context.info('  ${refs.length} bridge(s)', pos);
			for (name => base in taken)
				Context.info('    $PACK.$name extends $base', pos);
		}

		return refs;
	}
}
#end
