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

/**
 * What an HL/C build has to add to itself to be able to compile scripts.
 *
 * Paths, not a command line, because the two things that consume this want different shapes: one
 * prints them for a build system that already exists, and the other runs a compiler with them.
 */
@:structInit class Recipe {
	/** Directories to add to the include path. */
	public var includes:Array<String>;

	/** C files to compile in, on top of whatever the program already compiles. */
	public var sources:Array<String>;

	/** What to add to the link, in the order it should be given. */
	public var links:Array<String>;

	/** Anything else the compiler needs to be told. */
	public var options:Array<String>;

	/**
	 * Whether the loader is part of this recipe.
	 *
	 * False on an architecture HashLink cannot jit for, where the recipe is a single small file and
	 * the program that comes out interprets every script rather than compiling any.
	 */
	public var loader:Bool;

	/** Where libhl and the import libraries live. */
	public var runtime:String;
}

/** What one look at this machine found out. */
enum Advice {
	/** It can be done, and this is what to do. */
	Ready(recipe:Recipe);

	/** It cannot, and this says what to do about it. */
	Missing(reason:String, remedy:String);
}

/**
 * Puts hxScript's runtime compiler into an **HL/C** program.
 *
 * HL/C is the other way to ship HashLink: `haxe -hl out.c` emits C that compiles to an ordinary
 * native binary with no VM process and no bytecode file. It is what a game with mod support on
 * desktop or Android is most likely to be built as.
 *
 * The difference from `Extension`, which produces `hxscript.hdll`, is only how the same C ends up in
 * the same process. There it is a shared library the VM loads by name when a module starts; here it
 * is compiled in and resolved by the linker, and Haxe's generated `natives.h` declares exactly the
 * symbols `hxscript.c` already defines, so the file itself is unchanged between the two.
 *
 * What follows from that is worth saying once: **an HL/C host decides at build time whether it can
 * compile scripts.** The `?` that makes the natives optional on HL/JIT has nothing to do here, since
 * a linked symbol either resolves or the link fails. A program that leaves this out is a program
 * that interprets, which is a decision rather than a fault.
 */
class Native {
	/**
	 * Works out what this machine can offer an HL/C build.
	 *
	 * @param carried The directory holding `hxscript.c`.
	 * @param jit Whether to include the loader. Null asks for it wherever it can work.
	 * @return What to add, or why nothing can be.
	 */
	public static function recipe(carried:String, ?jit:Null<Bool>):Advice {
		if (!FileSystem.exists(Path.join([carried, 'hxscript.c'])))
			return Missing('there is no hxscript.c at ' + carried, 'point this at the directory holding it');

		var runtime:Null<String> = Extension.machine();
		if (runtime == null)
			return Missing('no HashLink runtime was found', 'install HashLink, or set HLPATH to the directory holding libhl');

		var wanted:Bool = jit == null ? jits() : jit;

		if (!wanted) {
			var header:Null<String> = headers(runtime, null);
			if (header == null)
				return Missing('no hl.h was found', 'set HL_SRC to a hashlink source tree, or use a HashLink install that ships include/hl.h');

			return Ready({
				includes: [header, carried],
				sources: [Path.join([carried, 'hxscript.c'])],
				links: [],
				options: ['-DHXS_NO_JIT'],
				loader: false,
				runtime: runtime
			});
		}

		var sources:Null<String> = Extension.tree();
		if (sources == null)
			return Missing('no hashlink sources were found',
				'run hlc.sh or hlc.bat beside hxscript.c, which offers to fetch them, or set HL_SRC yourself');

		var mismatch:Null<String> = disagreement(sources, runtime);
		if (mismatch != null)
			return Missing(mismatch, 'point HL_SRC at a tree matching the HashLink you are linking against');

		var carriedSources:Array<String> = [Path.join([carried, 'hxscript.c'])];
		for (part in ['code.c', 'module.c', 'jit.c'])
			carriedSources.push(Path.join([sources, 'src', part]));

		return Ready({
			includes: [Path.join([sources, 'src']), carried],
			sources: carriedSources,
			links: [],
			options: [],
			loader: true,
			runtime: runtime
		});
	}

