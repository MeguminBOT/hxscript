import hxscript.Environment;
import hxscript.Module;
import hxscript.compile.Cppia;
import hxscript.compile.Unit;
import hxscript.compile.Result;
import hxscript.types.ScriptedClass;

/**
 * Statics initialised at their declaration, read from another module.
 *
 * A static whose initialiser constructs something has to run that constructor before any other
 * module can touch the field. Getting that wrong does not fail where the field is: the holding
 * module stays uninitialised, and the first sign of it is the *consumer* reporting that the holding
 * type does not exist at all. That misdirection is why this is worth its own test rather than being
 * folded into the general world case.
 *
 * Each case builds a two-module world twice, once wholly interpreted and once with the holder
 * compiled, and the two answers must agree.
 */
class StaticInitTest {
	public static function run():Void {
		cpp.cppia.Host.enableJit(true);

		check('map literal static', 'Map<String, Int>', 'new Map<String, Int>()', 'store.set("a", 5); return store.exists("a") ? store.get("a") : -1;', '5');

		check('string map static', 'haxe.ds.StringMap<Int>', 'new haxe.ds.StringMap<Int>()', 'store.set("a", 6); return store.get("a");', '6');

		check('int map static', 'Map<Int, Int>', 'new Map<Int, Int>()', 'store.set(1, 7); return store.get(1);', '7');

		check('array static', 'Array<Int>', 'new Array<Int>()', 'store.push(8); return store[0];', '8');

		check('array literal static', 'Array<Int>', '[1, 2, 3]', 'return store[0] + store[2];', '4');

		check('nested array static', 'Array<Array<Int>>', '[[1, 2], [3, 4]]', 'return store[1][0];', '3');

		check('string buf static', 'StringBuf', 'new StringBuf()', 'store.add("hi"); return store.toString();', 'hi');

		// The shape that actually broke a mod: a map whose value is itself parameterised.
		check('map of arrays static', 'Map<String, Array<Int>>', 'new Map<String, Array<Int>>()',
			'store.set("a", [1, 2]); return store.get("a")[1];', '2');

		check('string map of arrays static', 'haxe.ds.StringMap<Array<Int>>', 'new haxe.ds.StringMap<Array<Int>>()',
			'store.set("a", [3, 4]); return store.get("a")[1];', '4');

		check('map of arrays lazy', 'Map<String, Array<Int>>', 'null',
			'store = new Map<String, Array<Int>>(); store.set("a", [5, 6]); return store.get("a")[1];', '6');

		chain();
		assignTargets();
	}

	/**
	 * Assignment targets that are not a plain local or field.
	 *
	 * cppia rejects a module outright with "Bad Set expr" or "Bad increment" when it is handed an
	 * assignment it cannot place, and the message names nothing inside the module, so the shape has
	 * to be found by elimination.
	 *
	 * Not covered here: a postfix increment used as a *value*, as in `var v = h.n++`. The emitter
	 * handles it, but hxScript's parser does not accept the form at all, so there is no way to reach
	 * the emitted code from a test. That is a parser gap and belongs with the parser.
	 */
	static function assignTargets():Void {
		var holder:String = 'package w;
'
			+ 'class Holder {
'
			+ '	public var rows:Array<Int>;
'
			+ '	public var idx:Int = 1;
'
			+ '	public function new() { rows = [0, 0, 0]; }
'
			+ '}
'
			+ 'class Outer {
'
			+ '	public var h:Holder;
'
			+ '	public function new() { h = new Holder(); }
'
			+ '}
';

		var cases:Array<Array<String>> = [
			['elem, literal index', 'var h = new Holder(); h.rows[1] = 7; return h.rows[1];', '7'],
			['elem, index from field', 'var h = new Holder(); h.rows[h.idx] = 8; return h.rows[1];', '8'],
			['elem via a local hop', 'var h = new Holder(); var r = h.rows; r[2] = 9; return h.rows[2];', '9'],
			['compound on elem', 'var h = new Holder(); h.rows[0] = 2; h.rows[0] += 3; return h.rows[0];', '5'],
			['increment on elem', 'var h = new Holder(); h.rows[0] = 4; h.rows[0]++; return h.rows[0];', '5'],
			['field of field', 'var h = new Holder(); h.idx = 6; return h.idx;', '6'],
			['or-assign on a local field', 'var h = new Holder(); h.idx = 1; h.idx |= 2; return h.idx;', '3'],
			['and-assign on a local field', 'var h = new Holder(); h.idx = 7; h.idx &= 5; return h.idx;', '5'],
			['plus-assign on a local field', 'var h = new Holder(); h.idx = 1; h.idx += 4; return h.idx;', '5'],
			['increment on a local field', 'var h = new Holder(); h.idx = 1; h.idx++; return h.idx;', '2'],
			['decrement on a local field', 'var h = new Holder(); h.idx = 5; h.idx--; return h.idx;', '4'],
			['compound through two fields', 'var o = new Outer(); o.h.idx = 1; o.h.idx |= 6; return o.h.idx;', '7'],
			['increment through two fields', 'var o = new Outer(); o.h.idx = 1; o.h.idx++; return o.h.idx;', '2']
		];

		for (item in cases) {
			var reader:String = 'package w;
import w.Holder;
class Reader {
	public static function go():Dynamic {
		'
				+ item[1] + '
	}
}
';

			var got:String = build(holder, reader, ['w.Holder', 'w.Reader']);
			if (got != item[2]) {
				TestCase.bad('assign ' + item[0], 'gave ' + got + ', expected ' + item[2]);
			} else {
				TestCase.ok('assign ' + item[0] + '   ' + got, true);
			}
		}
	}

