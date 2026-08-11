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

#if (hl && hxscript_hl)
import haxe.io.Bytes;

/** A module the VM has read and jitted, kept alive for as long as anything calls into it. */
typedef Loaded = hl.Abstract<"hxs_module">;

/**
 * Reaches HashLink's bytecode loader, which the VM does not otherwise offer.
 *
 * `hl_code_read` and `hl_module_init` are compiled into `hl.exe` rather than into `libhl`, so there
 * is no way to them from Haxe. `hxscript.hdll` carries hashlink's own copies and these are its
 * entry points; `hxscript.setup.Extension` builds it.
 *
 * Every native names the library as `?hxscript`, which is what makes shipping it a choice rather
 * than a condition of starting. HashLink resolves a module's natives before any of its code runs, so
 * without the mark a program built to be able to compile scripts would refuse to run at all on a
 * machine that had not got the extension. With it, an absent or unusable library leaves these bound
 * to a stub, `available` says so, and everything is interpreted.
 */
class Loader {
	/** Whether the extension is here and agrees with this VM, which is what decides if this can be used. */
	public static var available(get, never):Bool;

	static var probed:Null<Bool> = null;

	static function get_available():Bool {
		if (probed == null) {
			try {
				probed = hl.Api.isPrimLoaded(read) && agrees();
			} catch (e:Dynamic) {
				probed = false;
			}
		}
		return probed;
	}

	/**
	 * @return The hashlink the extension was built against, or -1 when there is no extension.
	 *
	 * Reported rather than acted on. An extension that disagrees with the VM makes `available` false
	 * on its own; this is for a host that wants to say which two things did not match.
	 */
	public static function builtFor():Int {
		try {
			return hl.Api.isPrimLoaded(builtVersion) ? builtVersion() : -1;
		} catch (e:Dynamic) {
			return -1;
		}
	}

	/**
	 * Reads, links and jits a module.
	 *
	 * @param bytes The module.
	 * @return It, or null when it could not be read; `error` then says why.
	 */
	public static function load(bytes:Bytes):Null<Loaded> {
		return read(@:privateAccess bytes.b, bytes.length);
	}

	/**
	 * Wraps one of a loaded module's functions as an ordinary function value.
	 *
	 * What comes back is a closure like any other, which is what lets a compiled function stand in
	 * for an interpreted one without anything above having to know.
	 *
	 * @param module The module.
	 * @param findex The function's index.
	 * @return The closure, or null when there is no such function.
	 */
	public static function bind(module:Loaded, findex:Int):Dynamic {
		return closure(module, findex);
	}

	/** @return The function index the module names as its entry point, or -1 when there is none. */
	public static function entryIndex(module:Loaded):Int {
		return entry(module);
	}

	/**
	 * Puts a value in one of a loaded module's globals.
	 *
	 * @param module The module.
	 * @param index The global's index.
	 * @param value What to put there.
	 */
	public static function set(module:Loaded, index:Int, value:Dynamic):Void {
		setGlobal(module, index, value);
	}

	/** @return Why the last `load` failed, or null when it did not. */
	public static function error():Null<String> {
		var raw:hl.Bytes = lastError();
		return raw == null ? null : @:privateAccess String.fromUTF8(raw);
	}

	@:hlNative("?hxscript", "load") static function read(data:hl.Bytes, size:Int):Loaded {
		return null;
	}

	@:hlNative("?hxscript", "closure") static function closure(module:Loaded, findex:Int):Dynamic {
		return null;
	}

	@:hlNative("?hxscript", "entry_index") static function entry(module:Loaded):Int {
		return -1;
	}

	@:hlNative("?hxscript", "set_global") static function setGlobal(module:Loaded, index:Int, value:Dynamic):Void {}

	@:hlNative("?hxscript", "last_error") static function lastError():hl.Bytes {
		return null;
	}

	@:hlNative("?hxscript", "agrees") static function agrees():Bool {
		return false;
	}

	@:hlNative("?hxscript", "built_for") static function builtVersion():Int {
		return -1;
	}
}
#end
