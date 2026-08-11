/*
 * Copyright (c) 2026 MeguminBOT (hxScript)
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 * DEALINGS IN THE SOFTWARE.
 */

package hxscript.hl;

#if hxscript_hl
import haxe.io.Bytes;
import haxe.io.BytesBuffer;

/**
 * Writes the primitives a HashLink module is made of.
 *
 * Everything above this works in whole sections; this works in bytes, and owns the one encoding a
 * reader and a writer can silently disagree about. `index` is HashLink's signed variable-length
 * integer: one byte up to 127, two bytes up to 13 bits, four bytes up to 29, with the sign carried
 * in a bit of the leading byte rather than in the value.
 */
class Writer {
	/** The bytes written so far. */
	var out:BytesBuffer;

	/** Starts an empty stream. */
	public function new() {
		out = new BytesBuffer();
	}

	/** @return How many bytes have been written, which is also the offset of the next one. */
	public var length(get, never):Int;

	inline function get_length():Int {
		return out.length;
	}

	/** Writes one byte. */
	public inline function byte(v:Int):Void {
		out.addByte(v & 0xFF);
	}

	/** Writes a signed 32-bit integer, little-endian and unencoded. */
	public function int32(v:Int):Void {
		out.addByte(v & 0xFF);
		out.addByte((v >> 8) & 0xFF);
		out.addByte((v >> 16) & 0xFF);
		out.addByte((v >>> 24) & 0xFF);
	}

	/** Writes a double, in the platform's own layout, which is what the reader reads back. */
	public function float64(v:Float):Void {
		var b:Bytes = Bytes.alloc(8);
		b.setDouble(0, v);
		out.addBytes(b, 0, 8);
	}

	/**
	 * Writes a variable-length signed integer.
	 *
	 * @param v The value.
	 * @throws String If it does not fit the 29 bits the encoding carries.
	 */
	public function index(v:Int):Void {
		if (v >= 0 && v < 0x80) {
			byte(v);
			return;
		}

		var negative:Bool = v < 0;
		var magnitude:Int = negative ? -v : v;

		if (magnitude < 0x2000) {
			byte(0x80 | (negative ? 0x20 : 0) | ((magnitude >> 8) & 0x1F));
			byte(magnitude & 0xFF);
			return;
		}

		if (magnitude >= 0x20000000)
			throw 'value ' + v + ' does not fit a HashLink index';

		byte(0xC0 | (negative ? 0x20 : 0) | ((magnitude >> 24) & 0x1F));
		byte((magnitude >> 16) & 0xFF);
		byte((magnitude >> 8) & 0xFF);
		byte(magnitude & 0xFF);
	}

	/**
	 * Writes a variable-length unsigned integer.
	 *
	 * The same encoding as `index`, with the negative half refused: a reader that meets one there
	 * stops with `Negative index`, and finding out here says which value did it.
	 *
	 * @param v The value.
	 * @throws String If it is negative.
	 */
	public function uindex(v:Int):Void {
		if (v < 0)
			throw 'unsigned index cannot be ' + v;
		index(v);
	}

	/** Writes raw bytes. */
	public inline function bytes(b:Bytes):Void {
		out.addBytes(b, 0, b.length);
	}

	/**
	 * Writes a string pool: the packed bytes, then each entry's length.
	 *
	 * Every entry is terminated even though its length is written too, because the reader checks
	 * for the terminator and rejects the module when it is missing.
	 *
	 * @param values The strings, in index order.
	 */
	public function stringPool(values:Array<String>):Void {
		var packed:BytesBuffer = new BytesBuffer();
		var lengths:Array<Int> = [];

		for (value in values) {
			var raw:Bytes = Bytes.ofString(value);
			packed.addBytes(raw, 0, raw.length);
			packed.addByte(0);
			lengths.push(raw.length);
		}

		var body:Bytes = packed.getBytes();
		int32(body.length);
		bytes(body);

		for (len in lengths)
			uindex(len);
	}

	/** @return Everything written. */
	public function done():Bytes {
		return out.getBytes();
	}
}
#end
