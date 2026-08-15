import hxscript.hl.TypeKind;
import hxscript.hl.Loader;
import hxscript.hl.Loader.Loaded;
import hxscript.hl.Bytecode;
import hxscript.hl.Opcode;
import hxscript.hl.TypeEntry;

/**
 * Builds modules here and has HashLink load and run them.
 *
 * The reader is the only thing that can say whether a layout is right, and it rejects a whole
 * module rather than pointing at the byte that was wrong, so these start at the smallest module
 * that can run and grow one construct at a time.
 *
 * Every entry point returns `Dynamic`, boxing its result with `OToDyn` first. That is not a
 * convenience for the probe: a host reads the result through a closure it has to be able to type,
 * and the value a script produced has no type the host knows until it is boxed.
 */
class WriterProbe {
	static var passed:Int = 0;
	static var failed:Int = 0;

	static var only:String = null;

	static function run(label:String, build:Bytecode->Int, want:Dynamic):Void {
		if (only != null && label != only)
			return;

		var m:Bytecode = new Bytecode();
		var findex:Int = build(m);
		m.entry = findex;

		var raw:haxe.io.Bytes = m.pack();
		var loaded:Loaded = Loader.load(raw);

		if (loaded == null) {
			say(label, 'REFUSED ' + (Loader.error() ?? 'no reason given'));
			failed++;
			return;
		}

		var fn:Dynamic = Loader.bind(loaded, findex);
		if (fn == null) {
			say(label, 'no closure for the entry point');
			failed++;
			return;
		}

		var got:Dynamic = Reflect.callMethod(null, fn, []);
		if (Std.string(got) == Std.string(want)) {
			passed++;
			say(label, Std.string(got));
		} else {
			failed++;
			say(label, Std.string(got) + '   WANTED ' + Std.string(want));
		}
	}

	static function say(label:String, what:String):Void {
		var pad:String = label;
		while (pad.length < 30)
			pad += ' ';
		Sys.println('  ' + pad + what);
		Sys.stdout().flush();
	}

	public static function main():Void {
		var args:Array<String> = Sys.args();
		if (args.length > 0)
			only = args[0];

		Sys.println('-- modules built here, read by HashLink --');

		run('a constant', function(m:Bytecode):Int {
			var i32:Int = m.prim(HI32);
			var dyn:Int = m.prim(HDyn);
			var f:Int = m.reserve();

			m.add({
				type: m.typeId(TFun([], dyn)),
				findex: f,
				regs: [i32, dyn],
				ops: [{op: OInt, args: [0, m.intId(42)]}, {op: OToDyn, args: [1, 0]}, {op: ORet, args: [1]}]
			});
			return f;
		}, 42);

		run('addition', function(m:Bytecode):Int {
			var i32:Int = m.prim(HI32);
			var dyn:Int = m.prim(HDyn);
			var f:Int = m.reserve();

			m.add({
				type: m.typeId(TFun([], dyn)),
				findex: f,
				regs: [i32, i32, i32, dyn],
				ops: [
					{op: OInt, args: [0, m.intId(300)]},
					{op: OInt, args: [1, m.intId(45)]},
					{op: OAdd, args: [2, 0, 1]},
					{op: OToDyn, args: [3, 2]},
					{op: ORet, args: [3]}
				]
			});
			return f;
		}, 345);

		run('a loop with a back jump', function(m:Bytecode):Int {
			var i32:Int = m.prim(HI32);
			var dyn:Int = m.prim(HDyn);
			var f:Int = m.reserve();

			m.add({
				type: m.typeId(TFun([], dyn)),
				findex: f,
				regs: [i32, i32, i32, dyn],
				ops: [
					{op: OInt, args: [0, m.intId(0)]},
					{op: OInt, args: [1, m.intId(0)]},
					{op: OInt, args: [2, m.intId(1000)]},
					{op: OLabel, args: []},
					{op: OJSGte, args: [1, 2, 3]},
					{op: OAdd, args: [0, 0, 1]},
					{op: OIncr, args: [1]},
					{op: OJAlways, args: [-5]},
					{op: OToDyn, args: [3, 0]},
					{op: ORet, args: [3]}
				]
			});
			return f;
		}, 499500);

		run('a call between functions', function(m:Bytecode):Int {
			var i32:Int = m.prim(HI32);
			var dyn:Int = m.prim(HDyn);

			var twice:Int = m.reserve();
			var entry:Int = m.reserve();

			m.add({
				type: m.typeId(TFun([i32], i32)),
				findex: twice,
				regs: [i32, i32],
				ops: [{op: OAdd, args: [1, 0, 0]}, {op: ORet, args: [1]}]
			});

			m.add({
				type: m.typeId(TFun([], dyn)),
				findex: entry,
				regs: [i32, i32, dyn],
				ops: [
					{op: OInt, args: [0, m.intId(21)]},
					{op: OCall1, args: [1, twice, 0]},
					{op: OToDyn, args: [2, 1]},
					{op: ORet, args: [2]}
				]
			});
			return entry;
		}, 42);

		run('float arithmetic', function(m:Bytecode):Int {
			var f64:Int = m.prim(HF64);
			var dyn:Int = m.prim(HDyn);
			var f:Int = m.reserve();

			m.add({
				type: m.typeId(TFun([], dyn)),
				findex: f,
				regs: [f64, f64, f64, dyn],
				ops: [
					{op: OFloat, args: [0, m.floatId(1.5)]},
					{op: OFloat, args: [1, m.floatId(2.25)]},
					{op: OMul, args: [2, 0, 1]},
					{op: OToDyn, args: [3, 2]},
					{op: ORet, args: [3]}
				]
			});
			return f;
		}, 3.375);

		run('recursion', function(m:Bytecode):Int {
			var i32:Int = m.prim(HI32);
			var dyn:Int = m.prim(HDyn);

			var fib:Int = m.reserve();
			var entry:Int = m.reserve();

			m.add({
				type: m.typeId(TFun([i32], i32)),
				findex: fib,
				regs: [i32, i32, i32, i32],
				ops: [
					{op: OInt, args: [1, m.intId(2)]},
					{op: OJSGte, args: [0, 1, 1]},
					{op: ORet, args: [0]},
					{op: OInt, args: [1, m.intId(1)]},
					{op: OSub, args: [1, 0, 1]},
					{op: OCall1, args: [1, fib, 1]},
					{op: OInt, args: [2, m.intId(2)]},
					{op: OSub, args: [2, 0, 2]},
					{op: OCall1, args: [2, fib, 2]},
					{op: OAdd, args: [3, 1, 2]},
					{op: ORet, args: [3]}
				]
			});

			m.add({
				type: m.typeId(TFun([], dyn)),
				findex: entry,
				regs: [i32, i32, dyn],
				ops: [
					{op: OInt, args: [0, m.intId(20)]},
					{op: OCall1, args: [1, fib, 0]},
					{op: OToDyn, args: [2, 1]},
					{op: ORet, args: [2]}
				]
			});
			return entry;
		}, 6765);

		Sys.println('== ' + passed + ' passed, ' + failed + ' failed ==');
		Sys.exit(failed == 0 ? 0 : 1);
	}
}
