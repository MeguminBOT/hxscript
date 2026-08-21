package game;

import hxscript.Config;
import hxscript.Environment;
import hxscript.Module;
import hxscript.syntax.Expr.ImportMode;
import hxscript.types.ScriptedClass;
import hxscript.types.TypeCollection;
import game.Entity;
import sys.FileSystem;
import sys.io.File;

/**
 * The whole embedding layer: everything the host has to do to make scripts work. Five steps, and
 * `setup` runs them once.
 *
 * The fifth is optional, and is what a host adds when scripts get hot enough to notice: the same
 * scripts, compiled to bytecode at runtime instead of interpreted. Nothing above it changes, and
 * nothing below it can tell which way a class ended up running.
 *
 * See [docs/embedding.md](../../../docs/embedding.md) for what each one is doing and why.
 */
class Mods {
	/** The world every loaded script and type lives in. */
	public static var world:Environment;

	/** What the compiler did, for `Main` to print. Empty when this build cannot compile. */
	public static var compileReport:String = 'interpreted (built without -D hxscript_cppia)';

	/**
	 * Names scripts can use without importing them.
	 *
	 * Listed by hand here because the list is four entries and the example is meant to be read. A
	 * host with a real API surface marks its types `@:scriptAmbient` instead and calls
	 * `Expose.apply()`, which fills this in and the compiler's copy of it from the same marks.
	 */
	static final GLOBALS:Array<String> = ['game.Entity', 'game.Component', 'game.Battle', 'game.Damage'];

	/**
	 * Loads every script in a folder and starts them as one world.
	 *
	 * @param dir The folder to read `.hx` files from.
	 */
	public static function setup(dir:String):Void {
		// 0. Use our interpreter, so scripts can name the running battle's members directly.
		//    Set before any Module or Script is built: each one instantiates this class once, at
		//    construction, so changing it later leaves the already-built ones on the old one.
		Config.interpClass = ModInterp;

		// 1. Let scripts name the game's types without importing them. Anything else compiled into
		//    the program is still reachable with an explicit `import`.
		//    A global import that cannot resolve throws out of the Script constructor uncaught, so
		//    only register what is actually in this build.
		for (path in GLOBALS)
			if (TypeCollection.main.fromPath(path) != null)
				Config.globalImports.set(path, INormal);

		// 2. Keep scripts away from the file system.
		//    Note these are packaged names. Blacklisting a top-level type (`Sys`) also works, but the
		//    default root wildcard import tries to resolve it on every interpreter reset and logs a
		//    warning each time, so block those by module or package instead.
		var blocked:Array<String> = Config.blacklist.get(ByType);
		for (name in ['sys.io.File', 'sys.io.Process', 'sys.FileSystem'])
			blocked.push(name);

		// 3. Build the world out of every script in the folder.
		world = new Environment();

		for (file in FileSystem.readDirectory(dir)) {
			if (!StringTools.endsWith(file, '.hx'))
				continue;

			var path:String = '$dir/$file';
			var name:String = file.substr(0, file.length - 3);
			world.addModule(new Module(File.getContent(path), name, [], path));
		}

		// 4. Give scripts the handful of values they cannot reach through their own objects.
		world.variables.set('roll', function(sides:Int):Int return 1 + Std.random(sides));

		world.start();

		// 5. Optional: compile what can be compiled.
		//    Worth about 20x on a script's own work, and free to leave out, since a build without
		//    `-D hxscript_cppia` skips this entirely and everything is interpreted as before.
		compile();
	}

	/**
	 * Compiles the world's scripts to bytecode, where this build can.
	 *
	 * The whole of it is one call. `Compiler.compile` offers every module, loads what compiled,
	 * registers the classes against the world and turns substitution on, so the rest of this file, from
	 * `classes()` to `roster()` to everything in `Battle`, goes on asking the world for a class and
	 * getting whichever form exists, without knowing which.
	 *
	 * A module the emitter cannot take is reported and left interpreted, so turning this on cannot
	 * break a script that was working. All twelve of these compile, including `Combat.hx`, which
	 * declares an enum, a typedef and an abstract in one module.
	 */
	static function compile():Void {
		#if hxscript_cppia
		// The same names step 1 gave the interpreter, given to the compiler in the form it reads.
		// Compiled code has no interpreter to have them injected into, so a bare `Entity` means
		// nothing to it until it is told where `Entity` lives. Miss this and the module still
		// emits, and fails to load.
		hxscript.compile.Compiler.ambient = GLOBALS;

		// `round` and `log` are the battle's, reached through `ModInterp` rather than out of any table,
		// and a battle only exists once one starts. Nothing is bound to read a type off while this
		// compiles, so they are named here instead: `round` is an `Int` and reads as one, `log` is a
		// method and stays untyped, which is what a bare name with no type named for it gets anyway.
		// Without this line `Bandit` is the one script left interpreted.
		hxscript.compile.Compiler.globalNames = ['round:Int', 'log'];

		var report = hxscript.compile.Compiler.compile(world);

		var parts:Array<String> = [
			'compiled ${report.compiled.length} classes in ' + Math.round(report.ms * 10) / 10 + 'ms'
		];

		for (skip in report.skipped)
			parts.push('interpreting ${skip.name}: ${skip.reason}');

		if (!report.substituting)
			parts.push('nothing compiled; all interpreted');

		compileReport = parts.join('
  ');
		#end
	}

	/**
	 * Every script-declared class in the world, by name, in a stable order.
	 *
	 * @return The loaded scripted classes.
	 */
	public static function classes():Array<ScriptedClass> {
		var found:Map<String, ScriptedClass> = [];
		for (module in world.modules)
			for (name => type in module.types)
				if (type is ScriptedClass)
					found.set(name, cast type);

		var names:Array<String> = [for (name in found.keys()) name];
		names.sort(Reflect.compare);
		return [for (name in names) found.get(name)];
	}

	/**
	 * Whether a scripted class descends from a native one.
	 *
	 * @param cls The scripted class.
	 * @param base The native base to look for.
	 * @return True if `base` is somewhere up the chain.
	 */
	public static function descendsFrom(cls:ScriptedClass, base:Class<Dynamic>):Bool {
		var native:Dynamic = cls.instanceClass;
		while (native != null) {
			if (native == base)
				return true;
			native = Type.getSuperClass(native);
		}
		return false;
	}

	/**
	 * Builds one of every entity a script declared for the given side.
	 *
	 * The host never names a script here: it asks the world which classes are entities and which
	 * side they declared themselves on, so dropping a new file into the scripts folder puts a new
	 * creature in the fight without touching any of this.
	 *
	 * @param side The value a script's `static var side` has to match.
	 * @return The newly built entities.
	 */
	public static function roster(side:String):Array<Entity> {
		var out:Array<Entity> = [];

		for (cls in classes()) {
			if (!descendsFrom(cls, Entity) || cls.reflectGetField('side') != side)
				continue;

			var made:Dynamic = cls.typeCreateInstance([]);
			if (made is Entity)
				out.push(made);
		}

		return out;
	}
}
