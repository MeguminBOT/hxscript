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

/** Where the value that fills a bound global comes from. */
enum abstract BindingKind(Int) to Int {
	/** Something the host owns, named as the script spelled it. */
	var BHost = 0;

	/** One of `Runtime`'s statics, which is what compiled code calls for what it cannot express. */
	var BSupport = 1;

	/** A value the emitter already had, because being handed one costs less than building it. */
	var BConst = 2;
}

/**
 * One global a module needs filled before it runs.
 *
 * Compiled code cannot link to anything outside its own module, so everything it reaches for lives
 * in a global that is filled once after loading. Where the value comes from differs; that it is
 * fetched once rather than per use is the point, since a lookup per use is most of what makes the
 * interpreter slow.
 */
@:structInit
class Binding {
	/** The global to fill. */
	public var index:Int;

	/** Where its value comes from. */
	public var kind:BindingKind;

	/** For a host value, the owner as the script wrote it. */
	public var owner:String = '';

	/** For a host value or a support call, the field's name. */
	public var field:String = '';

	/** For a constant, the value itself. */
	public var value:Dynamic = null;
}
