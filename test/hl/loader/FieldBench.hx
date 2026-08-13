import hxscript.hl.TypeKind;
import hxscript.hl.Loader;
import hxscript.hl.Loader.Loaded;
import hxscript.hl.Bytecode;
import hxscript.hl.Opcode;
import hxscript.hl.TypeEntry;

/** What the loops read a field off. An ordinary Haxe class, which is what a host object is. */
class Target {
	public var v:Int;

	public function new() {
		v = 3;
	}
}

/**
 * What reading a host object's field costs, by each of the ways bytecode can do it.
 *
 * This is the measurement the HashLink backend was restarted over. The archived attempt reached 582x
 * interpreted on typed locals and 2.2x on a host field, and a host field is what a real script
 * touches on every line, so the average script saw almost none of the 582. The cause was the route:
 * every access called a Haxe function taking Dynamic arguments.
 *
 * Four rows, and the emitter is not written yet, so each loop is bytecode built here by hand. They
 * differ only in how the field is read:
 *
 *   native      Haxe's own compiled field access, the ceiling
 *   ODynGet     what HashLink offers unaided, a direct call to hl_dyn_geti with the hash baked in
 *   hxs.geti    a native call with an inline cache, which is what this backend will emit
 *   a closure   a call out to a Haxe function, which is what the archived backend emitted
 */
class FieldBench {
	static inline var LOOPS:Int = 3000000;

	static var target:Target = new Target();

	/** The shape the archived backend reached the host through: a Haxe function taking Dynamic. */
	public static function fetch(o:Dynamic):Dynamic {
		return Reflect.field(o, 'v');
	}

	static function report(label:String, seconds:Float, answer:Dynamic):Void {
		var ok:Bool = answer == LOOPS * 3;
		Sys.println(StringTools.rpad('  ' + label, ' ', 16)
			+ StringTools.lpad(Std.string(Math.round(seconds * 1000)), ' ', 6) + ' ms'
			+ StringTools.lpad(Std.string(Math.round(seconds * 1000000000 / LOOPS * 10) / 10), ' ', 8) + ' ns/read'
			+ (ok ? '' : '   WRONG ANSWER ' + answer));
	}

	/**
	 * Builds a module whose entry point loops over one way of reading the field.
	 *
	 * Registers are the same in all of them: 0 the object it was handed, 1 the running total, 2 the
	 * counter, 3 the limit, 4 what the read produced, 5 the boxed result. A variant may use 6 upwards
	 * for whatever its own read needs.
	 *
	 * @param read The instructions that leave the field's value in register 4.
	 * @param setup Anything that has to happen once before the loop.
	 * @param regs The register types, which a variant extends.
	 * @return The module, ready to load.
	 */
	static function loop(m:Bytecode, regs:Array<Int>, setup:Array<Instruction>, read:Array<Instruction>):Int {
		var dyn:Int = m.prim(HDyn);
		var entry:Int = m.reserve();

		var step:Array<Instruction> = [
			({op: OAdd, args: [1, 1, 4]} : Instruction),
			({op: OIncr, args: [2]} : Instruction)
		];

		var body:Array<Instruction> = read.concat(step);

		var head:Array<Instruction> = [
			({op: OInt, args: [1, m.intId(0)]} : Instruction),
			({op: OInt, args: [2, m.intId(0)]} : Instruction),
			({op: OInt, args: [3, m.intId(LOOPS)]} : Instruction)
		];

		var gate:Array<Instruction> = [
			({op: OLabel, args: []} : Instruction),
			({op: OJSGte, args: [2, 3, body.length + 1]} : Instruction)
		];

		var tail:Array<Instruction> = [
			({op: OJAlways, args: [-(body.length + 3)]} : Instruction),
			({op: OToDyn, args: [5, 1]} : Instruction),
			({op: ORet, args: [5]} : Instruction)
		];

		var ops:Array<Instruction> = head.concat(setup).concat(gate).concat(body).concat(tail);

		m.add({
			type: m.typeId(TFun([dyn], dyn)),
			findex: entry,
			regs: regs,
			ops: ops
		});

		return entry;
	}

	/** Loads a module and times one call into it. */
	static function time(label:String, m:Bytecode, entry:Int, ?fill:Loaded->Void):Void {
		var loaded:Null<Loaded> = Loader.load(m.pack());

		if (loaded == null) {
			Sys.println('  ' + label + ': REFUSED ' + (Loader.error() ?? 'no reason given'));
			return;
		}

		if (fill != null)
			fill(loaded);

		var fn:Dynamic = Loader.bind(loaded, entry);
		var started:Float = haxe.Timer.stamp();
		var answer:Dynamic = Reflect.callMethod(null, fn, [target]);
		report(label, haxe.Timer.stamp() - started, answer);
	}

	public static function main():Void {
		if (!Loader.available) {
			Sys.println('  the loader is not usable: ' + Loader.why());
			Sys.exit(1);
		}

		Sys.println('-- reading one Int field of a host object, ' + LOOPS + ' times --');

		var total:Int = 0;
		var started:Float = haxe.Timer.stamp();
		for (i in 0...LOOPS)
			total += target.v;
		report('native', haxe.Timer.stamp() - started, total);

		var byOpcode:Bytecode = new Bytecode();
		{
			var i32:Int = byOpcode.prim(HI32);
			var dyn:Int = byOpcode.prim(HDyn);
			var entry:Int = loop(byOpcode, [dyn, i32, i32, i32, i32, dyn], [], [
				{op: ODynGet, args: [4, 0, byOpcode.stringId('v')]}
			]);
			time('ODynGet', byOpcode, entry);
		}

		var byNative:Bytecode = new Bytecode();
		{
			var i32:Int = byNative.prim(HI32);
			var dyn:Int = byNative.prim(HDyn);
			var geti:Int = byNative.native('hxs', 'geti', byNative.typeId(TFun([dyn, i32, i32], i32)));

			var entry:Int = loop(byNative, [dyn, i32, i32, i32, i32, dyn, i32, i32], [
				{op: OInt, args: [6, byNative.intId(Loader.hash('v'))]},
				{op: OInt, args: [7, byNative.intId(Loader.site())]}
			], [
				{op: OCall3, args: [4, geti, 0, 6, 7]}
			]);
			time('hxs.geti', byNative, entry);
		}

		var byClosure:Bytecode = new Bytecode();
		{
			var i32:Int = byClosure.prim(HI32);
			var dyn:Int = byClosure.prim(HDyn);
			var fn:Int = byClosure.typeId(TFun([dyn], dyn));
			var slot:Int = byClosure.global(fn);

			var entry:Int = loop(byClosure, [dyn, i32, i32, i32, i32, dyn, fn, dyn], [], [
				{op: OGetGlobal, args: [6, slot]},
				{op: OCallClosure, args: [7, 6, 0]},
				{op: OSafeCast, args: [4, 7]}
			]);

			time('a closure', byClosure, entry, function(loaded:Loaded):Void {
				Loader.set(loaded, slot, fetch);
			});
		}
	}
}
