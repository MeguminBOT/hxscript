import hxscript.Environment;
import hxscript.Module;
import hxscript.error.Sink;
import hxscript.types.ScriptedClass;

/**
 * What a `safe` class's method throws goes to the sink before the class's hook.
 *
 * `safe` is the bridge catching the throw where it happened, and it only called `onInstanceError`,
 * which traced it, so a host listening to the sink never heard of it. Only a bridged base reaches
 * that catch, which is why this is a cpp test.
 */
class SafeHookTest {
	public static function run():Void {
		var wasPrinting:Bool = Sink.printing;
		Sink.printing = false;

		var env:Environment = new Environment();
		env.addModule(new Module('package hk;\nclass Told extends HostBase {\n\tpublic function new() { super(); }\n'
			+ '\toverride public function tell():Int { throw "told"; }\n}\n', 'Told', ['hk'], 'Told.hx'));
		env.start();

		var cls:ScriptedClass = cast env.resolve('hk.Told');
		cls.safe = true;

		var hooked:String = null;
		cls.onInstanceError = function(error:Dynamic, fun:String, ?instance):Void hooked = fun;

		var mark:Int = Sink.history.length;
		var instance:HostBase = cast cls.typeCreateInstance([]);
		var survived:Bool = try {
			instance.tell();
			true;
		} catch (e:Dynamic) false;

		var reported:Bool = false;
		for (d in Sink.history.slice(mark))
			if (d.message.indexOf('Told.tell') >= 0 && d.message.indexOf('told') >= 0)
				reported = true;

		TestCase.ok('a safe method that throws does not throw at its caller', survived);
		TestCase.ok('it is reported', reported);
		TestCase.ok('the class hook is still called', hooked == 'tell');

		Sink.printing = wasPrinting;
	}
}
