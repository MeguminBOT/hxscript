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

#if macro
import haxe.io.Path;
import haxe.macro.Compiler;
import haxe.macro.Context;
import sys.FileSystem;
import sys.io.File;
import sys.io.Process;

/** What one attempt at the native module found out. */
enum Outcome {
	/** It is there and was built for this HashLink. Nothing was done. */
	Ready(path:String);

	/** It was built. */
	Built(path:String);

	/**
	 * It is there or was built, and it is the runtime and nothing else, because the carried loader
	 * is x86-64 only.
	 *
	 * Nothing is wrong and nothing would fix it, so this is a note rather than a warning: the
	 * program is the one it asked for, and every script in it is interpreted.
	 */
	Interprets(path:String, arch:String);

	/** Nothing was done, and this says why and what would change that. */
	Missing(reason:String, remedy:String);
}

/** What a build is for, as the compiler in front of it answers rather than as the machine looks. */
typedef Arch = {
	/** The architecture, as `hxs_arch.h` names it. */
	var name:String;

	/** Whether a loader can be compiled for it at all. */
	var jit:Bool;

	/**
	 * Whose jit it uses: `vendor` for the one hashlink ships, `arm64` for this library's own.
	 *
	 * The two supported architectures do not share a backend, because hashlink has none for arm64.
	 * Read out of `hxs_arch.h` through the probe rather than decided here, so the answer lives in one
	 * place.
	 */
	var backend:String;
}

/**
 * Builds hxScript's native module as part of a HashLink build, so a host that wants compiled scripts
 * does not have to know how.
 *
 * HashLink's bytecode loader is compiled into `hl.exe` rather than into `libhl`, so a program has no
 * way to reach it and the library carries hashlink's own `code.c`, `module.c` and `jit.c` beside its
 * own runtime. Those have to be compiled against the same hashlink the VM was built from, because
 * what they share with it is struct layouts rather than function names: a mismatched pair links
 * cleanly and then reads fields from the wrong offsets.
 *
 * Everything that can be worked out from this machine is. Nothing is fetched and nothing leaves the
 * machine. What is not here is one sentence naming what to install, never a failed build: the
 * natives are declared `?hxscript`, so a program with no module beside it starts exactly as it would
 * have and interprets every script.
 *
 * `-D hxscript_no_native` turns it off. `-D hxscript_native_out=<path>` asks for an HL/C program to
 * be linked there, which is the one thing not done unasked.
 */
class Native {
	/** What the carried loader was written against, as `hl.h` spells its own version. */
	static inline var CARRIED:Int = 0x011000;

	/**
	 * Builds the module for this build, if this is a build that wants one.
	 *
	 * Called from `Autowire`, so no build file has to name it. Runs after the target is generated,
	 * because an HL/C program is not there to be linked until then.
	 */
	public static function run():Void {
		if (!Context.defined('hl') || !Context.defined('hxscript_hl') || Context.defined('hxscript_no_native'))
			return;

		Context.onAfterGenerate(function():Void {
			report(ensure());
		});
	}

	/**
	 * Says what happened, once, and never fails the build.
	 *
	 * A missing module is a slower program rather than a broken one, so it is a warning with the
	 * thing to do about it. Silence on success unless asked, because a build that says nothing new
	 * is one nobody has to read.
	 *
	 * @param what The attempt's outcome.
	 */
	static function report(what:Outcome):Void {
		switch (what) {
			case Ready(path):
				hxscript.macro.Banner.note('native', path + ' is current');

			case Built(path):
				hxscript.macro.Banner.note('native', 'built ' + path);

			case Interprets(path, arch):
				hxscript.macro.Banner.note('native', 'built ' + path + ' for ' + arch + ', which has no loader, so every script will be interpreted');

			case Missing(reason, remedy):
				hxscript.macro.Banner.note('native', 'missing, so every script will be interpreted');
				Context.warning('hxscript: compiled scripts need a native module and '
					+ reason
					+ '\n'
					+ remedy
					+ '\n'
					+ 'Until then every script is interpreted, which is a slower program rather than a broken one.',
					Context.currentPos());
		}
	}

