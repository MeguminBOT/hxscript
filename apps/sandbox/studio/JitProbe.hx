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
	 * Loads a project and offers a batch of its modules to the compiler.
	 *
	 * @param name The project folder's name.
	 * @param only Comma-separated module names to keep, or null for all of them.
	 */
	public static function run(name:String, only:String):Void {
		Sink.listen(function(d:Diagnostic):Void say('  ' + d.toString().split('\n').join('\n  ')));

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

		Sys.exit(0);
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
