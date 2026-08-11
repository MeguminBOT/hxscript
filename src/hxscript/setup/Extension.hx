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
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import sys.io.Process;

/** What one attempt to produce the extension found out. */
enum Outcome {
	/** It is there and current. Nothing was done. */
	Ready(path:String);

	/** It was built. */
	Built(path:String);

	/** It could not be, and this says what to do about it. */
	Missing(reason:String, remedy:String);
}

/**
 * Produces `hxscript.hdll`, which is what lets a HashLink host load compiled scripts.
 *
 * HashLink's bytecode loader is compiled into `hl.exe` rather than into `libhl`, so a host cannot
 * reach it and the library carries hashlink's own `code.c`, `module.c` and `jit.c` in a small
 * extension instead. Those have to be compiled against the same hashlink the VM was built from,
 * which is the whole difficulty: the struct layouts in `hl.h` are shared with the running `libhl`,
 * so a mismatched pair links and only then misbehaves.
 *
 * Everything that can be worked out from this machine is worked out: the VM, its version, a source
 * tree, a compiler, and where the build's output will look for the result. Nothing is fetched and
 * nothing leaves the machine. What is not already here is reported as one sentence naming the thing
 * to install, never as a failed build.
 */
class Extension {
	/**
	 * Makes sure the extension is next to a build's output, building it when it is not.
	 *
	 * @param into The directory the output runs from, which is where HashLink looks.
	 * @param carried The directory holding `hxscript.c`.
	 * @return What happened.
	 */
	public static function ensure(into:String, carried:String):Outcome {
		var out:String = Path.join([into, 'hxscript.hdll']);

		var vm:Null<String> = machine();
		if (vm == null)
			return Missing('no HashLink VM was found', 'install HashLink, or set HLPATH to the directory holding libhl');

		var version:Null<String> = versionOf(vm);
		if (version == null)
			return Missing('the HashLink at ' + vm + ' would not report its version', 'check that it runs, or set HL_SRC to a matching source tree');

		if (current(out, carried, version))
			return Ready(out);

		var sources:Null<String> = tree();
		if (sources == null)
			return Missing('no hashlink sources were found',
				'run hdll.sh or hdll.bat beside hxscript.c, which offers to fetch the hashlink ' + version + ' sources, or set HL_SRC yourself');

		var mismatch:Null<String> = disagreement(sources, version);
		if (mismatch != null)
			return Missing(mismatch, 'point HL_SRC at a hashlink ' + version + ' tree');

		var cc:Null<String> = compiler();
		if (cc == null)
			return Missing('no C compiler was found', hint());

		if (!FileSystem.exists(into))
			FileSystem.createDirectory(into);

		var problem:Null<String> = compile(cc, sources, vm, carried, out);
		if (problem != null)
			return Missing('the extension did not compile', problem);

		File.saveContent(out + '.built', version);
		return Built(out);
	}

	/**
	 * @return Whether a built extension is there, no older than what it was built from, and built
	 *         for the HashLink that is going to run it.
	 *
	 * The version is the part that matters. An upgraded VM leaves an extension whose timestamp says
	 * it is current and whose struct layouts no longer are, which is exactly the mismatch this is
	 * all trying to avoid, so what it was built for is recorded beside it and compared rather than
	 * inferred.
	 */
	static function current(out:String, carried:String, version:String):Bool {
		if (!FileSystem.exists(out))
			return false;

		if (built(out) != version)
			return false;

		var glue:String = Path.join([carried, 'hxscript.c']);
		if (!FileSystem.exists(glue))
			return true;

		return FileSystem.stat(out).mtime.getTime() >= FileSystem.stat(glue).mtime.getTime();
	}

	/** @return The version an extension records having been built for, or null when it records none. */
	static function built(out:String):Null<String> {
		var note:String = out + '.built';
		return FileSystem.exists(note) ? StringTools.trim(File.getContent(note)) : null;
	}

	/**
	 * Finds the directory holding the VM's shared library.
	 *
	 * `HLPATH` is hashlink's own convention and is tried first, then whatever `hl` on the path
	 * resolves to, then the places the installers use.
	 *
	 * @return The directory, or null when there is no HashLink here.
	 */
	public static function machine():Null<String> {
		var named:Null<String> = Sys.getEnv('HLPATH');
		if (named != null && holdsRuntime(named))
			return named;

		var found:Null<String> = onPath('hl');
		if (found != null) {
			var dir:String = Path.directory(found);
			if (holdsRuntime(dir))
				return dir;
		}

		for (guess in likely()) {
			if (holdsRuntime(guess))
				return guess;
		}

		return null;
	}

