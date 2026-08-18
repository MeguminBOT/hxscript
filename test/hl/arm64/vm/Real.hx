/**
 * An ordinary Haxe program, for hashlink's own VM to run on this library's jit.
 *
 * Not a script and nothing to do with hxScript: the point is that a jit written for the bytecode
 * hxScript emits also runs the bytecode Haxe emits, which is a far wider part of the instruction set.
 * Classes, enums with pattern matching, arrays, maps, anonymous structures, exceptions and string
 * work, each printing something a reader can check by eye.
 */
enum Shape { Circle(r:Float); Rect(w:Float, h:Float); }

class Real {
	var name:String;
	public function new(n:String) name = n;
	public function greet():String return 'hello ' + name;

	static function area(s:Shape):Float {
		return switch (s) {
			case Circle(r): 3.14159 * r * r;
			case Rect(w, h): w * h;
		}
	}

	static function main() {
		var total = 0;
		for (i in 0...10) total += i * i;
		Sys.println('loop      ' + total);

		var list = [1, 2, 3, 4, 5];
		list.push(6);
		Sys.println('array     ' + list.length + ' ' + list[5]);

		var map = new Map<String, Int>();
		map.set('answer', 42);
		Sys.println('map       ' + map.get('answer'));

		Sys.println('object    ' + new Real('world').greet());
		Sys.println('enum      ' + area(Rect(6, 7)));

		try throw 'thrown' catch (e:String) Sys.println('catch     ' + e);

		var anon = { x: 3, y: 4 };
		Sys.println('anon      ' + (anon.x + anon.y));
		Sys.println('string    ' + 'AB'.toLowerCase() + ' ' + Std.string(1.5));
	}
}
