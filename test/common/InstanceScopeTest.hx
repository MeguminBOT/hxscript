import hxscript.Environment;
import hxscript.Module;
import hxscript.types.IScriptedInstance;
import hxscript.types.ScriptedClass;
import TestCase;

/**
 * What an instance sees of the names its class holds, and what happens when it writes one.
 *
 * **An instance stands on its class's table rather than carrying a copy of it.** Copying made a
 * host's script API cost something per object spawned, growing with the API: 5.7us to construct at
 * eight bound values and 12.9us at fifty-eight. Standing on it is flat.
 *
 * What that has to preserve is the whole of this file. A read falls through to the class, a write
 * never does, so an instance assigning to one of these names gets an entry of its own from that
 * moment and its siblings and its class are left as they were. That is exactly what the copy gave
 * it, and the only reason the change is safe.
 */
class InstanceScopeTest {
	static var SRC:String = 'class Counter {
	public function new() {}

	public function read():Int {
		return shared;
	}

	public function bump():Int {
		shared = shared + 1;
		return shared;
	}
}
';

	public static function run():Void {
		TestCase.section('an instance reads its class\'s names');

		var env:Environment = world();
		var cls:ScriptedClass = cast env.resolve('Counter');

		var a:Dynamic = cls.typeCreateInstance([]);
		var b:Dynamic = cls.typeCreateInstance([]);

		TestCase.eq('a fresh instance reads a host-bound name', call(a, 'read'), 10);
		TestCase.eq('so does a second one', call(b, 'read'), 10);

		TestCase.section('writing one gives that instance its own');

		TestCase.eq('the writer sees its own value', call(a, 'bump'), 11);
		TestCase.eq('and keeps seeing it', call(a, 'read'), 11);
		TestCase.eq('a sibling is untouched', call(b, 'read'), 10);
		TestCase.eq('and the class is untouched', module(env).variables.get('shared'), 10);

		TestCase.eq('the sibling writes its own too', call(b, 'bump'), 11);
		TestCase.eq('which does not disturb the first', call(a, 'read'), 11);

		TestCase.section('the fallback is live until an instance writes');

		var later:Environment = world();
		var lateCls:ScriptedClass = cast later.resolve('Counter');
		var untouched:Dynamic = lateCls.typeCreateInstance([]);
		var written:Dynamic = lateCls.typeCreateInstance([]);

		call(written, 'bump');

		/**
		 * The class's own table, not the module's. A class copies the module's names when it is built
		 * and has had its own ever since, which is older than any of this and is why the module is not
		 * what an instance falls back to.
		 */
		@:privateAccess lateCls.interp.variables.set('shared', 40);

		TestCase.eq('an instance that never wrote follows the class', call(untouched, 'read'), 40);
		TestCase.eq('one that did keeps its own', call(written, 'read'), 11);

		TestCase.section('a module write does not reach a class, as it never did');

		module(later).variables.set('shared', 70);

		TestCase.eq('the class keeps what it was given', call(untouched, 'read'), 40);
	}

	/** @return A world binding one value, with the counter module in it. */
	static function world():Environment {
		var env:Environment = new Environment();
		env.variables.set('shared', 10);
		env.addModule(new Module(SRC, 'Counter', []));
		env.start();
		return env;
	}

	/** @return The world's only module. */
	static function module(env:Environment):Module {
		for (m in env.modules)
			return m;

		return null;
	}

	/**
	 * Calls a method on a scripted instance.
	 *
	 * Through its own slots, because a class with no host base behind it is a `ScriptedObject` and its
	 * methods are not native fields for reflection to find. This is the same route the interpreter
	 * takes to one.
	 *
	 * @param instance A scripted instance.
	 * @param name The method to call.
	 * @return What it answered.
	 */
	static function call(instance:Dynamic, name:String):Dynamic {
		var slots:Map<String, hxscript.runtime.Variable> = @:privateAccess (cast instance : IScriptedInstance).__vars;
		return Reflect.callMethod(instance, slots.get(name).r, []);
	}
}
