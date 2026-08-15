import host.Sandbox;
import hxscript.error.Diagnostic;
import hxscript.error.Sink;
import hxscript.setup.Boot;
import hxscript.types.ScriptedClass;
import studio.EntryKind;
import studio.EntryKindTools;
import studio.ProjectInfo;
import studio.Projects;

/**
 * The sandbox with no window: what this build wired, and whether the projects load.
 *
 * The graphical app answers "does my project work". This answers the question underneath it, which is the
 * one that actually goes wrong: **is the build right**. All four setup steps fail by succeeding, in that the
 * build goes green, the app starts, and a project finds a null field weeks later. So a check that runs in a
 * second and needs no window is worth having beside the one that needs a window and a person looking at it.
 *
 * ```
 * haxe check.hxml
 * haxe check.hxml --run Check --projects ../some/other/folder
 * haxe check.hxml -lib heaps
 * ```
 *
 * Resolved by name rather than by type, because naming `h2d.Object` here would require heaps to be in
 * the build, and the whole point of this program is to run without it. Walking the super-class chain as
 * strings gives the same answer for every project and costs only that it cannot construct anything, which it
 * was never going to do anyway.
 */
class Check {
	/** The native bases a project can extend, and what each means, longest chain first. */
	static var BASES:Array<{path:String, kind:EntryKind}> = [
		{path: 'h2d.Scene', kind: KScene},
		{path: 'h2d.Object', kind: KObject},
		{path: 'host.Project', kind: KProject}
	];

	static function main():Void {
		Sink.listen(function(d:Diagnostic):Void Sys.println(indent(d.toString())));

		Sys.println(Boot.report());
		Sys.println('');
		Sys.println('shipped   ${Sandbox.shipping}');
		Sys.println('compiler  ${Sandbox.compiler}');
		Sys.println('');

		if (!Projects.open(argument('--projects'))) {
			Sys.println('no projects folder at ' + Projects.root);
			Sys.exit(1);
		}

		Sys.println('projects  ' + Projects.root);

		var projects:Array<ProjectInfo> = Projects.all();

		if (projects.length == 0) {
			Sys.println('          (none yet; the app writes its templates out on first run)');
			return;
		}

		var bad:Int = 0;

		for (project in projects) {
			Sys.println('');
			Sys.println('-- ${project.name} --');

			if (project.problem != null) {
				Sys.println('  ! ${project.problem}');
				bad++;
				continue;
			}

			Sandbox.load(project);
			Sys.println('  ${project.scripts.length} script(s), ' + Sandbox.compiled);

			unresolved = 0;
			var entry:String = describe(project);

			if (entry == null)
				unresolved += Sandbox.typeErrors;

			if (entry != null) {
				Sys.println('  entry ' + entry);
			} else if (unresolved > 0) {
				Sys.println('  - extends a base this build does not carry; add the libraries to check it');
			} else {
				Sys.println('  ! nothing runnable: no class extends FlxState, Sprite or Project, and none declares a static main()');
				bad++;
			}
		}

		Sys.println('');
		Sys.println(bad == 0 ? '${projects.length} project(s), nothing wrong' : '$bad of ${projects.length} project(s) cannot run');

		if (bad > 0)
			Sys.exit(1);
	}

	/** Classes in the project just checked whose native base this build does not have. */
	static var unresolved:Int = 0;

	/**
	 * What the launcher would run for a project, as a line of text.
	 *
	 * @param project The loaded project.
	 * @return The description, or null when nothing is runnable.
	 */
	static function describe(project:ProjectInfo):String {
		for (cls in Sandbox.classes()) {
			if (project.entry != null && cls.name != project.entry && cls.path != project.entry)
				continue;

			var kind:EntryKind = shapeOf(cls);

			if (kind != null)
				return '${cls.name}  (' + EntryKindTools.describe(kind) + ')';
		}

		return null;
	}

	/**
	 * Which shape a scripted class is, by walking its native super-classes as names.
	 *
	 * @param cls The scripted class.
	 * @return The shape, or null when it is none of them.
	 */
	static function shapeOf(cls:ScriptedClass):EntryKind {
		var native:Dynamic = null;

		try {
			native = cls.instanceClass;
		} catch (e:haxe.Exception) {
			unresolved++;
			return null;
		}

		while (native != null) {
			var name:String = Type.getClassName(native);

			for (base in BASES)
				if (base.path == name)
					return base.kind;

			native = Type.getSuperClass(native);
		}

		try {
			if (Reflect.isFunction(cls.reflectGetField('main')))
				return KMain;
		} catch (e:haxe.Exception) {}

		return null;
	}

	/**
	 * @param text A diagnostic, possibly several lines.
	 * @return It, indented, so it reads as belonging to the project above it.
	 */
	static function indent(text:String):String {
		return '  ' + text.split('\n').join('\n  ');
	}

	/**
	 * Reads a `--name value` command-line argument.
	 *
	 * @param name The flag, including its dashes.
	 * @return The value after it, or null when the flag is absent.
	 */
	static function argument(name:String):String {
		var args:Array<String> = Sys.args();

		for (i in 0...args.length)
			if (args[i] == name && i + 1 < args.length)
				return args[i + 1];

		return null;
	}
}