	/**
	 * Produces the module for whichever of the two HashLink outputs this build writes.
	 *
	 * @return What happened.
	 */
	static function ensure():Outcome {
		var out:String = Compiler.getOutput();
		var carried:String = beside();

		if (carried == null)
			return Missing('the library\'s own sources were not on the class path',
				'this is a fault in the build rather than in your machine; check that -lib hxscript resolves');

		var hl:Null<String> = installation();
		if (hl == null)
			return Missing('no HashLink installation was found',
				'set HLPATH to the directory holding hl.h and libhl, or put hl on the path');

		var headers:Null<String> = include(hl);
		if (headers == null)
			return Missing('the HashLink at ' + hl + ' has no hl.h',
				'point HLPATH at a binary distribution, which ships the headers beside the VM');

		var version:Null<Int> = versionOf(headers);
		if (version == null)
			return Missing('the hl.h at ' + headers + ' does not say which HashLink it is',
				'point HLPATH at a HashLink 1.16 binary distribution');

		if (version != CARRIED)
			return Missing('the HashLink at '
				+ hl
				+ ' is '
				+ spell(version)
				+ ' and the carried loader is for '
				+ spell(CARRIED),
				'install HashLink '
				+ spell(CARRIED)
				+ ', or build the module yourself against a matching source tree:\n'
				+ '  sh '
				+ Path.join([carried, 'build.sh'])
				+ ' --src <hashlink tree>');

		var cc:Null<String> = compiler();
		if (cc == null)
			return Missing('no C compiler was found', 'install one, or set CC to the one to use');

		var arch:Arch = architecture(cc, carried);

		return Path.extension(out) == 'c' ? program(out, carried, hl, headers, cc, version,
			arch) : library(out, carried, hl, headers, cc, version, arch);
	}

	/**
	 * Puts `hxscript.hdll` beside what the VM is going to run.
	 *
	 * Beside the output, because that is where HashLink looks for a library a program names, and a
	 * host should not have to move it there itself.
	 *
	 * @return What happened.
	 */
	static function library(out:String, carried:String, hl:String, headers:String, cc:String, version:Int, arch:Arch):Outcome {
		var into:String = Path.directory(out);
		if (into == '')
			into = '.';

		var target:String = Path.join([into, 'hxscript.hdll']);

		if (current(target, carried, version, arch))
			return arch.jit ? Ready(target) : Interprets(target, arch.name);

		if (!FileSystem.exists(into))
			FileSystem.createDirectory(into);

		/**
		 * `-fPIC` belongs to every shared library and is not optional anywhere it matters. On arm64
		 * Linux the linker refuses outright rather than producing something that does not load; on
		 * Windows it is meaningless and ignored, and on macOS clang already does it.
		 */
		var args:Array<String> = ['-shared', '-fPIC', '-fvisibility=hidden'];
		for (a in shared(carried, headers, arch))
			args.push(a);

		args.push('-L');
		args.push(hl);
		args.push('-lhl');

		/**
		 * The AArch64 jit calls `fmod` for the remainder of two floats, which is what hashlink's own
		 * jit does on x86 as well, so libm is not optional wherever that backend is compiled in. It is
		 * part of the C runtime on Windows and has no library to name there.
		 */
		if (!windows())
			args.push('-lm');

		/**
		 * Built under another name and renamed once whole, so an interrupted build cannot leave
		 * behind something that loads.
		 */
		var partial:String = target + '.building';
		var failed:Null<String> = invoke(cc, args, partial);

		if (failed != null) {
			tidy(partial);
			return Missing('the module did not compile', failed);
		}

		tidy(target);
		FileSystem.rename(partial, target);
		File.saveContent(target + '.built', Std.string(version) + ' ' + arch.name);

		return arch.jit ? Built(target) : Interprets(target, arch.name);
	}

