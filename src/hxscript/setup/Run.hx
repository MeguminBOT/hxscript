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

package hxscript.setup;

#if (sys || macro)
import hxscript.setup.Extension.Outcome;
import sys.FileSystem;

/**
 * What `haxelib run hxscript` does.
 *
 * A build with `-lib hxscript -D hxscript_hl` produces the HashLink extension on its own, so this
 * is for the times that is not what you want: a build machine with no compiler that shipped the
 * sources instead, an extension that has to land somewhere other than beside the output, or finding
 * out why the automatic attempt reported what it did.
 */
class Run {
	public static function main():Void {
		var args:Array<String> = Sys.args();

		var home:String = Sys.getCwd();
		var here:String = home;

		if (Sys.getEnv('HAXELIB_RUN') != null && args.length > 0)
			here = args.pop();

		var carried:Null<String> = shipped();
		if (carried == null)
			carried = library(home);

		Sys.setCwd(here);

		if (carried == null)
			carried = library(here);

		var command:String = args.length > 0 ? args.shift() : 'hdll';

		switch (command) {
			case 'hdll':
				hdll(args, carried);

			case 'help' | '--help' | '-h':
				usage();

			case _:
				Sys.println('hxscript: no command called "' + command + '"');
				usage();
				Sys.exit(1);
		}
	}

	/**
	 * Builds the HashLink extension.
	 *
	 * @param args Whatever followed the command.
	 * @param carried The directory holding `hxscript.c`, or null when this install has none.
	 */
	static function hdll(args:Array<String>, carried:Null<String>):Void {
		var into:String = args.length > 0 ? args[0] : '.';

		if (carried == null) {
			Sys.println('hxscript: could not find hxscript.c, so this is not a complete install of the library');
			Sys.exit(1);
		}

		switch (Extension.ensure(into, carried)) {
			case Ready(path):
				Sys.println('hxscript: ' + path + ' is already current');

			case Built(path):
				Sys.println('hxscript: built ' + path);

			case Missing(reason, remedy):
				Sys.println('hxscript: ' + reason);
				Sys.println('          to fix it, ' + remedy);
				Sys.exit(1);
		}
	}

	/**
	 * @return The directory `hxscript.c` sat in when this was compiled, or null when it is gone.
	 *
	 * Baked in rather than searched for. Whichever class path carried this class carried the C
	 * beside it, and that is a better answer than anything the working directory can give: `haxelib
	 * run` starts in the library, a plain `--run` starts wherever the caller was, and neither is
	 * reliably the install.
	 */
	static macro function shipped():haxe.macro.Expr {
		var found:String = null;

		try {
			found = haxe.io.Path.directory(haxe.macro.Context.resolvePath('hxscript/hl/hxscript.c'));
			found = sys.FileSystem.absolutePath(found);
		} catch (e:Dynamic) {
			found = null;
		}

		return macro $v{found};
	}

	/**
	 * @param root Where to look from.
	 * @return The directory holding `hxscript.c`, absolute, or null when it is not under there.
	 *
	 * Absolute because the answer outlives the working directory: `haxelib run` starts in the
	 * library and the build being helped is somewhere else entirely.
	 */
	static function library(root:String):Null<String> {
		for (guess in ['src/hxscript/hl', 'hxscript/hl']) {
			var at:String = haxe.io.Path.join([root, guess]);
			if (FileSystem.exists(haxe.io.Path.join([at, 'hxscript.c'])))
				return FileSystem.absolutePath(at);
		}

		return null;
	}

	static function usage():Void {
		Sys.println('hxscript');
		Sys.println('');
		Sys.println('  haxelib run hxscript hdll [directory]');
		Sys.println('    Builds hxscript.hdll, which lets a HashLink host run compiled scripts.');
		Sys.println('    Goes in the current directory unless one is named. A build with');
		Sys.println('    -lib hxscript -D hxscript_hl does this on its own, beside its output.');
		Sys.println('');
		Sys.println('  Environment');
		Sys.println('    HLPATH             where the HashLink VM is, when it is not on the path');
		Sys.println('    HL_SRC             a hashlink source tree to build against, matching the VM');
		Sys.println('    CC                 the C compiler to use');
	}
}
#end
