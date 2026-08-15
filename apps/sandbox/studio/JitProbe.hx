package studio;

import host.Sandbox;
import hxscript.Module;
import hxscript.error.Diagnostic;
import hxscript.error.Sink;

/**
 * Loads and compiles a project with no window, for finding out what the runtime compiler does to it.
 *
 * Named apart from `host.Probe`, which answers a different question: that one is script-facing and
 * says whether a type is reachable, this one is a debugging entry point for the compiler.
 *
 * `--probe <project>` exists because the interesting failure is not one a window helps with. The
 * hxcpp JIT can fault while compiling, and a fault there is a segmentation fault rather than
 * something Haxe can catch, so the process ends and whatever was printed last is the only evidence.
 * Printing the batch before offering it, and flushing, turns that into a bisection.
 *
 * `--only <a,b,c>` narrows the batch to named modules, which is how a batch that faults gets cut
 * down to the smallest one that still does. `--nojit` compiles the same batch with the JIT off, to
 * separate a fault in the bytecode from a fault in the machine code made out of it.
 */
class JitProbe {
	/**
	 * Loads a project and offers a batch of its modules to the compiler, once or several times.
	 *
	 * `--probe sonic2,sonic2` loads and compiles it twice in one process, which is what a host does
	 * every time it switches project or reloads one from disk. The second pass is where a compiler
	 * that remembers the first one shows it: the classes it already built are bound into a world that
	 * has just re-read every file, and everything referencing them is refused against them, so the
	 * second report compiles less than the first. Reading the two reports beside each other is the
	 * whole test, and it needs no window.
	 *
	 * @param name The project, or several separated by commas.
	 * @param only Module names to compile, or null for all of them.
	 */
	public static function run(name:String, only:String):Void {
		Sink.listen(function(d:Diagnostic):Void say('  ' + d.toString().split('\n').join('\n  ')));

		var names:Array<String> = name.split(',');

		for (i => one in names) {
			if (names.length > 1)
				say('--- pass ${i + 1} of ${names.length} ---');

			once(one, only);
		}

		/**
		 * Here rather than at the end of a pass, which is where it used to be: a probe that exits
		 * inside the cycle can only ever run one, and the second cycle is the whole point of asking
		 * for two.
		 */
		Sys.exit(0);
	}

	/** One load-and-compile cycle, reported on its own. */
	static function once(name:String, only:String):Void {
		var project:ProjectInfo = null;
		for (candidate in Projects.all())
			if (candidate.name == name)
				project = candidate;

		if (project == null) {
			say('no project named "$name" in ' + Projects.root);
			Sys.exit(2);
		}

		say('project   ${project.name}, ${project.scripts.length} script(s)');

		Sandbox.load(project);

		var modules:Array<Module> = [];
		var wanted:Array<String> = only == null ? null : only.split(',');

		for (module in Sandbox.world.modules)
			if (wanted == null || wanted.indexOf(module.name) >= 0)
				modules.push(module);

		var interpreted:Bool = Sys.args().indexOf('--interp') >= 0;

		#if hxscript_cppia
		/**
		 * `--echo Class.method` prints the instructions emitted for one method. A fault in bytecode
		 * leaves nothing behind, so once a batch has been narrowed to the module carrying it, reading
		 * what was written for it is the only way left to see what is wrong with it.
		 */
		hxscript.cppia.Backend.echoTarget = argument('--echo');

		if (!interpreted) {
			var jit:Bool = Sys.args().indexOf('--nojit') < 0;
			hxscript.compile.Compiler.jit = jit;

			say('batch     ${modules.length} module(s), jit ' + (jit ? 'on' : 'off'));
			say('          ' + [for (m in modules) m.name].join(' '));
			say('compiling ...');

			var report = hxscript.compile.Compiler.compile(Sandbox.world, modules);

			say('SURVIVED  compiled ${report.compiled.length}, skipped ${report.skipped.length}, '
				+ 'failed ${report.failed.length}, ${report.bytes} bytes, '
				+ Math.round(report.ms * 10) / 10 + 'ms');

			if (hxscript.cppia.Backend.echoTarget != null) {
				say('--- ' + hxscript.cppia.Backend.echoTarget + ' ---');
				say(hxscript.cppia.Backend.echoed == null ? '(nothing emitted for it)' : hxscript.cppia.Backend.echoed);
			}

			for (skip in report.skipped)
				say('  skipped ' + skip);
			for (fault in report.failed)
				say('  refused ${fault.name}: ${fault.reason}');
		} else {
			say('batch     not compiled, interpreting');
		}
		#else
		say('this build has no runtime compiler (-D hxscript_cppia)');
		#end

		var call:String = argument('--call');
		if (call != null)
			invoke(call);

		var made:String = argument('--make');
		if (made != null)
			construct(made);
	}