	/**
	 * Whether the machine being built for can run HashLink's jit.
	 *
	 * The same test `hxscript.c` makes for itself, asked here so that a recipe can say so before
	 * anything is compiled. It reads this machine, which is right for a native build and wrong for a
	 * cross-compile, so `jit` overrides it.
	 *
	 * @return Whether this looks like x86 or x86-64.
	 */
	static function jits():Bool {
		var arch:Null<String> = Sys.getEnv('PROCESSOR_ARCHITECTURE');
		if (arch != null)
			return arch.indexOf('ARM') < 0;

		var said:Null<String> = Extension.say('uname', ['-m']);
		if (said == null)
			return true;

		var machine:String = StringTools.trim(said).toLowerCase();
		return machine.indexOf('arm') < 0 && machine.indexOf('aarch') < 0;
	}

	/**
	 * Finds a directory holding `hl.h`.
	 *
	 * @param runtime Where libhl is, whose install may ship the headers beside it.
	 * @param sources A hashlink tree, or null when there is none.
	 * @return The directory, or null when neither has one.
	 */
	static function headers(runtime:String, sources:Null<String>):Null<String> {
		if (sources != null && FileSystem.exists(Path.join([sources, 'src/hl.h'])))
			return Path.join([sources, 'src']);

		var tree:Null<String> = Extension.tree();
		if (tree != null)
			return Path.join([tree, 'src']);

		for (near in [Path.join([runtime, 'include']), runtime]) {
			if (FileSystem.exists(Path.join([near, 'hl.h'])))
				return near;
		}

		return null;
	}

	/**
	 * @return Why a source tree does not match what is going to be linked, or null when it does.
	 *
	 * Different from the check the `.hdll` path makes, and better. That one asks `hl --version`,
	 * which needs a VM binary that an HL/C build has no other use for. A HashLink install ships
	 * `include/hl.h`, and that carries `HL_VERSION`, so the two headers can be compared directly.
	 * When the install ships none, the VM is asked as a second try, and when there is no VM either
	 * the check is skipped rather than guessed at.
	 */
	static function disagreement(sources:String, runtime:String):Null<String> {
		var declared:Null<String> = Extension.stamped(Path.join([sources, 'src/hl.h']));
		if (declared == null)
			return null;

		var shipped:Null<String> = Extension.stamped(Path.join([runtime, 'include/hl.h']));

		if (shipped == null) {
			var said:Null<String> = Extension.say(Path.join([runtime, Sys.systemName() == 'Windows' ? 'hl.exe' : 'hl']), ['--version']);
			if (said != null)
				shipped = StringTools.trim(said.split('\n')[0]);
		}

		if (shipped == null || shipped.length == 0 || shipped == declared)
			return null;

		return 'the sources at ' + sources + ' are hashlink ' + declared + ', and ' + runtime + ' is ' + shipped;
	}

	/**
	 * Writes a recipe out as compiler arguments.
	 *
	 * Only what hxScript adds. Whatever an HL/C build already needs to compile the C that Haxe wrote
	 * is that build's business and is not repeated here.
	 *
	 * @param recipe What to add.
	 * @return The arguments, in the order they should be given.
	 */
	public static function flags(recipe:Recipe):Array<String> {
		var out:Array<String> = [];

		for (option in recipe.options)
			out.push(option);

		for (dir in recipe.includes)
			out.push('-I' + dir);

		for (file in recipe.sources)
			out.push(file);

		for (link in recipe.links)
			out.push(link);

		return out;
	}