	/**
	 * Links an HL/C program with the module compiled into it.
	 *
	 * There is nowhere to put a library in an HL/C build, so the module is the program or it is
	 * nothing. Nothing else produces this binary either: Haxe writes the C and the hashlink haxelib
	 * says native compilation is not implemented, so the choice is between a binary here and a
	 * directory of C nobody asked the host to compile.
	 *
	 * It takes the name of the C Haxe was told to write, so `-hl out/game.c` leaves `out/game`.
	 *
	 * @return What happened.
	 */
	static function program(out:String, carried:String, hl:String, headers:String, cc:String, version:Int, arch:Arch):Outcome {
		var told:Null<String> = Context.definedValue('hxscript_native_out');
		var target:String = told != null ? told : Path.withoutExtension(out) + (windows() ? '.exe' : '');

		var where:String = Path.directory(out);
		var entry:Null<String> = written(where);

		if (entry == null)
			return Missing('no hlc.json was written beside ' + out, 'this build did not produce HL/C after all');

		var args:Array<String> = ['-O2'];

		if (windows())
			args.push('-municode');

		for (a in shared(carried, headers, arch))
			args.push(a);

		args.push('-I');
		args.push(where);
		args.push(Path.join([where, entry]));

		for (a in binds(where, hl))
			args.push(a);

		var partial:String = target + '.building';
		var failed:Null<String> = invoke(cc, args, partial);

		if (failed != null) {
			tidy(partial);
			return Missing('the program did not link', failed);
		}

		tidy(target);
		FileSystem.rename(partial, target);

		return arch.jit ? Built(target) : Interprets(target, arch.name);
	}

	/**
	 * @return The arguments both outputs share: what to compile and what to compile it against.
	 */
	static function shared(carried:String, headers:String, arch:Arch):Array<String> {
		var vendor:String = Path.join([carried, 'vendor']);
		var loader:String = Path.join([vendor, 'hl116']);

		var args:Array<String> = [
			'-O3',
			'-std=c11',
			'-DHXS_NATIVE_TABLE',
			'-include',
			Path.join([vendor, 'hxs_vendor.h']),
			'-I',
			headers,
			'-I',
			loader,
			'-I',
			Path.join([carried, 'arm64']),
			Path.join([carried, 'hxs.c'])
		];

		/**
		 * Without the loader the module is the runtime and nothing else, which is what a host wants
		 * when it means to measure the interpreter inside a build that is otherwise the same.
		 *
		 * The define says what was asked for rather than what was worked out, so a module built for
		 * an architecture with no loader can still name that architecture when a host asks it why.
		 */
		if (Context.defined('hxscript_no_jit')) {
			args.push('-DHXS_NO_JIT');
			return args;
		}

		if (!arch.jit)
			return args;

		/**
		 * `code.c` reads a module and `module.c` links it, and neither has an architecture in it, so
		 * both are shared whatever the backend. Only `jit.c` is replaced, because only `jit.c` is an
		 * x86 encoder: its own guard is `__arm__`, which 64 bit ARM does not define, so compiling it
		 * on arm64 is not dead weight but working code that emits instructions the processor cannot
		 * run.
		 */
		for (name in ['code.c', 'module.c'])
			args.push(Path.join([loader, name]));

		if (arch.backend == 'arm64') {
			args.push(Path.join([carried, 'arm64', 'jit_arm64.c']));
			args.push(Path.join([carried, 'arm64', 'exec.c']));
		} else {
			args.push(Path.join([loader, 'jit.c']));
		}

		return args;
	}