	/**
	 * A static that calls another static of its own class, reached from a second module.
	 *
	 * This is the shape that failed in a real mod: the consumer reported the holder's *type* as not
	 * found, and the link error named the outer static. Both modules are compiled, which is the
	 * arrangement a whole-world compile produces and the one a single-module test never reaches.
	 */
	static function chain():Void {
		var holder:String = 'package w;\n'
			+ 'class Holder {\n'
			+ '\tstatic var cache:Map<String, Array<Int>> = null;\n'
			+ '\tpublic static function raw(key:String):Array<Int> {\n'
			+ '\t\tif (cache == null) cache = new Map<String, Array<Int>>();\n'
			+ '\t\tif (cache.exists(key)) return cache.get(key);\n'
			+ '\t\tvar out:Array<Int> = [200, 60, 5];\n'
			+ '\t\tcache.set(key, out);\n'
			+ '\t\treturn out;\n'
			+ '\t}\n'
			+ '\tpublic static function signed(key:String):Array<Int> {\n'
			+ '\t\tvar src:Array<Int> = raw(key);\n'
			+ '\t\tif (src == null) return null;\n'
			+ '\t\tvar out:Array<Int> = [];\n'
			+ '\t\tvar i:Int = 0;\n'
			+ '\t\twhile (i < src.length) { var v:Int = src[i]; out.push(v > 127 ? v - 256 : v); i++; }\n'
			+ '\t\treturn out;\n'
			+ '\t}\n'
			+ '}\n';

		var reader:String = 'package w;\n'
			+ 'import w.Holder;\n'
			+ 'class Reader {\n'
			+ '\tstatic var got:Array<Int> = null;\n'
			+ '\tpublic static function go():Dynamic {\n'
			+ '\t\tgot = Holder.signed("t");\n'
			+ '\t\treturn got[0] + "," + got[1] + "," + got[2];\n'
			+ '\t}\n'
			+ '}\n';

		var want:String = '-56,60,5';

		var cases:Array<{name:String, compile:Array<String>}> = [
			{name: 'nothing compiled', compile: []},
			{name: 'holder compiled only', compile: ['w.Holder']},
			{name: 'reader compiled only', compile: ['w.Reader']},
			{name: 'both compiled', compile: ['w.Holder', 'w.Reader']}
		];

		for (item in cases) {
			var got:String = build(holder, reader, item.compile);
			if (got != want) {
				TestCase.bad('static chain, ' + item.name, 'gave ' + got + ', expected ' + want);
			} else {
				TestCase.ok('static chain, ' + item.name + '   ' + got, true);
			}
		}
	}

	/**
	 * Builds a holder whose static is initialised inline, and a reader in another module.
	 *
	 * @param type    the static's declared type
	 * @param init    the initialiser expression
	 * @param body    what the reader does with it, as the body of a static returning Dynamic
	 * @param want    the expected result
	 */
	static function check(label:String, type:String, init:String, body:String, want:String):Void {
		var holder:String = 'package w;\nclass Holder {\n\tpublic static var store:' + type + ' = ' + init + ';\n}\n';
		var reader:String = 'package w;\nimport w.Holder;\nclass Reader {\n\tpublic static function go():Dynamic {\n\t\tvar store = Holder.store;\n\t\t' + body + '\n\t}\n}\n';

		var interpreted:String = build(holder, reader, []);
		var compiled:String = build(holder, reader, ['w.Holder']);

		if (interpreted != want) {
			TestCase.bad(label, 'interpreted gave ' + interpreted + ', expected ' + want);
			return;
		}

		if (compiled != want) {
			TestCase.bad(label, 'compiled gave ' + compiled + ', expected ' + want);
			return;
		}

		TestCase.ok(label + '   ' + compiled, true);
	}

	static function build(holder:String, reader:String, compile:Array<String>):String {
		try {
			var env:Environment = new Environment();
			var sources:Array<{name:String, pack:Array<String>, code:String}> = [
				{name: 'Holder', pack: ['w'], code: holder},
				{name: 'Reader', pack: ['w'], code: reader}
			];

			var modules:Array<Module> = [];
			for (source in sources) {
				var module:Module = new Module(source.code, source.name, source.pack, source.name);
				env.addModule(module);
				modules.push(module);
			}

			for (module in modules)
				module.init(env);
			for (module in modules)
				module.start(env);
			for (module in modules)
				module.startTypes(env);

			if (compile.length > 0)
				compileInto(env, sources, compile);

			var cls:ScriptedClass = cast env.resolve('w.Reader');
			return Std.string(Reflect.callMethod(null, cls.reflectGetField('go'), []));
		} catch (e:Dynamic) {
			return 'threw: ' + e;
		}
	}

	static function compileInto(env:Environment, sources:Array<{name:String, pack:Array<String>, code:String}>, wanted:Array<String>):Void {
		var inputs:Array<Unit> = [];
		var outside:Array<String> = [];

		for (source in sources) {
			var path:String = source.pack.join('.') + '.' + source.name;
			var decls = new hxscript.syntax.Parser().parseModule(source.code, source.name, 0, source.pack);

			if (wanted.indexOf(path) >= 0)
				inputs.push({name: source.name, decls: decls});
			else
				outside.push(path);
		}

		var result:Result = Cppia.compile(inputs, null, outside, []);
		if (result.bytes == null)
			return;

		var loaded = cpp.cppia.Module.fromData(result.bytes.getData());
		loaded.boot();

		#if hxscript_cppia
		for (path in wanted) {
			var cls:Class<Dynamic> = loaded.resolveClass(path);
			if (cls != null)
				env.compiled.set(path, cls);
		}

		env.substituting = env.compiled.keys().hasNext();
		#end
	}
}