	/**
	 * Builds an HL/C program, hxScript and all.
	 *
	 * For someone with no native build of their own. Everything Haxe wrote is named in `hlc.json`
	 * beside it, including the libraries the program binds, so this reads that rather than being
	 * told twice.
	 *
	 * @param cdir The directory Haxe generated the C into.
	 * @param out Where the executable goes.
	 * @param recipe What hxScript adds.
	 * @param cc The compiler, or null to find one.
	 * @return What went wrong, or null when nothing did.
	 */
	public static function build(cdir:String, out:String, recipe:Recipe, ?cc:String):Null<String> {
		var manifest:String = Path.join([cdir, 'hlc.json']);
		if (!FileSystem.exists(manifest))
			return 'there is no hlc.json at ' + cdir + ', so this is not a directory Haxe generated HL/C into';

		var written:Dynamic = null;
		try {
			written = haxe.Json.parse(File.getContent(manifest));
		} catch (e:Dynamic) {
			return 'hlc.json at ' + cdir + ' could not be read';
		}

		if (cc == null)
			cc = Extension.compiler();
		if (cc == null)
			return 'no C compiler was found; set CC to one';

		var windows:Bool = Sys.systemName() == 'Windows';
		var args:Array<String> = ['-O2'];

		if (windows)
			args.push('-municode');

		args.push('-I' + cdir);

		for (dir in recipe.includes)
			args.push('-I' + dir);

		args.push('-o');
		args.push(out);

		var entry:Null<String> = mainFile(written);
		if (entry == null)
			return 'hlc.json at ' + cdir + ' names no files';

		args.push(Path.join([cdir, entry]));

		for (file in recipe.sources)
			args.push(file);

		for (link in libraries(written.libs, recipe.runtime, windows))
			args.push(link);

		for (link in recipe.links)
			args.push(link);

		if (windows) {
			args.push('-ldbghelp');
			args.push('-luser32');
			args.push('-lkernel32');
		}

		var into:String = Path.directory(out);
		if (into != null && into.length > 0 && !FileSystem.exists(into))
			FileSystem.createDirectory(into);

		return drive(cc, args);
	}

	/**
	 * @param written What `hlc.json` said.
	 * @return The one file to compile, or null when it named none.
	 *
	 * **One, not all of them.** Haxe writes a file per type and then a main file that `#include`s
	 * every one of them, unless `HL_MAKE` says it is being built the other way. So compiling the list
	 * as well as the main file defines everything twice, and the link fails on a few hundred
	 * duplicate symbols rather than on anything to do with hxScript.
	 *
	 * Separate compilation is the faster route on a machine with cores to spare and is what a real
	 * build system should do. This is the fallback for someone who has none, where one invocation
	 * that is certainly right beats several that have to be orchestrated.
	 */
	static function mainFile(written:Dynamic):Null<String> {
		var files:Array<String> = written.files;
		return files == null || files.length == 0 ? null : files[0];
	}

	/**
	 * Works out what to link for the libraries a generated program binds.
	 *
	 * `hlc.json` names them the way `@:hlNative` did, and a HashLink install ships an import library
	 * per `.hdll` beside it, so the two line up by name. Two never do: `std` is libhl itself, and
	 * `hxscript` is compiled in from source rather than linked against, which is what makes the
	 * result one binary with nothing to ship beside it.
	 *
	 * @param libs What the program binds.
	 * @param runtime Where the install is.
	 * @param windows Whether this is Windows, whose import libraries are named differently.
	 * @return What to add to the link.
	 */
	static function libraries(libs:Array<String>, runtime:String, windows:Bool):Array<String> {
		var out:Array<String> = [];

		if (windows) {
			out.push(Path.join([runtime, 'libhl.dll']));
		} else {
			out.push('-L' + runtime);
			out.push('-lhl');
		}

		if (libs == null)
			return out;

		for (lib in libs) {
			if (lib == 'std' || lib == 'hxscript')
				continue;

			if (windows) {
				var found:String = Path.join([runtime, lib + '.hdll']);
				if (FileSystem.exists(found))
					out.push(found);
			} else {
				out.push('-l' + lib);
			}
		}

		return out;
	}

	/**
	 * Runs the compiler and reads what it complained about.
	 *
	 * **Drained before it is waited on, and it has to be in that order.** A pipe holds a few tens of
	 * kilobytes, and a process that fills one blocks in `write` until somebody reads. Waiting for the
	 * exit code first is therefore a deadlock as soon as the compiler has more to say than the buffer
	 * holds, which a hundred and fifty translation units reliably do and the one file the `.hdll` is
	 * built from never does.
	 *
	 * @param cc The compiler.
	 * @param args Its arguments.
	 * @return What went wrong, or null when nothing did.
	 */
	static function drive(cc:String, args:Array<String>):Null<String> {
		var process:Process = null;

		try {
			process = new Process(cc, args);

			var complaint:String = process.stderr.readAll().toString();
			process.stdout.readAll();

			var code:Int = process.exitCode();
			process.close();

			if (code != 0)
				return StringTools.trim(complaint.split('\n').slice(0, 12).join('\n'));
		} catch (e:Dynamic) {
			if (process != null)
				process.close();
			return 'could not run ' + cc;
		}

		return null;
	}
}
#end