	/**
	 * What an HL/C program has to be linked against, read out of the hlc.json Haxe wrote rather than
	 * listed here, because a list kept by hand is wrong the moment the program's imports change.
	 *
	 * @param where The directory Haxe wrote the C into.
	 * @param hl The HashLink installation.
	 * @return The linker arguments.
	 */
	static function binds(where:String, hl:String):Array<String> {
		var args:Array<String> = [];

		if (windows()) {
			args.push(Path.join([hl, 'libhl.dll']));
		} else {
			args.push('-L' + hl);
			args.push('-L' + Path.join([hl, 'lib']));
			args.push('-lhl');
		}

		for (lib in libraries(where)) {
			/** std is libhl itself, and hxscript is this module, which is compiled in rather than linked. */
			if (lib == 'std' || lib == 'hxscript')
				continue;

			if (windows()) {
				var hdll:String = Path.join([hl, lib + '.hdll']);
				if (FileSystem.exists(hdll))
					args.push(hdll);
			} else {
				args.push('-l' + lib);
			}
		}

		if (windows()) {
			args.push('-ldbghelp');
			args.push('-luser32');
			args.push('-lkernel32');
		} else {
			args.push('-lm');
			args.push('-lpthread');
		}

		return args;
	}

	/**
	 * @param where The directory Haxe wrote the C into.
	 * @return The one file to compile, which includes every other, or null when there is no hlc.json.
	 *
	 * Haxe writes a file per type and then a main file that includes all of them, so compiling the
	 * list as well would define everything twice.
	 */
	static function written(where:String):Null<String> {
		var manifest:String = Path.join([where, 'hlc.json']);

		if (!FileSystem.exists(manifest))
			return null;

		var found:Array<String> = strings(File.getContent(manifest), 'files');
		for (name in found)
			if (Path.extension(name) == 'c')
				return name;

		return null;
	}

	/** @return The libraries an HL/C program binds, as hlc.json names them. */
	static function libraries(where:String):Array<String> {
		var manifest:String = Path.join([where, 'hlc.json']);
		return FileSystem.exists(manifest) ? strings(File.getContent(manifest), 'libs') : [];
	}

	/**
	 * Reads one array of strings out of hlc.json.
	 *
	 * By hand rather than through a JSON parser, because this runs inside the compiler and every
	 * dependency it takes is one every build of every host takes with it. The shape is fixed and
	 * written by Haxe, so what would be gained by parsing it properly is not gained here.
	 *
	 * @param json The file's contents.
	 * @param key The array to read.
	 * @return Its entries, in order.
	 */
	static function strings(json:String, key:String):Array<String> {
		var at:Int = json.indexOf('"' + key + '"');
		if (at < 0)
			return [];

		var open:Int = json.indexOf('[', at);
		var close:Int = json.indexOf(']', open);

		if (open < 0 || close < 0)
			return [];

		var out:Array<String> = [];
		var body:String = json.substring(open + 1, close);
		var quote:Int = body.indexOf('"');

		while (quote >= 0) {
			var end:Int = body.indexOf('"', quote + 1);
			if (end < 0)
				break;

			out.push(body.substring(quote + 1, end));
			quote = body.indexOf('"', end + 1);
		}

		return out;
	}

	/**
	 * @return Whether a built module is there and was built for this HashLink.
	 *
	 * The version is the part that matters. An upgraded VM leaves a module whose timestamp says it is
	 * current and whose struct layouts no longer are, which is the mismatch all of this exists to
	 * avoid, so what it was built for is written down beside it and compared rather than inferred.
	 *
	 * The architecture is written down for the same reason and reads the same way. A tree built for
	 * one and then for another leaves a module that is neither newer nor wrong to look at, and that
	 * cannot be loaded by what is about to run.
	 */
	static function current(target:String, carried:String, version:Int, arch:Arch):Bool {
		if (!FileSystem.exists(target))
			return false;

		var note:String = target + '.built';
		if (!FileSystem.exists(note) || StringTools.trim(File.getContent(note)) != Std.string(version) + ' ' + arch.name)
			return false;

		var glue:String = Path.join([carried, 'hxs.c']);
		if (!FileSystem.exists(glue))
			return true;

		return FileSystem.stat(target).mtime.getTime() >= FileSystem.stat(glue).mtime.getTime();
	}

	/** @return The directory holding the module's own sources, or null when they are not reachable. */
	static function beside():Null<String> {
		try {
			return Path.directory(Context.resolvePath('hxscript/hl/native/hxs.c'));
		} catch (e:Dynamic) {
			return null;
		}
	}