	/**
	 * Constructs a scripted class, which is what a project's entry gets before anything renders.
	 *
	 * `--call` only reaches a static, and a project usually starts by being built rather than called:
	 * a flixel state is constructed and handed to `switchState`. So a fault while constructing one is
	 * reachable with no window, and that is the half worth reaching, because a fault in emitted
	 * bytecode ends the process rather than reporting anything.
	 *
	 * @param name The class, by its short name or its path.
	 */
	static function construct(name:String):Void {
		var cls:hxscript.types.ScriptedClass = null;

		for (candidate in Sandbox.classes())
			if (candidate.name == name || candidate.path == name)
				cls = candidate;

		if (cls == null) {
			say('no class named $name');
			return;
		}

		say('--- constructing $name ---');

		var made:Dynamic = Sandbox.make(cls);

		say(made == null ? '--- $name did not construct ---' : '--- $name constructed ---');

		if (made == null)
			return;

		/**
		 * Then the two a frame loop would call. Constructing a state proved clean while running the
		 * project did not, so what is left is what flixel does next, and reaching it here rather than
		 * through a window is what makes the fault bisectable.
		 */
		var ticks:Int = Std.parseInt(argument('--tick') == null ? '0' : argument('--tick'));

		if (ticks <= 0)
			return;

		step(made, 'create', []);

		for (i in 0...ticks)
			step(made, 'update', [0.016]);

		say('--- ticked $ticks time(s) ---');
	}

	/**
	 * Calls one method on a scripted instance, saying so before it runs.
	 *
	 * Said before rather than after on purpose: a fault in emitted bytecode ends the process, so the
	 * last line printed is the only evidence of where it was.
	 *
	 * @param on The instance.
	 * @param name The method.
	 * @param args What to pass.
	 */
	static function step(on:Dynamic, name:String, args:Array<Dynamic>):Void {
		var fn:Dynamic = Reflect.field(on, name);

		if (!Reflect.isFunction(fn)) {
			say('  (no $name)');
			return;
		}

		say('  calling $name ...');

		try {
			Reflect.callMethod(on, fn, args);
		} catch (e:Dynamic) {
			say('  $name THREW ' + Std.string(e));
		}
	}

	/**
	 * Calls a static method on a scripted class, so the same source can be run in each mode.
	 *
	 * The interpreter's own counters are reset around the call and reported after it. That is the
	 * witness that a run labelled compiled really was: compiled code does not pass through them, so a
	 * mode claiming to be compiled while the counters climb is measuring nothing.
	 *
	 * @param target `Class.method`, the class being the module's short name.
	 */
	static function invoke(target:String):Void {
		var dot:Int = target.lastIndexOf('.');
		if (dot < 0) {
			say('--call wants Class.method');
			return;
		}

		var owner:String = target.substr(0, dot);
		var member:String = target.substr(dot + 1);
		var cls:hxscript.types.ScriptedClass = null;

		for (candidate in Sandbox.classes())
			if (candidate.name == owner || candidate.path == owner)
				cls = candidate;

		if (cls == null) {
			say('no class named $owner');
			return;
		}

		hxscript.debug.Metrics.on = true;
		hxscript.debug.Metrics.reset();

		say('--- $target ---');

		try {
			var fn:Dynamic = cls.reflectGetField(member);

			if (!Reflect.isFunction(fn))
				say('$owner.$member is not callable');
			else
				Reflect.callMethod(null, fn, []);
		} catch (e:Dynamic) {
			say('THREW ' + Std.string(e));
		}

		say('--- interpreter did ${hxscript.debug.Metrics.calls} call(s), '
			+ '${hxscript.debug.Metrics.reads} read(s) ---');
	}

	/**
	 * Reads a `--name value` argument.
	 *
	 * @param name The flag.
	 * @return Its value, or null.
	 */
	static function argument(name:String):String {
		var args:Array<String> = Sys.args();

		for (i in 0...args.length)
			if (args[i] == name && i + 1 < args.length)
				return args[i + 1];

		return null;
	}

	/**
	 * Prints a line and flushes it, so the last thing printed before a crash is the truth.
	 *
	 * @param text What to print.
	 */
	static function say(text:String):Void {
		Sys.stdout().writeString(text + '\n');
		Sys.stdout().flush();
	}
}
