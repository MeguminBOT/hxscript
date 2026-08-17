package hxscript.stdlib;

/**
 * Standard-library members that have no runtime form, re-registered as real closures.
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

	/** Registers every standard-library member whose runtime form the target does not carry. */
	public static function register():Void {
		strings();

		set('StringTools.hex', function(o:Dynamic, args:Array<Dynamic>):Dynamic {
			var value:Int = args[0];
			var digits:Null<Int> = args.length > 1 ? args[1] : null;

			var out:String = '';
			var chars:String = '0123456789ABCDEF';

			do {
				out = chars.charAt(value & 15) + out;
				value >>>= 4;
			} while (value > 0);

			if (digits != null)
				while (out.length < digits)
					out = '0' + out;

			return out;
		});

		set('StringTools.lpad', function(o:Dynamic, args:Array<Dynamic>):Dynamic {
			var value:String = args[0];
			var char:String = args[1];
			var length:Int = args[2];

			if (char.length <= 0)
				return value;

			var buffer:StringBuf = new StringBuf();
			while (buffer.length + value.length < length)
				buffer.add(char);

			buffer.add(value);
			return buffer.toString();
		});
	}

	/**
	 * `StringTools` members that are `inline` on one target or another.
	 *
	 * Written out rather than forwarded to `StringTools`, because forwarding to a member that was
	 * inlined away is what this exists to work around.
	 */
	static function strings():Void {
		set('StringTools.startsWith', function(o:Dynamic, args:Array<Dynamic>):Dynamic {
			var v:String = args[0];
			var start:String = args[1];
			return v.length >= start.length && v.substr(0, start.length) == start;
		});

		set('StringTools.endsWith', function(o:Dynamic, args:Array<Dynamic>):Dynamic {
			var v:String = args[0];
			var end:String = args[1];
			return v.length >= end.length && v.substr(v.length - end.length) == end;
		});

		set('StringTools.contains', function(o:Dynamic, args:Array<Dynamic>):Dynamic {
			var v:String = args[0];
			return v.indexOf(args[1]) >= 0;
		});

		set('StringTools.isSpace', function(o:Dynamic, args:Array<Dynamic>):Dynamic {
			var v:String = args[0];
			var at:Int = args[1];
			var c:Int = v.charCodeAt(at);
			return (c > 8 && c < 14) || c == 32;
		});

		set('StringTools.ltrim', function(o:Dynamic, args:Array<Dynamic>):Dynamic {
			var v:String = args[0];
			var i:Int = 0;
			while (i < v.length && isBlank(v.charCodeAt(i)))
				i++;
			return i > 0 ? v.substr(i) : v;
		});

		set('StringTools.rtrim', function(o:Dynamic, args:Array<Dynamic>):Dynamic {
			var v:String = args[0];
			var i:Int = v.length;
			while (i > 0 && isBlank(v.charCodeAt(i - 1)))
				i--;
			return i < v.length ? v.substr(0, i) : v;
		});

		set('StringTools.trim', function(o:Dynamic, args:Array<Dynamic>):Dynamic {
			var v:String = args[0];
			var from:Int = 0;
			var to:Int = v.length;
			while (from < to && isBlank(v.charCodeAt(from)))
				from++;
			while (to > from && isBlank(v.charCodeAt(to - 1)))
				to--;
			return v.substr(from, to - from);
		});

		set('StringTools.replace', function(o:Dynamic, args:Array<Dynamic>):Dynamic {
			var v:String = args[0];
			return v.split(args[1]).join(args[2]);
		});

		set('StringTools.rpad', function(o:Dynamic, args:Array<Dynamic>):Dynamic {
			var v:String = args[0];
			var char:String = args[1];
			var length:Int = args[2];

			if (char.length <= 0)
				return v;

			var buffer:StringBuf = new StringBuf();
			buffer.add(v);
			while (buffer.length < length)
				buffer.add(char);

			return buffer.toString();
		});

		set('StringTools.fastCodeAt', function(o:Dynamic, args:Array<Dynamic>):Dynamic {
			var v:String = args[0];
			var at:Int = args[1];
			return at < v.length ? v.charCodeAt(at) : 0;
		});

		set('StringTools.unsafeCodeAt', function(o:Dynamic, args:Array<Dynamic>):Dynamic {
			var v:String = args[0];
			return v.charCodeAt(args[1]);
		});

		set('StringTools.isEof', function(o:Dynamic, args:Array<Dynamic>):Dynamic {
			var c:Null<Int> = args[0];
			return c == null || c <= 0;
		});

		set('StringTools.iterator', function(o:Dynamic, args:Array<Dynamic>):Dynamic {
			var v:String = args[0];
			var codes:Array<Int> = [for (i in 0...v.length) v.charCodeAt(i)];
			return codes.iterator();
		});

		set('StringTools.keyValueIterator', function(o:Dynamic, args:Array<Dynamic>):Dynamic {
			var v:String = args[0];
			var codes:Array<Int> = [for (i in 0...v.length) v.charCodeAt(i)];
			return codes.keyValueIterator();
		});

		set('StringTools.htmlEscape', function(o:Dynamic, args:Array<Dynamic>):Dynamic {
			var v:String = args[0];
			var quotes:Bool = args.length > 1 && args[1] == true;

			var out:String = v.split('&').join('&amp;').split('<').join('&lt;').split('>').join('&gt;');
			if (quotes)
				out = out.split('"').join('&quot;').split("'").join('&#039;');

			return out;
		});

		set('StringTools.htmlUnescape', function(o:Dynamic, args:Array<Dynamic>):Dynamic {
			var v:String = args[0];
			return v.split('&gt;')
				.join('>').split('&lt;').join('<').split('&quot;').join('"').split('&#039;').join("'").split('&amp;').join('&');
		});
	}

	/**
	 * @param c A character code.
	 * @return Whether it is whitespace, matching what `StringTools.trim` treats as trimmable.
	 */
	static function isBlank(c:Null<Int>):Bool {
		return c != null && ((c > 8 && c < 14) || c == 32);
	}
}
