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

package hxscript.cppia;

#if hxscript_cppia
import haxe.ds.StringMap;
import haxe.io.Bytes;

/**
 * Builds a cppia module in the textual `CPPIA` form: a string pool, a type pool, then class records
 * that reference both by index. Records are buffered so the header can be written once the pools
 * have settled.
 */
class Writer {
	/** The string pool, in the order the header writes it. */
	var strings:Array<String>;

	/** Index of each pooled string, so a repeat costs nothing. */
	var stringIds:StringMap<Int>;

	/** The type pool, written the same way. */
	var types:Array<String>;

	/** Index of each pooled type. */
	var typeIds:StringMap<Int>;

	/** Everything after the header: the tokens themselves. */
	var body:StringBuf;

	/** Starts an empty module, with the pools seeded so index zero is the empty entry. */
	public function new() {
		strings = [];
		stringIds = new StringMap();
		types = [];
		typeIds = new StringMap();
		body = new StringBuf();

		typeId('');
		stringId('');
	}

	/**
	 * Interns a string.
	 *
	 * @param s The string to intern.
	 * @return Its pool index.
	 */
	public function stringId(s:String):Int {
		if (s == null)
			s = '';

		var known:Null<Int> = stringIds.get(s);
		if (known != null)
			return known;

		var id:Int = strings.length;
		strings.push(s);
		stringIds.set(s, id);
		return id;
	}

	/**
	 * Interns a type path.
	 *
	 * @param path The dotted type path.
	 * @return Its pool index.
	 */
	public function typeId(path:String):Int {
		if (path == null)
			path = '';

		var known:Null<Int> = typeIds.get(path);
		if (known != null)
			return known;

		var id:Int = types.length;
		types.push(path);
		typeIds.set(path, id);
		return id;
	}

	/**
	 * A readable echo of what is being written, or null.
	 *
	 * The body is a stream of pool indices, so reading it back means resolving every number against
	 * the pools to find out what it meant. These methods are handed the real names on the way in, so
	 * recording them here is exact and costs nothing when it is off.
	 */
	public var echo:StringBuf = null;

	/**
	 * Writes one opcode or keyword.
	 *
	 * @param t The token text.
	 */
	public inline function token(t:String):Void {
		if (echo != null) {
			echo.addChar(10);
			echo.add(t);
		}
		body.add(t);
		body.addChar(' '.code);
	}

	/**
	 * Writes an integer operand, space separated.
	 *
	 * @param v The value.
	 */
	public inline function int(v:Int):Void {
		if (echo != null) {
			echo.addChar(' '.code);
			echo.add(Std.string(v));
		}
		body.add(Std.string(v));
		body.addChar(' '.code);
	}

	/**
	 * Writes a flag, which the format spells as an integer.
	 *
	 * @param v The value.
	 */
	public inline function bool(v:Bool):Void {
		int(v ? 1 : 0);
	}

	/** Writes a string as its pool index. */
	public inline function str(s:String):Void {
		if (echo != null) {
			echo.add(' "');
			echo.add(s);
			echo.addChar('"'.code);
		}
		var saved:StringBuf = echo;
		echo = null;
		int(stringId(s));
		echo = saved;
	}

	/** Writes a type path as its pool index, falling back to `Dynamic` for an empty path. */
	public inline function type(path:String):Void {
		if (echo != null) {
			echo.addChar(' '.code);
			echo.add((path == null || path.length == 0) ? '<Dynamic>' : '<' + path + '>');
		}
		var saved:StringBuf = echo;
		echo = null;
		if (path == null || path.length == 0)
			unknownType();
		else
			int(typeId(path));
		echo = saved;
	}

	/**
	 * Writes the type used where the real one is not known.
	 *
	 * Emits `Dynamic`, never pool index 0: an empty type name resolves to no class and corrupts the
	 * loader rather than failing it.
	 */
	public inline function unknownType():Void {
		int(typeId('Dynamic'));
	}

	/** Ends the current expression. The format is whitespace separated, so this is a separator. */
	public inline function newline():Void {
		body.addChar('\n'.code);
	}

	/**
	 * Writes the file id and line prefixing every expression in the textual form.
	 *
	 * @param line The source line.
	 */
	public inline function pos(line:Int):Void {
		int(0);
		int(line);
	}

	/**
	 * Assembles the finished module. Pool string lengths are counted in bytes, not characters.
	 *
	 * @param classCount How many class records the body holds.
	 * @return The complete module.
	 */
	public function finish(classCount:Int):Bytes {
		var out:StringBuf = new StringBuf();
		out.add('CPPIA\n');

		out.add(strings.length);
		out.addChar('\n'.code);
		for (s in strings) {
			out.add(Bytes.ofString(s).length);
			out.addChar(' '.code);
			out.add(s);
			out.addChar('\n'.code);
		}

		out.add(types.length);
		out.addChar('\n'.code);
		for (t in types) {
			out.add(Bytes.ofString(t).length);
			out.addChar(' '.code);
			out.add(t);
			out.addChar('\n'.code);
		}

		out.add(classCount);
		out.addChar('\n'.code);
		out.add(body.toString());

		return Bytes.ofString(out.toString());
	}
}
#end
