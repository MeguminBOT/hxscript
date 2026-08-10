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

package hxscript.debug;

/**
 * Counts what the interpreter does, for a host that wants to show it.
 */
class Metrics {
	/** Whether to count. Off, so nothing pays for a host that does not ask. */
	public static var on:Bool = false;

	/** Method and function calls the interpreter has performed. */
	public static var calls:Int = 0;

	/** Instances of scripted classes constructed. */
	public static var instances:Int = 0;

	/** Fields read through the interpreter, which is every access compiled code would have inlined. */
	public static var reads:Int = 0;

	/** Fields written through it. */
	public static var writes:Int = 0;

	/** Zeroes every count, leaving `on` as it was. */
	public static function reset():Void {
		calls = 0;
		instances = 0;
		reads = 0;
		writes = 0;
	}
}
