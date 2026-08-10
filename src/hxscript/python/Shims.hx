package hxscript.python;

#if python
import python.internal.ArrayImpl;
import python.internal.StringImpl;

/**
 * Array and String members, re-registered as real closures.
 */
class Shims {
	/**
	 * Registers one shim through the setup registrar.
	 *
	 * @param key `<fully.qualified.Owner>.<method>`.
	 * @param shim Receives the receiver and the call arguments.
	 */
	static function set(key:String, shim:(o:Dynamic, args:Array<Dynamic>) -> Dynamic):Void {
		hxscript.setup.Shims.set(key, shim);
	}

	/** Registers every Array and String member the builtins do not carry themselves. */
	public static function register():Void {
		array();
		string();
	}

	/** `Array`, whose members are statics on `python.internal.ArrayImpl`. */
	static function array():Void {
		set('Array.push', function(o:Dynamic, a:Array<Dynamic>):Dynamic return ArrayImpl.push(o, a[0]));
		set('Array.pop', function(o:Dynamic, a:Array<Dynamic>):Dynamic return ArrayImpl.pop(o));
		set('Array.shift', function(o:Dynamic, a:Array<Dynamic>):Dynamic return ArrayImpl.shift(o));
		set('Array.unshift', function(o:Dynamic, a:Array<Dynamic>):Dynamic {
			ArrayImpl.unshift(o, a[0]);
			return null;
		});
		set('Array.insert', function(o:Dynamic, a:Array<Dynamic>):Dynamic {
			ArrayImpl.insert(o, a[0], a[1]);
			return null;
		});
		set('Array.remove', function(o:Dynamic, a:Array<Dynamic>):Dynamic return ArrayImpl.remove(o, a[0]));
		set('Array.contains', function(o:Dynamic, a:Array<Dynamic>):Dynamic return ArrayImpl.contains(o, a[0]));
		set('Array.indexOf', function(o:Dynamic, a:Array<Dynamic>):Dynamic return ArrayImpl.indexOf(o, a[0], a.length > 1 ? a[1] : null));
		set('Array.lastIndexOf', function(o:Dynamic, a:Array<Dynamic>):Dynamic return ArrayImpl.lastIndexOf(o, a[0], a.length > 1 ? a[1] : null));
		set('Array.join', function(o:Dynamic, a:Array<Dynamic>):Dynamic return ArrayImpl.join(o, a[0]));
		set('Array.reverse', function(o:Dynamic, a:Array<Dynamic>):Dynamic {
			ArrayImpl.reverse(o);
			return null;
		});
		set('Array.sort', function(o:Dynamic, a:Array<Dynamic>):Dynamic {
			ArrayImpl.sort(o, a[0]);
			return null;
		});
		set('Array.slice', function(o:Dynamic, a:Array<Dynamic>):Dynamic return ArrayImpl.slice(o, a[0], a.length > 1 ? a[1] : null));
		set('Array.splice', function(o:Dynamic, a:Array<Dynamic>):Dynamic return ArrayImpl.splice(o, a[0], a[1]));
		set('Array.concat', function(o:Dynamic, a:Array<Dynamic>):Dynamic return ArrayImpl.concat(o, a[0]));
		set('Array.copy', function(o:Dynamic, a:Array<Dynamic>):Dynamic return ArrayImpl.copy(o));
		set('Array.map', function(o:Dynamic, a:Array<Dynamic>):Dynamic return ArrayImpl.map(o, a[0]));
		set('Array.filter', function(o:Dynamic, a:Array<Dynamic>):Dynamic return ArrayImpl.filter(o, a[0]));
		set('Array.resize', function(o:Dynamic, a:Array<Dynamic>):Dynamic {
			ArrayImpl.resize(o, a[0]);
			return null;
		});
		set('Array.iterator', function(o:Dynamic, a:Array<Dynamic>):Dynamic return ArrayImpl.iterator(o));
		set('Array.keyValueIterator', function(o:Dynamic, a:Array<Dynamic>):Dynamic return ArrayImpl.keyValueIterator(o));
		set('Array.toString', function(o:Dynamic, a:Array<Dynamic>):Dynamic return ArrayImpl.toString(o));
	}

	/** `String`, whose members are statics on `python.internal.StringImpl`. */
	static function string():Void {
		set('String.fromCharCode', function(o:Dynamic, a:Array<Dynamic>):Dynamic return StringImpl.fromCharCode(a[0]));
		set('String.split', function(o:Dynamic, a:Array<Dynamic>):Dynamic return StringImpl.split(o, a[0]));
		set('String.charAt', function(o:Dynamic, a:Array<Dynamic>):Dynamic return StringImpl.charAt(o, a[0]));
		set('String.charCodeAt', function(o:Dynamic, a:Array<Dynamic>):Dynamic return StringImpl.charCodeAt(o, a[0]));
		set('String.indexOf', function(o:Dynamic, a:Array<Dynamic>):Dynamic return StringImpl.indexOf(o, a[0], a.length > 1 ? a[1] : null));
		set('String.lastIndexOf', function(o:Dynamic, a:Array<Dynamic>):Dynamic return StringImpl.lastIndexOf(o, a[0], a.length > 1 ? a[1] : null));
		set('String.toUpperCase', function(o:Dynamic, a:Array<Dynamic>):Dynamic return StringImpl.toUpperCase(o));
		set('String.toLowerCase', function(o:Dynamic, a:Array<Dynamic>):Dynamic return StringImpl.toLowerCase(o));
		set('String.substring', function(o:Dynamic, a:Array<Dynamic>):Dynamic return StringImpl.substring(o, a[0], a.length > 1 ? a[1] : null));
		set('String.substr', function(o:Dynamic, a:Array<Dynamic>):Dynamic return StringImpl.substr(o, a[0], a.length > 1 ? a[1] : null));
		set('String.toString', function(o:Dynamic, a:Array<Dynamic>):Dynamic return StringImpl.toString(o));
	}
}
#end
