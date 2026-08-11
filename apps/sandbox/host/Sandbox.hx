package host;

import hxscript.Environment;
import hxscript.Module;
import hxscript.types.ScriptedClass;
import studio.ProjectInfo;
import sys.FileSystem;
import sys.io.File;

/**
 * Loads one project's scripts into a world of their own.
 *
 * This file used to open with four setup steps in a fixed order, registering the global imports, applying
 * the expose macro, installing a blacklist and registering the shims, followed by a paragraph about why the
 * order mattered. All of it now happens in `hxscript.setup.Boot`, triggered by the first `Environment`.
 *
 * What is left is the part that was always the host's own: read the files, build the world, compile
 * it where the build can, and answer questions about what came out.
 *
 * **One project, one world.** Every project gets a fresh `Environment`, so two projects cannot see
 * each other's types and reloading one cannot leave anything of the last one behind. That also
 * makes the reload story simple: throw the world away and build another.
 */
class Sandbox {
	/** The world the loaded project lives in, replaced on every load. */
	public static var world:Environment;

	/** The project currently loaded, or null. */
	public static var current:ProjectInfo;

	/** What the runtime compiler did, for the status bar. */
	public static var compiled:String = 'interpreted';

	/** How many classes have a compiled form, so a readout can say so as a number. */
	public static var classCount(default, null):Int = 0;

	/**
	 * Whether the loaded world has been through the compiler.
	 *
	 * What tells a caller that a world read on selection still needs compiling before it is run. Not
	 * the same question as whether anything came out compiled: a world the emitter refused entirely has
	 * been offered and there is no point offering it again.
	 */
	public static var compiledWorld(default, null):Bool = false;

	/**
	 * How many bytes of bytecode the compiler produced.
	 *
	 * The one measurement of compiled code that can actually be taken. cppia's runtime surface is
	 * `fromData`, `boot`, `run` and `resolveClass` and nothing else, so there are no counters inside it to
	 * read. What compiled code costs per call cannot be asked, only what it weighed on the way in.
	 */
	public static var bytecode(default, null):Int = 0;

	/**
	 * How many of the last load's types failed to build.
	 *
	 * A project whose scripts all fail to parse reports nothing, and a project of one such class and one
	 * good one looks exactly like a project with nothing runnable in it. The difference matters, because one
	 * is a broken project and the other is a build without the library in it, so it is recorded where it
	 * happens.
	 */
	public static var typeErrors(default, null):Int = 0;

	/** Modification times at load, so `stale` can tell whether anything changed. */
	static var times:Map<String, Float> = [];

	/** The last answer `classes()` gave, dropped whenever a world is built. */
	static var listed:Array<ScriptedClass> = null;

	/**
	 * Reads a project's scripts into a fresh world and starts them.
	 *
	 * Errors are not returned. Everything a script can get wrong reaches
	 * `hxscript.error.Sink` with its position, source line and cause, and the shell is listening,
	 * so a caller that wanted to know "did it work" asks `world` for the types it expected rather
	 * than reading a status back from here. Building the world is wrapped for the same reason: a
	 * static initializer that throws would otherwise leave through openfl and end the process with
	 * nothing printed.
	 *
	 * @param project The project to load.
	 * @param compileNow Whether to run the runtime compiler as well. Off by default, because reading a
	 *        project is what selecting one does and compiling is what running one does: emitting
	 *        bytecode for every project somebody clicks past is work nobody asked for, and it is the
	 *        slowest thing here by an order of magnitude.
	 * @return Whether any module loaded.
	 */
	public static function load(project:ProjectInfo, compileNow:Bool = false):Bool {
		current = project;
		times = [];
		compiled = 'not compiled';
		compiledWorld = false;
		typeErrors = 0;

		Api.projectPath = project.path;
		Api.project = project.name;

		var count = function(d:hxscript.error.Diagnostic):Void {
			if (d.phase == PType)
				typeErrors++;
		};

		hxscript.error.Sink.onDiagnostic.push(count);

		world = new Environment();
		listed = null;

		var scriptsRoot:String = '${project.path}/scripts';

		for (file in project.scripts) {
			var relative:String = file.substr(scriptsRoot.length + 1);
			var parts:Array<String> = relative.split('/');
			var name:String = parts.pop().substr(0, -3);

			times.set(file, FileSystem.stat(file).mtime.getTime());

			world.addModule(new Module(File.getContent(file), name, parts, file));
		}

		try {
			world.start();
		} catch (e:Dynamic) {
			if (Std.isOfType(e, haxe.Exception))
				hxscript.error.Sink.caught(cast e, PType, 'starting ${project.name}');
			else
				hxscript.error.Sink.note(PType, 'starting ${project.name}: ' + Std.string(e));

			typeErrors++;
		}

		if (compileNow)
			compile();

		guard();

		hxscript.error.Sink.onDiagnostic.remove(count);

		return project.scripts.length > 0;
	}

