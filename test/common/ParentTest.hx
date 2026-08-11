import hxscript.Script;
import TestCase.eq;
import TestCase.gap;
import TestCase.ok;

private class Host {
	public var hp:Int = 10;
	public var name:String = 'host';

	public var doubled(get, never):Int;

	function get_doubled():Int {
		return hp * 2;
	}

	public var clamped(default, set):Int = 0;

	function set_clamped(v:Int):Int {
		clamped = v > 100 ? 100 : v;
		return clamped;
	}

	public function new() {}

	public function greet():String {
		return 'hello from ' + name;
	}
}

/**
 * `Interp.parent`: a script bound to an object reads and writes that object's fields by bare name.
 *
 * Precedence is the part worth pinning down, because getting it wrong is silent. A local that shares
 * a name with a host field has to win, or a script quietly writes to the host instead of to itself.
 *
 * The three `gap` cases are the limits of what the feature reaches, not failures. `parent` is indexed
 * from `Type.getInstanceFields`, which lists a property's accessors rather than the property, so a
 * `(get, never)` field is not there to be found; and a name that resolves to a method is not reached
 * at all, whether it is called or taken as a value.
 */
class ParentTest {
	static function on(body:String):Host {
		var host:Host = new Host();
		var script:Script = new Script(body, 'parent');

		script.interp.parent = host;
		script.start();

		return host;
	}

	static function result(body:String):String {
		var host:Host = new Host();
		var script:Script = new Script(body, 'parent');

		script.interp.parent = host;
		script.onProgramError = function(e:haxe.Exception):Void {};
		script.start();

		return Std.string(script.variables.get('res'));
	}

	public static function run():Void {
		eq('reads a parent field', result('res = hp;'), '10');
		eq('reads another', result('res = name;'), 'host');
		eq('reads in an expression', result('res = hp * 2 + 1;'), '21');

		eq('writes a parent field', on('hp = 42;').hp, 42);
		eq('compound-assigns one', on('hp -= 4;').hp, 6);
		eq('increments one', on('hp++;').hp, 11);

		eq('writes through a setter', on('clamped = 500;').clamped, 100);
		eq('setter sees an ordinary value', on('clamped = 7;').clamped, 7);

		eq('a local shadows a parent field', result('var hp = 1; hp = 99; res = hp;'), '99');
		eq('and the parent keeps its value', Std.string(on('var hp = 1; hp = 99;').hp), '10');
		eq('a null local still shadows', result('var name = null; res = name;'), 'null');

		var rebound:Script = new Script('res = hp;', 'rebind');
		var second:Host = new Host();
		second.hp = 77;

		rebound.interp.parent = new Host();
		rebound.interp.parent = second;
		rebound.start();
		eq('rebinding sees the new parent', Std.string(rebound.variables.get('res')), '77');

		var anon:Script = new Script('res = a + b;', 'anon');
		anon.interp.parent = {a: 2, b: 3};
		anon.start();
		eq('an anonymous parent reads', Std.string(anon.variables.get('res')), '5');

		var written:Dynamic = {a: 1};
		var writing:Script = new Script('a = 9;', 'anonwrite');
		writing.interp.parent = written;
		writing.start();
		eq('an anonymous parent writes', Std.string(Reflect.field(written, 'a')), '9');

		var bare:Script = new Script('res = nothingNamedThis;', 'bare');
		var threw:Bool = false;
		bare.onProgramError = function(e:haxe.Exception):Void threw = true;
		bare.start();
		ok('an unknown name still fails with no parent', threw);

		var missing:Script = new Script('res = notAFieldOfHost;', 'missing');
		var alsoThrew:Bool = false;
		missing.interp.parent = new Host();
		missing.onProgramError = function(e:haxe.Exception):Void alsoThrew = true;
		missing.start();
		ok('an unknown name still fails with one', alsoThrew);

		gap('a parent method can be called', result('res = greet();'), 'hello from host');
		gap('a parent method as a value', result('res = greet == null ? "no" : "yes";'), 'yes');
		gap('a getter-only property is read', result('res = doubled;'), '20');
	}

	static function main():Void {
		run();
		TestCase.exit();
	}
}