	/**
	 * Finds the HashLink to build against.
	 *
	 * `HLPATH` is hashlink's own convention and is tried first, then what `hl` on the path resolves
	 * to, then where the installers put it.
	 *
	 * @return The directory, or null when there is no HashLink here.
	 */
	static function installation():Null<String> {
		var told:Null<String> = Sys.getEnv('HLPATH');
		if (told != null && include(told) != null)
			return told;

		var found:Null<String> = onPath(windows() ? 'hl.exe' : 'hl');
		if (found != null) {
			var beside:String = Path.directory(found);
			if (include(beside) != null)
				return beside;
		}

		var guesses:Array<String> = windows() ? ['C:/hashlink', 'C:/Program Files/HashLink'] : ['/usr/local', '/usr', '/opt/hashlink'];

		var home:Null<String> = Sys.getEnv('HOME');
		if (home != null)
			guesses.push(Path.join([home, 'hashlink']));

		for (guess in guesses) {
			if (include(guess) != null)
				return guess;

			/** One level down, because the binary distributions unpack into a versioned directory. */
			if (!FileSystem.exists(guess) || !FileSystem.isDirectory(guess))
				continue;

			for (entry in FileSystem.readDirectory(guess)) {
				var inside:String = Path.join([guess, entry]);
				if (FileSystem.isDirectory(inside) && include(inside) != null)
					return inside;
			}
		}

		return null;
	}

	/** @return The directory holding `hl.h` under an installation, or null when there is none. */
	static function include(hl:String):Null<String> {
		for (where in [Path.join([hl, 'include']), hl]) {
			if (FileSystem.exists(Path.join([where, 'hl.h'])))
				return where;
		}

		return null;
	}

	/**
	 * @param headers The directory holding `hl.h`.
	 * @return The HashLink it belongs to, as it spells its own version, or null when it does not say.
	 *
	 * Read out of the header rather than asked of the VM, because the header is what the module is
	 * compiled against and a machine may have more than one HashLink on it.
	 */
	static function versionOf(headers:String):Null<Int> {
		var said:String = File.getContent(Path.join([headers, 'hl.h']));
		var at:Int = said.indexOf('#define HL_VERSION');

		if (at < 0)
			return null;

		var line:String = said.substring(at, said.indexOf('\n', at));
		var digits:EReg = ~/0x([0-9A-Fa-f]+)/;

		if (!digits.match(line))
			return null;

		return Std.parseInt('0x' + digits.matched(1));
	}

	/**
	 * @param packed A version as hl.h spells it.
	 * @return It as hashlink tags them.
	 */
	static function spell(packed:Int):String {
		return ((packed >> 16) & 0xFF) + '.' + ((packed >> 8) & 0xFF) + '.' + (packed & 0xFF);
	}

	/**
	 * @return The C compiler to use, or null when there is none here.
	 *
	 * What `CC` names is checked for being there rather than taken on trust, so a stale one in the
	 * environment reads as no compiler and says which thing to fix, instead of arriving later as
	 * whatever the operating system says about a program it could not start.
	 */
	static function compiler():Null<String> {
		var told:Null<String> = Sys.getEnv('CC');

		if (told != null && told != '')
			return runnable(told) ? told : null;

		for (name in ['clang', 'gcc', 'cc', 'x86_64-w64-mingw32-gcc'])
			if (runnable(name))
				return name;

		return null;
	}

