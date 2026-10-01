package hxscript.lib.flixel;

#if macro
import haxe.io.Path;
import haxe.macro.Compiler;
import haxe.macro.Context;
import sys.FileSystem;
import sys.io.File;

using StringTools;

/**
 * Turns on flixel's debugger console, watch expressions and console completion with hxScript where
 * flixel expects hscript.
 *
 * flixel compiles all three only under `#if hscript`, and says the console needs hscript otherwise.
 * Defining `hscript` would also switch on code in other libraries (haxeui's `calc()`, heaps' shader
 * reload) that needs the real hscript, so the define is left alone. Instead the six flixel modules
 * that test it are copied with the test read as `hxscript`, the two hscript imports pointed at
 * hxScript's parser and syntax tree, and the console's interpreter rebased on hxScript's, and the
 * copies go ahead of flixel on the classpath.
 *
 * Every edit has to find exactly what it expects, in every module, or nothing is copied: a flixel
 * laid out differently keeps its console off, as it is without hscript today, rather than failing to
 * build. A host with the real hscript, or `-D hxscript_no_flixel_console`, is left as it is.
 */
class FlixelConsole {
	/** The modules that test `hscript`. */
	static var MODULES:Array<String> = [
		'flixel.system.debug.console.Console',
		'flixel.system.debug.console.ConsoleUtil',
		'flixel.system.debug.completion.CompletionHandler',
		'flixel.system.debug.watch.WatchEntry',
		'flixel.system.debug.watch.WatchEntryData',
		'flixel.system.frontEnds.WatchFrontEnd'
	];

	/**
	 * Writes the copies and puts them on the classpath.
	 *
	 * Runs as an init macro, before anything parses the modules, because a module flixel's own copy
	 * of has already been loaded is not looked up again.
	 */
	public static function run():Void {
		if (!Context.defined('flixel') || Context.defined('hscript') || Context.defined('hxscript_no_flixel_console'))
			return;

		var copies:Array<{relative:String, text:String}> = [];

		for (module in MODULES) {
			var relative:String = module.split('.').join('/') + '.hx';
			var source:Null<String> = try Context.resolvePath(relative) catch (e:Dynamic) null;

			if (source == null) {
				skip(module + ' is not on the classpath');
				return;
			}

			var text:Null<String> = rewrite(module, File.getContent(source));

			if (text == null) {
				skip(module + ' is not laid out as this expects');
				return;
			}

			copies.push({relative: relative, text: text});
		}

		var root:String = Path.join([outputDirectory(), '.hxscript', 'flixel']);

		for (copy in copies)
			write(Path.join([root, copy.relative]), copy.text);

		Compiler.addClassPath(root);

		if (Context.defined('hxscript_verbose'))
			Context.info('hxscript: flixel console runs on hxScript, from ' + root, Context.currentPos());
	}

	/**
	 * @param module The module's path.
	 * @param text Its source.
	 * @return The source with hxScript where it had hscript, or null when an edit did not find what it
	 *         expects.
	 */
	static function rewrite(module:String, text:String):Null<String> {
		var gate:EReg = ~/#if hscript\b/g;
		if (!gate.match(text))
			return null;

		text = gate.replace(text, '#if hxscript');

		switch (module) {
			case 'flixel.system.debug.console.ConsoleUtil':
				text = once(text, 'import hscript.Expr;', 'import hxscript.syntax.Expr;');
				text = once(text, 'import hscript.Parser;', 'import hxscript.syntax.Parser;');
				text = once(text, 'parser.parseString(', 'parser.parseScript(');
				text = once(text, 'extends hscript.Interp', 'extends hxscript.runtime.Interp');

				/**
				 * flixel overrides these because hscript reads and writes fields without their
				 * accessors. hxScript's own go through `Reflect.getProperty` and `setProperty`, and take
				 * an extra argument, so the overrides would no longer compile.
				 */
				text = withoutMethod(text, 'override function get(o:Dynamic, f:String):Dynamic');
				text = withoutMethod(text, 'override function set(o:Dynamic, f:String, v:Dynamic):Dynamic');

			case 'flixel.system.debug.watch.WatchEntryData':
				text = once(text, 'import hscript.Expr;', 'import hxscript.syntax.Expr;');

			default:
		}

		/**
		 * Anything still naming the hscript package would not resolve. Docstrings mention hscript in
		 * plain sentences, so only a name followed by a member counts.
		 */
		if (text == null || ~/\bhscript\.[A-Za-z_]/.match(text))
			return null;

		return text;
	}

	/**
	 * @param text A source, or null once an earlier edit failed.
	 * @param from Text that has to occur exactly once.
	 * @param to Its replacement.
	 * @return The source with it replaced, or null.
	 */
	static function once(text:Null<String>, from:String, to:String):Null<String> {
		if (text == null)
			return null;

		var at:Int = text.indexOf(from);
		if (at < 0 || text.indexOf(from, at + from.length) >= 0)
			return null;

		return text.substr(0, at) + to + text.substr(at + from.length);
	}

	/**
	 * Removes a method, its line and the blank line before it, by matching braces from its signature.
	 *
	 * @param text A source, or null once an earlier edit failed.
	 * @param signature The method's signature, which has to occur exactly once.
	 * @return The source without it, or null.
	 */
	static function withoutMethod(text:Null<String>, signature:String):Null<String> {
		if (text == null)
			return null;

		var at:Int = text.indexOf(signature);
		if (at < 0 || text.indexOf(signature, at + signature.length) >= 0)
			return null;

		var open:Int = text.indexOf('{', at + signature.length);
		if (open < 0)
			return null;

		var depth:Int = 0;
		var end:Int = -1;

		for (i in open...text.length) {
			switch (text.charAt(i)) {
				case '{':
					depth++;
				case '}':
					depth--;
					if (depth == 0) {
						end = i + 1;
						break;
					}
				default:
			}
		}

		if (end < 0)
			return null;

		var start:Int = text.lastIndexOf('\n', at) + 1;
		if (start > 1) {
			var before:Int = text.lastIndexOf('\n', start - 2) + 1;
			if (text.substring(before, start).trim() == '')
				start = before;
		}

		if (text.charAt(end) == '\r')
			end++;
		if (text.charAt(end) == '\n')
			end++;

		return text.substr(0, start) + text.substr(end);
	}

	/**
	 * @return The directory the build writes to, which is where the copies go, so that each project
	 *         keeps its own beside its own output.
	 */
	static function outputDirectory():String {
		var output:String = Compiler.getOutput();

		if (output == null || output == '')
			return Sys.getCwd();

		if (Path.extension(output) != '')
			output = Path.directory(output);

		return FileSystem.absolutePath(output == '' ? '.' : output);
	}

	/**
	 * Writes a copy only when it differs, so an unchanged copy keeps its timestamp and a compilation
	 * server does not parse it again.
	 *
	 * @param path Where it goes.
	 * @param text What it holds.
	 */
	static function write(path:String, text:String):Void {
		if (FileSystem.exists(path) && File.getContent(path) == text)
			return;

		FileSystem.createDirectory(Path.directory(path));
		File.saveContent(path, text);
	}

	/** @param reason Why flixel's own modules are kept. */
	static function skip(reason:String):Void {
		if (Context.defined('hxscript_verbose'))
			Context.info('hxscript: flixel console left as it is: ' + reason, Context.currentPos());
	}
}
#end
