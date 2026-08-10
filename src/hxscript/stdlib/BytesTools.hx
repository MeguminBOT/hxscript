package hxscript.stdlib;

import haxe.io.Bytes;

/**
 * Bulk byte access for scripts.
 */
@:keep
class BytesTools {
	/**
	 * Copies a byte range into a plain array of unsigned values.
	 *
	 * @param bytes The buffer to read.
	 * @param start First byte to copy; defaults to the beginning.
	 * @param length How many to copy; defaults to the rest of the buffer.
	 * @return The bytes as an array, empty when there is nothing to read.
	 */
	public static function toIntArray(bytes:Bytes, start:Int = 0, length:Int = -1):Array<Int> {
		if (bytes == null)
			return [];

		var from:Int = start < 0 ? 0 : start;
		if (from > bytes.length)
			return [];

		var count:Int = length < 0 ? bytes.length - from : length;
		if (from + count > bytes.length)
			count = bytes.length - from;

		var out:Array<Int> = [];
		for (i in 0...count)
			out.push(bytes.get(from + i));

		return out;
	}

	/**
	 * Reads a fixed-size, NUL-padded name, upper-cased.
	 *
	 * Container formats pad short names out to a fixed width with NULs, and building that string a
	 * character at a time is a call per character from a script. This is here because it is the one
	 * string operation such formats need in bulk.
	 *
	 * @param bytes The buffer to read.
	 * @param start Where the field begins.
	 * @param width How wide the field is.
	 * @return The name, without its padding, or the empty string when the range is out of bounds.
	 */
	public static function fixedName(bytes:Bytes, start:Int, width:Int):String {
		if (bytes == null || start < 0 || start + width > bytes.length)
			return '';

		var out:StringBuf = new StringBuf();
		for (i in 0...width) {
			var c:Int = bytes.get(start + i);
			if (c != 0)
				out.addChar(c);
		}

		return out.toString().toUpperCase();
	}
}
