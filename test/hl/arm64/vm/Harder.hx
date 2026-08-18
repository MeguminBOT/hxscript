/**
 * The parts of Haxe that reach compiled code from the runtime rather than from other compiled code.
 *
 * Sorting with a comparator, a function held in a Dynamic, Reflect.callMethod, mapping over an array,
 * iterating a map's keys and reading an anonymous object's fields. Each of those leaves the jitted
 * world and comes back into it, through a closure, a wrapper or a method on a structural type, which
 * are exactly the three things a jit has to supply and the code it emits cannot.
 */
class Harder {
	static function twice(n:Int):Int return n * 2;

	static function main() {
		var list = [5, 3, 1, 4, 2];
		list.sort(function(a, b) return a - b);
		Sys.println('sorted    ' + list.join(','));

		var f:Dynamic = twice;
		Sys.println('dynamic   ' + f(21));

		Sys.println('reflect   ' + Reflect.callMethod(null, twice, [21]));

		var mapped = list.map(function(x) return x * x);
		Sys.println('mapped    ' + mapped.join(','));

		var m = new Map<String, Int>();
		m.set('a', 1); m.set('b', 2);
		var total = 0;
		for (k in m.keys()) total += m.get(k);
		Sys.println('iterate   ' + total);

		Sys.println('fields    ' + Reflect.fields({ x: 1, y: 2 }).length);
	}
}
