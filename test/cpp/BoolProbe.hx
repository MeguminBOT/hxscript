import hxscript.cppia.Backend;
import hxscript.compile.Result;

/**
 * Reads a `Bool` back out of a compiled field every way a host can, jitted and not.
 *
 * `Reflect.field` on a `Bool` member answers `true` interpreted and `1` jitted, and the emitted
 * bytecode is the same in both: `SET FLINK ... CASTBOOL true`. Reading hxcpp's own source says the
 * jitted path stores `hx::DynTrue` and so cannot produce an integer, so the reading has to say which
 * step is the one that lies.
 *
 * Built like the other probes here, then run both ways and diffed:
 *
 * ```
 * haxe -cp src -cp test/common -cp test/common/fixtures -cp test/lib -cp test/cpp \
 *   -D scriptable -D hxscript_cppia -dce no --macro hxscript.macro.Keep.run() \
 *   -main BoolProbe -cpp bin_test/boolprobe
 * ./bin_test/boolprobe/BoolProbe.exe
 * ./bin_test/boolprobe/BoolProbe.exe --nojit
 * ```
 *
 * `Int field, for contrast` is the control: it is meant to read back as `1`, and a run where it does
 * not is a run to distrust.
 */
class BoolProbe {
	static function main():Void {
		Backend.jit = Sys.args().indexOf('--nojit') < 0;
		Sys.println('jit: ' + Backend.jit);

		one('initialiser', 'public var v:Bool = true;', 'return Reflect.field(new T(), "v");');
		one('assigned later', 'public var v:Bool = false; public function set():Void { v = true; }',
			'var t = new T(); t.set(); return Reflect.field(new T() != null ? t : t, "v");');
		one('read directly', 'public var v:Bool = true;', 'return new T().v;');
		one('local, not a field', '', 'var b:Bool = true; return b;');
		one('returned from a method', 'public var v:Bool = true; public function get():Bool return v;', 'return new T().get();');
		one('untyped field', 'public var v = true;', 'return Reflect.field(new T(), "v");');
		one('Int field, for contrast', 'public var v:Int = 1;', 'return Reflect.field(new T(), "v");');
		one('Std.string of a field', 'public var v:Bool = true;', 'return Std.string(Reflect.field(new T(), "v"));');
		one('Std.string of a method', 'public function get():Bool return true;', 'return Std.string(new T().get());');
		one('Bool static return', '', 'return Std.string(yes());', 'static function yes():Bool return true;');
		one('Bool arg round trip', '', 'return Std.string(same(true));', 'static function same(b:Bool):Bool return b;');
	}

	/**
	 * @param label What the case is called.
	 * @param members Extra members for the class.
	 * @param body The static body to run.
	 */
	static function one(label:String, members:String, body:String, statics:String = ''):Void {
		var source:String = 'package p' + count + ';\nclass T {\n' + members + '\n' + statics + '\npublic function new() {}\n'
			+ 'public static function run():Dynamic { ' + body + ' }\n}\n';
		var path:String = 'p' + count + '.T';
		count++;

		try {
			var decls = new hxscript.syntax.Parser().parseModule(source, 'test', 0, [path.split('.')[0]]);
			var result:Result = Backend.compile([{name: path, decls: decls}]);

			if (result.bytes == null) {
				Sys.println(pad(label) + 'refused: ' + result.skipped[0].reason);
				return;
			}

			var module = cpp.cppia.Module.fromData(result.bytes.getData());
			module.boot();
			var cls:Class<Dynamic> = module.resolveClass(path);
			var got:Dynamic = Reflect.callMethod(cls, Reflect.field(cls, 'run'), []);

			Sys.println(pad(label) + 'value=' + Std.string(got) + '   typeof=' + Std.string(Type.typeof(got)));
		} catch (e:Dynamic) {
			Sys.println(pad(label) + 'threw ' + e);
		}
	}

	static var count:Int = 0;

	static function pad(s:String):String {
		return StringTools.rpad('  ' + s, ' ', 26);
	}
}
