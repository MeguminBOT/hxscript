import hxscript.Environment;
import hxscript.Module;
import hxscript.types.ScriptedClass;
import TestCase.ok;

/**
 * Imports across modules of one world, and `import pack.*` in particular.
 *
 * A wildcard used to reach nothing a package declared: the filter that keeps a module's main type
 * compared the whole module path against the type's name, so `game.core.Handoff` never matched
 * `Handoff` and every packaged type was dropped. Only an unpackaged module could survive it, which
 * is why the root wildcard in the default imports looked fine.
 */
class ImportTest {
	public static function run():Void {
		var pack:Array<{pack:String, name:String, body:String}> = [
			{pack: 'game.core', name: 'Handoff', body: 'public static function tag():String return "handoff";'},
			{pack: 'game.core', name: 'Modes', body: 'public static function tag():String return "modes";'},
			{pack: 'game.core', name: 'Consts', body: 'public static var SIZE:Int = 10;'}
		];

		ok('a wildcard reaches every class in the package',
			world(pack, 'game', 'Play', 'import game.core.*;', 'return Handoff.tag() + "/" + Modes.tag() + "/" + Consts.SIZE;')
			== 'handoff/modes/10');

		ok('the order modules were added does not matter',
			worldReversed(pack, 'game', 'Play', 'import game.core.*;', 'return Modes.tag();') == 'modes');

		ok('a wildcard does not reach a nested package',
			world([{pack: 'game.core.deep', name: 'Buried', body: 'public static function tag():String return "buried";'}],
				'game', 'Play', 'import game.core.*;', 'return Buried.tag();').indexOf('threw') == 0);

		ok('naming one type still works', world(pack, 'game', 'Play', 'import game.core.Handoff;', 'return Handoff.tag();') == 'handoff');

		ok('an alias still works', world(pack, 'game', 'Play', 'import game.core.Handoff as H;', 'return H.tag();') == 'handoff');

		ok('a wildcard beside an alias keeps both',
			world(pack, 'game', 'Play', 'import game.core.*;\nimport game.core.Modes as M;', 'return Handoff.tag() + "/" + M.tag();')
			== 'handoff/modes');

		/*
			A module of the user's own package, which Haxe resolves with nothing written at all.

			This needed an import, and the failure did not surface at the name: it surfaced at the
			first use, as `Invalid access to field` interpreted and `Cannot call` compiled, so both
			sides reported it the same way and a conformance pass read it as unsupported everywhere
			rather than as a defect. Every module of a packaged project had to import its own
			siblings, which is not a script anybody writes.
		*/
		var near:Array<{pack:String, name:String, body:String}> = [
			{
				pack: 'game',
				name: 'Near',
				body: 'public var n:Int = 3; public function new() {} public function twice():Int return n * 2; '
				+ 'public static function tag():String return "near";'
			}
		];

		ok('a sibling module is constructed and called with no import', world(near, 'game', 'Play', '', 'var v = new Near(); return v.twice();') == '6');

		ok('a sibling module satisfies an annotation', world(near, 'game', 'Play', '', 'var v:Near = new Near(); return v.twice();') == '6');

		ok('a sibling module\'s static is reached with no import', world(near, 'game', 'Play', '', 'return Near.tag();') == 'near');

		// Imports are read before the package is, which is the order Haxe reads them in: the import
		// is the more deliberate of the two and a module that writes one means it.
		ok('an import wins over a sibling of the same name',
			world([
				{pack: 'game', name: 'Twin', body: 'public static function tag():String return "mine";'},
				{pack: 'other', name: 'Twin', body: 'public static function tag():String return "theirs";'}
			], 'game', 'Play', 'import other.Twin;', 'return Twin.tag();')
			== 'theirs');

		// The other half of the same rule. Reaching a sibling must not turn into reaching anything.
		ok('another package is still not reached without an import',
			world([{pack: 'far', name: 'Away', body: 'public static function tag():String return "away";'}], 'game', 'Play', '',
				'return Away.tag();')
				.indexOf('threw') == 0);

		ok('a nested package of the module\'s own is still not reached',
			world([{pack: 'game.deep', name: 'Buried', body: 'public static function tag():String return "buried";'}], 'game', 'Play', '',
				'return Buried.tag();')
				.indexOf('threw') == 0);
	}

	/**
	 * @param pack The classes to put in the world before the user.
	 * @param userPack The user's package.
	 * @param userName The user's class name.
	 * @param head Its import lines.
	 * @param body Its `run` body.
	 * @return What `run` answered, or `threw: <e>`.
	 */
	static function world(pack:Array<{pack:String, name:String, body:String}>, userPack:String, userName:String, head:String,
			body:String):String {
		return build(pack, userPack, userName, head, body, false);
	}

	/** As `world`, but the user is added before the package it imports. */
	static function worldReversed(pack:Array<{pack:String, name:String, body:String}>, userPack:String, userName:String, head:String,
			body:String):String {
		return build(pack, userPack, userName, head, body, true);
	}

	static function build(pack:Array<{pack:String, name:String, body:String}>, userPack:String, userName:String, head:String, body:String,
			userFirst:Bool):String {
		try {
			var env:Environment = new Environment();

			var user:Void->Void = function():Void {
				add(env, userPack, userName, 'public static function run():Dynamic { ' + body + ' }', head);
			};

			if (userFirst)
				user();

			for (one in pack)
				add(env, one.pack, one.name, one.body);

			if (!userFirst)
				user();

			for (module in env.modules)
				module.init(env);
			for (module in env.modules) {
				module.start(env);
				module.startTypes(env);
			}

			var cls:ScriptedClass = cast env.resolve(userPack + '.' + userName);
			return Std.string(Reflect.callMethod(null, cls.reflectGetField('run'), []));
		} catch (e:Dynamic) {
			return 'threw: ' + Std.string(e);
		}
	}

	/**
	 * @param env The world.
	 * @param pack The package, dotted.
	 * @param name The class name.
	 * @param body Its members.
	 * @param head Declarations above the class.
	 */
	static function add(env:Environment, pack:String, name:String, body:String, head:String = ''):Void {
		var module:Module = new Module('', name, pack.split('.'), 'importtest');
		module.parse('package ' + pack + ';\n' + head + '\nclass ' + name + ' {\n' + body + '\n}\n');
		env.addModule(module);
	}
}