	/** @return Whether a directory holds the shared library this links against. */
	static function holdsRuntime(dir:String):Bool {
		for (name in ['libhl.dll', 'libhl.so', 'libhl.dylib', 'libhl.lib']) {
			if (FileSystem.exists(Path.join([dir, name])))
				return true;
		}
		return false;
	}

	/** @return The places a HashLink install is usually put, for this platform. */
	static function likely():Array<String> {
		return switch (Sys.systemName()) {
			case 'Windows': ['C:/HaxeToolkit/hl', 'C:/hashlink', 'C:/Program Files/hashlink'];
			case 'Mac': ['/usr/local/lib', '/opt/homebrew/lib', '/usr/local/opt/hashlink/lib'];
			case _: ['/usr/local/lib', '/usr/lib', '/usr/lib/x86_64-linux-gnu'];
		}
	}

	/**
	 * @param vm The directory holding the VM.
	 * @return Its version as hashlink tags them, or null when it would not say.
	 */
	static function versionOf(vm:String):Null<String> {
		var exe:String = Path.join([vm, Sys.systemName() == 'Windows' ? 'hl.exe' : 'hl']);
		var said:Null<String> = FileSystem.exists(exe) ? say(exe, ['--version']) : say('hl', ['--version']);

		if (said == null)
			return null;

		var trimmed:String = StringTools.trim(said.split('\n')[0]);
		return trimmed.length == 0 ? null : trimmed;
	}

	/**
	 * Finds a hashlink source tree on this machine.
	 *
	 * Only what is already here is considered. Nothing is downloaded: a library has no business
	 * reaching the network during someone's build, and a source tree fetched from anywhere but the
	 * machine's own package management is not something a build should be quietly trusting.
	 *
	 * @return The tree's root, or null when this machine has none.
	 */
	static function tree():Null<String> {
		var named:Null<String> = Sys.getEnv('HL_SRC');
		if (named != null && isTree(named))
			return named;

		var vm:Null<String> = machine();
		if (vm == null)
			return null;

		for (near in [Path.join([vm, 'src']), Path.join([vm, '..', 'src']), Path.join([vm, '..']), Path.join([vm, '..', '..'])]) {
			if (isTree(near))
				return near;
		}

		return null;
	}

	/** @return Whether a directory is a hashlink checkout, by the files this needs from one. */
	static function isTree(dir:String):Bool {
		for (needed in ['src/hl.h', 'src/hlmodule.h', 'src/opcodes.h', 'src/code.c', 'src/module.c', 'src/jit.c']) {
			if (!FileSystem.exists(Path.join([dir, needed])))
				return false;
		}
		return true;
	}

	/**
	 * @return Why a source tree does not match the VM, or null when it does.
	 *
	 * `hl.h` carries the version it belongs to, so this is a fact rather than a guess. Catching it
	 * here is the point of the whole check: a mismatched pair compiles and links cleanly, and what
	 * goes wrong afterwards is memory read through the wrong struct layout.
	 */
	static function disagreement(sources:String, version:String):Null<String> {
		var declared:Null<String> = stamped(Path.join([sources, 'src/hl.h']));
		if (declared == null || declared == version)
			return null;

		return 'the sources at ' + sources + ' are hashlink ' + declared + ', and the VM is ' + version;
	}

	/**
	 * @param header A path to `hl.h`.
	 * @return The version it declares, or null when it declares none this can read.
	 */
	static function stamped(header:String):Null<String> {
		if (!FileSystem.exists(header))
			return null;

		var mark:EReg = ~/#[ \t]*define[ \t]+HL_VERSION[ \t]+0x0?([0-9a-fA-F]{2})([0-9a-fA-F]{2})([0-9a-fA-F]{2})/;
		if (!mark.match(File.getContent(header)))
			return null;

		var major:Int = Std.parseInt('0x' + mark.matched(1));
		var minor:Int = Std.parseInt('0x' + mark.matched(2));
		var patch:Int = Std.parseInt('0x' + mark.matched(3));

		return major + '.' + minor + '.' + patch;
	}

