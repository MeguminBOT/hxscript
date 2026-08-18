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

package hxscript.macro;

#if macro
import haxe.macro.Context;
import sys.io.File;

/**
 * What a build says about hxScript being in it.
 *
 * Wired in from `extraParams.hxml`, so `-lib hxscript` is the whole of the setup and there is
 * nothing to add to a build file.
 *
 * **It is one block, printed once, and it is mostly facts rather than decoration.** A library that
 * wires itself in has to say what it wired, because the alternative is a build that silently did
 * four things and a user who finds out which by reading the source. The mark is at the top so the
 * block is findable in a long log; the lines under it are what this build can actually do, and every
 * one of them has been a question somebody asked: which target, whether scripts will be compiled or
 * interpreted, which game library was detected, and how much of it a script can reach.
 *
 * `-D hxscript_no_banner`, or `HXSCRIPT_NO_BANNER=1` in the environment, prints nothing at all.
 * `NO_COLOR` keeps the block and drops the escapes, which is the convention CI logs expect.
 * `-D hxscript_verbose` is unaffected and still prints the per-item detail underneath.
 */
class Banner {
	/** Whether the mark has been printed, so a macro context that runs twice prints once. */
	static var marked:Bool = false;

	/** Whether anything at all has been printed, which decides if the trailer needs a blank line. */
	static var opened:Bool = false;

	/** The library's own version, read once from `haxelib.json`. */
	static var version:Null<String> = null;

	static var LOGO:Array<String> = [
		'      _                             _         _   ',
		'     | |__  __  __ ___   ___  _ __ (_) _ __  | |_ ',
		'     | \'_ \\ \\ \\/ // __| / __|| \'__|| || \'_ \\ | __|',
		'     | | | | >  < \\__ \\| (__ | |   | || |_) || |_ ',
		'     |_| |_|/_/\\_\\|___/ \\___||_|   |_|| .__/  \\__|',
		'                                      |_|         '
	];

	/**
	 * Prints the mark and what this build is.
	 *
	 * Called from `extraParams.hxml` rather than from the setup, so a build that turned the setup off
	 * with `-D hxscript_no_autowire` still says the library is in it.
	 */
	public static function show():Void {
		if (marked || quiet())
			return;

		marked = true;
		opened = true;

		var target:String = targetName();

		for (line in LOGO)
			say(paint(line, colourFor(target)));

		line('hxscript', release() + '   ' + target + '   ' + backend());
	}

	/**
	 * Prints what the setup wired in.
	 *
	 * Called by `Autowire` once it knows, which is the only moment the numbers exist: the libraries
	 * are decided by what else is in the build, and the counts are the result of resolving them.
	 *
	 * @param libraries The game libraries detected, by title.
	 * @param bridges How many scriptable bases were bridged.
	 * @param types How many modules were forced in so a script can name them.
	 * @param abstracts How many abstracts were given a runtime form.
	 * @param globals How many types a script reaches without importing them, which no shipped preset
	 *        offers and so is normally zero.
	 */
	public static function wired(libraries:Array<String>, bridges:Int, types:Int, abstracts:Int, globals:Int):Void {
		if (quiet())
			return;

		/**
		 * The library's own preset is not a detection. It is in every build by definition, and a line
		 * saying hxscript wired hxscript is a line nobody learns anything from.
		 */
		var detected:Array<String> = [];

		for (title in libraries)
			if (title != 'hxscript')
				detected.push(title);

		line('wired', detected.length == 0 ? 'no game library detected, the interpreter alone' : detected.join(', '));

		var reach:String = '$types type(s), $abstracts abstract(s), $bridges bridge(s)';

		/**
		 * The offer is only worth a word when there is one. No shipped preset offers a name, so on
		 * almost every build this would read `0 offered global(s)` and invite the reader to wonder what
		 * they had turned off.
		 */
		if (globals > 0)
			reach += ', $globals offered global(s)';

		line('reach', reach);
	}

	/**
	 * Prints one more line under the block, for a step that finishes later than the rest.
	 *
	 * The native module is the one that does: it is produced after the target is generated, because
	 * an HL/C program is not there to be linked until then.
	 *
	 * @param label The line's name.
	 * @param text What to say.
	 */
	public static function note(label:String, text:String):Void {
		if (quiet())
			return;

		line(label, text);
	}