	/**
	 * Makes every scripted class report its errors instead of throwing them.
	 *
	 * Errors are reported rather than thrown, because a script failure is a normal outcome here and must not
	 * take the app with it. An `update` that throws goes straight past the launcher, out through openfl, and
	 * ends the process with no message at all, because a windowed build has nowhere to print one.
	 *
	 * `safe` moves that boundary inside the scripted class: an instance method that throws is caught
	 * where it happened, reported with its position, and the frame carries on. A project that is
	 * broken then looks broken rather than looking like a crash.
	 */
	static function guard():Void {
		for (cls in classes()) {
			cls.safe = true;

			cls.onInstanceError = function(error:Dynamic, fun:String, ?instance):Void {
				report(error, '${cls.name}.$fun');
			};

			cls.onExpressionError = function(error:Dynamic, field:String, ?expr):Void {
				report(error, '${cls.name}.$field');
			};
		}
	}

	/**
	 * Reports something a scripted class threw.
	 *
	 * `Dynamic` rather than an exception, because a script may `throw` any value at all, and the one
	 * that reaches here is whatever it chose.
	 *
	 * @param error What was thrown.
	 * @param where Which method it came out of.
	 */
	static function report(error:Dynamic, where:String):Void {
		if (Std.isOfType(error, haxe.Exception))
			hxscript.error.Sink.caught(cast error, PRun, where);
		else
			hxscript.error.Sink.note(PRun, '$where: ' + Std.string(error));
	}

	/** Drops the loaded world, so nothing of it survives into the next project. */
	public static function unload():Void {
		world = null;
		current = null;
		listed = null;
		times = [];
	}

	/**
	 * Compiles the world to bytecode where this build can.
	 *
	 * Both paths produce the same class, so nothing downstream needs to know which one it got. A
	 * module the emitter refuses is reported and left interpreted, and a module the loader refuses
	 * no longer takes the application with it.
	 *
	 * Deferred to whoever is about to run something, and idempotent, so the caller can ask without
	 * knowing whether an earlier one already did. Safe to leave until then because a world sitting in
	 * the list has run nothing: substituting a compiled class for a scripted one is only hazardous once
	 * something holds an instance or has written to a static, and between being read and being run,
	 * nothing has.
	 */
	public static function compile():Void {
		if (world == null || compiledWorld)
			return;

		compiledWorld = true;
		bytecode = 0;
		classCount = 0;

		#if hxscript_cppia
		if (!studio.Settings.compiling()) {
			compiled = 'interpreted (by choice)';
			guard();
			return;
		}

		var report = hxscript.compile.Compiler.compile(world);
		var parts:Array<String> = ['compiled ${report.compiled.length} class(es) in ' + Math.round(report.ms * 10) / 10 + 'ms'];

		classCount = report.compiled.length;
		bytecode = report.bytes;

		for (skip in report.skipped)
			parts.push('interpreting ' + skip);

		for (fault in report.failed)
			parts.push('the loader refused ' + fault);

		if (!report.substituting)
			parts.push('all interpreted');

		compiled = parts.join('; ');
		guard();
		#else
		compiled = 'interpreted (built without -D hxscript_cppia)';
		#end
	}