	/** @return A C compiler this can drive, or null when none is installed. */
	public static function compiler():Null<String> {
		var named:Null<String> = Sys.getEnv('CC');
		if (named != null && onPath(named) != null)
			return named;

		var tried:Array<String> = Sys.systemName() == 'Windows' ? ['x86_64-w64-mingw32-gcc', 'gcc', 'clang'] : ['cc', 'gcc', 'clang'];

		for (name in tried) {
			if (onPath(name) != null)
				return name;
		}

		return null;
	}

	/** @return What to tell someone who has no compiler, for the platform they are on. */
	static function hint():String {
		return switch (Sys.systemName()) {
			case 'Windows': 'install mingw-w64, or set CC to a C compiler that targets x86_64 Windows';
			case 'Mac': 'install the Xcode command line tools with xcode-select --install';
			case _: 'install build-essential, or set CC to a C compiler';
		}
	}

	/**
	 * Compiles the extension.
	 *
	 * Built under another name and given its own only once it is whole. A build stopped part way
	 * through would otherwise leave something that loads, and an extension that half exists is worse
	 * than one that does not: the loader would take it and the failure would come later.
	 *
	 * @param cc The compiler.
	 * @param sources A hashlink tree.
	 * @param vm The directory holding the VM's shared library.
	 * @param carried The directory holding `hxscript.c`.
	 * @param out Where the extension goes.
	 * @return What went wrong, or null when nothing did.
	 */
	static function compile(cc:String, sources:String, vm:String, carried:String, out:String):Null<String> {
		var partial:String = out + '.building';
		var args:Array<String> = ['-O2', '-I' + Path.join([sources, 'src']), '-I' + carried];

		switch (Sys.systemName()) {
			case 'Windows':
				args.push('-shared');
				args.push('-m64');
			case 'Mac':
				args.push('-dynamiclib');
				args.push('-fPIC');
			case _:
				args.push('-shared');
				args.push('-fPIC');
		}

		args.push('-o');
		args.push(partial);
		args.push(Path.join([carried, 'hxscript.c']));

		for (part in ['code.c', 'module.c', 'jit.c'])
			args.push(Path.join([sources, 'src', part]));

		if (Sys.systemName() == 'Windows') {
			args.push(Path.join([vm, 'libhl.dll']));
		} else {
			args.push('-L' + vm);
			args.push('-lhl');
		}

		var process:Process = null;

		if (FileSystem.exists(partial))
			FileSystem.deleteFile(partial);

		try {
			process = new Process(cc, args);
			var code:Int = process.exitCode();
			var complaint:String = process.stderr.readAll().toString();
			process.close();

			if (code != 0)
				return StringTools.trim(complaint.split('\n').slice(0, 4).join('\n'));
		} catch (e:Dynamic) {
			if (process != null)
				process.close();
			return 'could not run ' + cc;
		}

		if (!FileSystem.exists(partial))
			return 'the compiler reported success and produced nothing';

		if (FileSystem.exists(out))
			FileSystem.deleteFile(out);

		FileSystem.rename(partial, out);
		return null;
	}

	/**
	 * @param name A program.
	 * @return Where it is, or null when it is not on the path.
	 */
	static function onPath(name:String):Null<String> {
		var asked:Null<String> = say(Sys.systemName() == 'Windows' ? 'where' : 'which', [name]);
		if (asked == null)
			return null;

		var first:String = StringTools.trim(asked.split('\n')[0]);
		return first.length == 0 ? null : first;
	}

	/**
	 * Runs a program and reads what it said.
	 *
	 * @param cmd The program.
	 * @param args Its arguments.
	 * @return Its output, or null when it could not be run or failed.
	 */
	static function say(cmd:String, args:Array<String>):Null<String> {
		var process:Process = null;

		try {
			process = new Process(cmd, args);
			var out:String = process.stdout.readAll().toString();
			var code:Int = process.exitCode();
			process.close();
			return code == 0 ? out : null;
		} catch (e:Dynamic) {
			if (process != null)
				process.close();
			return null;
		}
	}

	/**
	 * Runs a program for its effect.
	 *
	 * @param cmd The program.
	 * @param args Its arguments.
	 * @return Whether it succeeded.
	 */
	static function run(cmd:String, args:Array<String>):Bool {
		var process:Process = null;

		try {
			process = new Process(cmd, args);
			var code:Int = process.exitCode();
			process.close();
			return code == 0;
		} catch (e:Dynamic) {
			if (process != null)
				process.close();
			return false;
		}
	}
}
#end