	/**
	 * Asks the compiler which architecture it is about to build for.
	 *
	 * The compiler rather than the machine, because a cross build is for whatever it targets and a
	 * machine that is compiling is not always the machine that will run it. The question is put by
	 * preprocessing `hxs_arch_probe.c`, which includes the same `hxs_arch.h` that `hxs.c` includes,
	 * so what is decided here and what the module compiles with are one chain read twice rather than
	 * two lists that can drift apart.
	 *
	 * @param cc The compiler.
	 * @param carried The directory holding the module's own sources.
	 * @return What it is building for.
	 *
	 * A compiler that will not answer is taken to be building for x86-64, which is what this assumed
	 * before it asked. Where there is a loader that keeps it, and where there is not the loader
	 * fails to compile and says so, rather than quietly going missing on a machine that could have
	 * had it.
	 */
	static function architecture(cc:String, carried:String):Arch {
		var said:Null<String> = ask(cc, ['-E', Path.join([carried, 'hxs_arch_probe.c'])]);

		if (said != null) {
			for (line in said.split('\n')) {
				var at:Int = line.indexOf('hxs_arch "');
				if (at < 0)
					continue;

				var rest:String = line.substr(at + 10);
				var end:Int = rest.indexOf('"');

				if (end < 0)
					continue;

				var tail:String = StringTools.trim(rest.substr(end + 1));
				var open:Int = tail.indexOf('"');
				var close:Int = open < 0 ? -1 : tail.indexOf('"', open + 1);

				return {
					name: rest.substring(0, end),
					jit: tail.charAt(0) == '1',
					backend: open >= 0 && close > open ? tail.substring(open + 1, close) : 'vendor'
				};
			}
		}

		return {name: 'x86-64', jit: true, backend: 'vendor'};
	}

	/**
	 * @param name A program.
	 * @return Whether it is here to be run, by path or by name.
	 */
	static function runnable(name:String):Bool {
		if (name.indexOf('/') >= 0 || name.indexOf('\\') >= 0)
			return FileSystem.exists(name);

		return onPath(name) != null || (windows() && onPath(name + '.exe') != null);
	}

	/**
	 * @param name An executable.
	 * @return Where it is, or null when it is not on the path.
	 */
	static function onPath(name:String):Null<String> {
		var path:Null<String> = Sys.getEnv('PATH');
		if (path == null)
			return null;

		for (entry in path.split(windows() ? ';' : ':')) {
			if (entry == '')
				continue;

			var candidate:String = Path.join([entry, name]);
			if (FileSystem.exists(candidate) && !FileSystem.isDirectory(candidate))
				return candidate;
		}

		return null;
	}

	/**
	 * Runs the compiler.
	 *
	 * @param cc The compiler.
	 * @param args What to compile, and against what.
	 * @param out Where to put the result.
	 * @return What it said when it refused, or null when it worked.
	 */
	static function invoke(cc:String, args:Array<String>, out:String):Null<String> {
		var whole:Array<String> = args.copy();
		whole.push('-o');
		whole.push(out);

		if (Context.defined('hxscript_verbose'))
			Context.info('hxscript: ' + cc + ' ' + whole.join(' '), Context.currentPos());

		try {
			var run:Process = new Process(cc, whole);
			var said:String = run.stderr.readAll().toString();
			var code:Int = run.exitCode();
			run.close();

			return code == 0 ? null : StringTools.trim(said);
		} catch (e:Dynamic) {
			return cc + ' would not run: ' + Std.string(e);
		}
	}

	/**
	 * Runs the compiler and reads what it wrote, for the one thing that is asked of it rather than
	 * compiled by it.
	 *
	 * @param cc The compiler.
	 * @param args What to ask.
	 * @return What it wrote, or null when it would not run or would not answer.
	 */
	static function ask(cc:String, args:Array<String>):Null<String> {
		try {
			var run:Process = new Process(cc, args);
			var said:String = run.stdout.readAll().toString();
			var code:Int = run.exitCode();
			run.close();

			return code == 0 ? said : null;
		} catch (e:Dynamic) {
			return null;
		}
	}

	/** Removes a file if it is there, so a rename onto it can succeed. */
	static function tidy(path:String):Void {
		if (FileSystem.exists(path))
			try
				FileSystem.deleteFile(path)
			catch (e:Dynamic) {}
	}

	/** @return Whether this is a Windows machine, which changes how a program is linked. */
	static function windows():Bool {
		return Sys.systemName() == 'Windows';
	}
}
#end