	/** @return Whether this build wants nothing printed. */
	static function quiet():Bool {
		/**
		 * A completion request is a build too, and it runs on every keystroke. Printing there puts the
		 * mark into whatever the editor is parsing, which at best is noise and at worst is a response
		 * the editor cannot read.
		 */
		if (Context.defined('display') || Context.defined('display_details'))
			return true;

		return Context.defined('hxscript_no_banner') || Sys.getEnv('HXSCRIPT_NO_BANNER') != null;
	}

	/**
	 * @param label The line's name, padded so the values line up.
	 * @param text What to say.
	 */
	static function line(label:String, text:String):Void {
		var padded:String = label;

		while (padded.length < 8)
			padded += ' ';

		say('     ' + paint(padded, DIM) + ' ' + text);
	}

	/** Writes a line where the compiler's own messages go, without a position in front of it. */
	static function say(text:String):Void {
		try {
			Sys.stderr().writeString(text + '\n');
		} catch (e:Dynamic) {}
	}

	/** The escape a colour needs, or nothing when this terminal was asked to do without. */
	static inline var DIM:String = '2';

	/**
	 * @param text What to colour.
	 * @param code The SGR parameter.
	 * @return It wrapped, or unchanged where colour is unwanted.
	 */
	static function paint(text:String, code:String):String {
		if (Sys.getEnv('NO_COLOR') != null)
			return text;

		return '\x1b[' + code + 'm' + text + '\x1b[0m';
	}

	/**
	 * @param target What this build targets.
	 * @return The colour to draw the mark in.
	 */
	static function colourFor(target:String):String {
		return switch (target) {
			case 'hxcpp': '36';
			case 'hashlink': '35';
			case 'javascript': '33';
			case 'neko': '32';
			case 'jvm', 'java': '31';
			case 'c#': '34';
			case 'python': '32';
			case 'php': '35';
			case 'lua': '34';
			case _: '37';
		}
	}

	/** @return What this build targets, as somebody would say it rather than as a define spells it. */
	static function targetName():String {
		return if (Context.defined('cpp')) 'hxcpp'; else if (Context.defined('hl')) 'hashlink'; else
			if (Context.defined('js')) 'javascript'; else if (Context.defined('neko')) 'neko'; else
				if (Context.defined('jvm')) 'jvm'; else if (Context.defined('java')) 'java'; else
					if (Context.defined('cs')) 'c#'; else if (Context.defined('python')) 'python'; else
						if (Context.defined('lua')) 'lua'; else if (Context.defined('php')) 'php'; else
							if (Context.defined('flash')) 'flash'; else if (Context.defined('eval')) 'eval'; else
								'unknown';
	}

	/**
	 * @return Which of the two things a script will be in this build.
	 *
	 * The single most useful line here. A compiled backend is opt-in on both targets that have one,
	 * and a build that meant to have one and does not is a program running scripts at a fraction of
	 * the speed it was measured at, with nothing anywhere saying so.
	 */
	static function backend():String {
		if (Context.defined('hxscript_cppia'))
			return Context.defined('cpp') ? 'cppia compiler' : 'cppia asked for, and this is not hxcpp';

		if (Context.defined('hxscript_hl'))
			return Context.defined('hl') ? 'HashLink bytecode compiler' : 'HashLink asked for, and this is not hl';

		if (Context.defined('cpp'))
			return 'interpreter only, add -D hxscript_cppia to compile scripts';

		if (Context.defined('hl'))
			return 'interpreter only, add -D hxscript_hl to compile scripts';

		return 'interpreter';
	}

	/** @return The library's version, or an empty string when `haxelib.json` could not be read. */
	static function release():String {
		if (version != null)
			return version;

		version = '';

		try {
			var here:String = Context.resolvePath('hxscript/macro/Banner.hx');
			var root:String = haxe.io.Path.directory(haxe.io.Path.directory(haxe.io.Path.directory(haxe.io.Path.directory(here))));
			var json:Dynamic = haxe.Json.parse(File.getContent(haxe.io.Path.join([root, 'haxelib.json'])));
			var named:Dynamic = Reflect.field(json, 'version');

			if (named != null)
				version = Std.string(named);
		} catch (e:Dynamic) {}

		return version;
	}
}
#end