	/**
	 * Whether any of the loaded project's files changed since it was read.
	 *
	 * Compares against the paths recorded at load and against the folder as it is now, so a file added or
	 * removed counts as a change too, which is what somebody creating a new script in their editor is doing.
	 *
	 * It walks the folder rather than re-reading the project: the manifest has nothing to do with
	 * whether a script changed, and this runs several times a second for as long as the application is
	 * open, so parsing a JSON file to answer it was work with no bearing on the answer.
	 *
	 * @return Whether a `load` would produce something different.
	 */
	public static function stale():Bool {
		if (current == null)
			return false;

		var fresh:Array<String> = [];
		studio.Projects.scripts(current.path, fresh);

		if (fresh.length != current.scripts.length)
			return true;

		for (file in fresh) {
			if (!times.exists(file))
				return true;

			try {
				if (times.get(file) != FileSystem.stat(file).mtime.getTime())
					return true;
			} catch (e:haxe.Exception) {
				return true;
			}
		}

		return false;
	}

	/**
	 * Every scripted class in the world, sorted by name.
	 *
	 * Cached, because the answer only changes when a world is built. It is asked far more often than
	 * that: resolving what a project runs reaches it six times, describing a project once more, and
	 * the readout window four times a second. Rebuilding a map, an array and a sort each time was the
	 * shape of the cost, not its size.
	 *
	 * @return The classes, in name order.
	 */
	public static function classes():Array<ScriptedClass> {
		if (listed != null)
			return listed;

		if (world == null)
			return [];

		var found:Map<String, ScriptedClass> = [];

		for (module in world.modules)
			for (name => type in module.types)
				if (type is ScriptedClass)
					found.set(name, cast type);

		var names:Array<String> = [for (n in found.keys()) n];
		names.sort(Reflect.compare);
		return listed = [for (n in names) found.get(n)];
	}

	/**
	 * Every scripted class descending from a native one.
	 *
	 * The host never names a project's classes. Asking the world what it has is what makes dropping
	 * a folder into `projects/` the whole installation step.
	 *
	 * @param base The native base to look for.
	 * @return The matching classes, sorted by name.
	 */
	public static function extending(base:Class<Dynamic>):Array<ScriptedClass> {
		return [
			for (cls in classes())
				if (descendsFrom(cls, base)) cls
		];
	}

	/**
	 * Whether a scripted class descends from a native one.
	 *
	 * @param cls The scripted class.
	 * @param base The native base to look for.
	 * @return Whether `base` is somewhere up the chain.
	 */
	public static function descendsFrom(cls:ScriptedClass, base:Class<Dynamic>):Bool {
		var native:Dynamic = null;

		try {
			native = cls.instanceClass;
		} catch (e:haxe.Exception) {
			return false;
		}

		while (native != null) {
			if (native == base)
				return true;

			native = Type.getSuperClass(native);
		}

		return false;
	}

	/**
	 * Instantiates a scripted class, reporting rather than throwing.
	 *
	 * A missing bridge fails here rather than at the declaration, and unhelpfully: the module's
	 * error already said `Class <base> can't be extended for scripting`, but the type stayed in the
	 * table, so construction throws `Type <name> is not initialized`, which does not mention the
	 * base. Watch the load errors, not this one.
	 *
	 * @param cls The class to build.
	 * @param args Constructor arguments.
	 * @return The instance, or null.
	 */
	public static function make(cls:ScriptedClass, ?args:Array<Dynamic>):Dynamic {
		try {
			return cls.typeCreateInstance(args == null ? [] : args);
		} catch (e:haxe.Exception) {
			hxscript.error.Sink.caught(e, PRun, 'constructing ${cls.name}');
			return null;
		}
	}
}
