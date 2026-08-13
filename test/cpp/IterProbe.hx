import hxscript.Environment;
import hxscript.Module;
import hxscript.compile.Compiler;

/**
 * Narrows what in a custom iterator ends the process once the JIT is on.
 *
 * `a custom iterator` is the last conformance case that behaves differently jitted, and it ends the
 * process rather than answering, so it has to be taken apart one construct at a time. Each variant
 * changes exactly one thing against the first.
 *
 * A crash takes the process with it, so a variant is named on stderr before it runs and each is run
 * in its own process:
 *
 * ```
 * for i in 0 1 2 3 4 5; do ./IterProbe.exe $i; done
 * ```
 *
 * Compiled through the world, because that is the path that turns the JIT on: compiling a module
 * directly and loading it never starts one, which is a trap this probe exists to avoid.
 */
class IterProbe {
	static var VARIANTS:Array<{name:String, members:String, body:String}> = [
		{
			name: 'the case as written',
			members: 'var at:Int = 0; var max:Int; public function new(max:Int) { this.max = max; } '
			+ 'public function hasNext():Bool return at < max; public function next():Int return at++;',
			body: 'var n = 0; for (v in new C(3)) n += v; return Std.string(n);'
		},
		{
			name: 'hasNext with no declared return',
			members: 'var at:Int = 0; var max:Int; public function new(max:Int) { this.max = max; } '
			+ 'public function hasNext() return at < max; public function next():Int return at++;',
			body: 'var n = 0; for (v in new C(3)) n += v; return Std.string(n);'
		},
		{
			name: 'next without the increment expression',
			members: 'var at:Int = 0; var max:Int; public function new(max:Int) { this.max = max; } '
			+ 'public function hasNext():Bool return at < max; '
			+ 'public function next():Int { var r = at; at = at + 1; return r; }',
			body: 'var n = 0; for (v in new C(3)) n += v; return Std.string(n);'
		},
		{
			name: 'driven by a while loop rather than for',
			members: 'var at:Int = 0; var max:Int; public function new(max:Int) { this.max = max; } '
			+ 'public function hasNext():Bool return at < max; public function next():Int return at++;',
			body: 'var n = 0; var it = new C(3); while (it.hasNext()) n += it.next(); return Std.string(n);'
		},
		{
			name: 'hasNext calling nothing, a plain field read',
			members: 'var at:Int = 0; var more:Bool = true; public function new(max:Int) {} '
			+ 'public function hasNext():Bool return more; public function next():Int { more = false; return 3; }',
			body: 'var n = 0; for (v in new C(3)) n += v; return Std.string(n);'
		},
		{
			name: 'the increment expression on its own, no iterator',
			members: 'var at:Int = 0; public function new(max:Int) {} public function bump():Int return at++;',
			body: 'var c = new C(0); var n = c.bump() + c.bump(); return Std.string(n);'
		},
		{
			name: 'the same increment written this.at++',
			members: 'var at:Int = 0; public function new(max:Int) {} public function bump():Int return this.at++;',
			body: 'var c = new C(0); var n = c.bump() + c.bump(); return Std.string(n);'
		},
		{
			name: 'a static field incremented',
			members: 'static var at:Int = 0; public function new(max:Int) {} public function bump():Int return at++;',
			body: 'var c = new C(0); var n = c.bump() + c.bump(); return Std.string(n);'
		},
		{
			name: 'a local incremented, the control',
			members: 'public function new(max:Int) {}',
			body: 'var at = 0; var n = at++ + at++; return Std.string(n);'
		},
		{
			name: 'pre-increment on a field',
			members: 'var at:Int = 0; public function new(max:Int) {} public function bump():Int return ++at;',
			body: 'var c = new C(0); var n = c.bump() + c.bump(); return Std.string(n);'
		}
	];

	static function main():Void {
		var args:Array<String> = Sys.args();
		var only:Int = args.length > 0 ? Std.parseInt(args[0]) : 0;

		if (only < 0 || only >= VARIANTS.length) {
			Sys.println('no variant ' + only);
			return;
		}

		var v = VARIANTS[only];
		Sys.println('--- ' + only + ': ' + v.name);
		Sys.stdout().flush();

		var source:String = 'package v' + only + ';\nclass C {\n' + v.members + '\n}\n'
			+ 'class T {\npublic static function run():Dynamic { ' + v.body + ' }\n}\n';

		try {
			var env:Environment = new Environment();
			var module:Module = new Module('', 'T', ['v' + only], 'iterprobe');
			module.parse(source);
			env.addModule(module);
			module.init(env);
			module.start(env);
			module.startTypes(env);

			Compiler.compile(env, [module]);

			var native:Null<Class<Dynamic>> = env.compiled.get('v' + only + '.T');
			if (native == null) {
				Sys.println('    not substituted, so it stayed interpreted');
				return;
			}

			Sys.println('    -> ' + Std.string(Reflect.callMethod(null, Reflect.field(native, 'run'), [])));
		} catch (e:Dynamic) {
			Sys.println('    threw ' + e);
		}
	}
}
