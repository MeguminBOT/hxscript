package hxscript.macro;

#if macro
import haxe.Json;
import haxe.macro.Context;
import sys.FileSystem;
import sys.io.File;
import sys.io.Process;

/**
 * Which C++ runtime a build links, libhxcpp or hxcpp, and what is said when it is not libhxcpp.
 *
 * hxScript is built and tested against [libhxcpp](https://github.com/openfl/libhxcpp), the
 * continuation of hxcpp. It carries the cppia fixes that compiled scripts rely on to agree with the
 * same script interpreted (issues 1, 2, 3 and 7 of `HXCPP-ISSUES.md`, and more), so it is what this
 * library asks for on hxcpp builds.
 *
 * **hxcpp is still allowed.** A build against it is not stopped: it gets one warning naming what
 * it misses and how to install libhxcpp, and goes on. `-D hxscript_allow_hxcpp` says the fallback is
 * meant and silences the warning; `-D hxscript_require_libhxcpp` turns it into an error, for a CI
 * that must not ship against hxcpp by accident.
 *
 * It is a check rather than a haxelib dependency because a dependency cannot fall back: haxelib
 * refuses `-lib hxscript` outright when a dependency is not installed, and it would put libhxcpp's
 * class path and defines into HashLink, JavaScript and every other build that never links a C++
 * runtime at all.
 *
 * Wired in from `extraParams.hxml`. Builds for any other target are not looked at.
 */
class Runtime {
	/** Whether the warning has been given, so a macro context that runs twice gives it once. */
	static var checked:Bool = false;

	/** Whether `detect` has run. */
	static var detected:Bool = false;

	/** The haxelib the build links as its C++ runtime, `libhxcpp` or `hxcpp`, null when unknown. */
	static var library:Null<String> = null;

	/** That library's version, null when unknown. */
	static var version:Null<String> = null;

	/**
	 * Checks the runtime of an hxcpp build and warns, or with `-D hxscript_require_libhxcpp` stops,
	 * when it is not libhxcpp.
	 */
	public static function check():Void {
		if (checked || !Context.defined('cpp'))
			return;

		checked = true;
		detect();

		if (library == 'libhxcpp')
			return;

		var required:Bool = Context.defined('hxscript_require_libhxcpp');
		if (!required && Context.defined('hxscript_allow_hxcpp'))
			return;

		var linked:String = library == null ? 'a C++ runtime haxelib could not name' : (version == null ? library : '$library $version');
		var affects:String = Context.defined('hxscript_cppia')
			? 'compiled scripts can disagree with the same script interpreted, or end the process'
			: 'a later -D hxscript_cppia would compile scripts on a runtime with known cppia faults';

		var message:String = 'hxscript: this build links $linked, not libhxcpp. hxScript is built and tested against '
			+ 'libhxcpp, which carries the cppia fixes listed in HXCPP-ISSUES.md; without them $affects. '
			+ 'Install it with `haxelib install libhxcpp` then `haxelib run libhxcpp setup`. ';

		if (required) {
			Context.error(message + '-D hxscript_require_libhxcpp is set, so the build stops here.', Context.currentPos());
			return;
		}

		Context.warning(message + 'Falling back to hxcpp; -D hxscript_allow_hxcpp says that is intended and silences this.',
			Context.currentPos());
	}

	/**
	 * @return The runtime for the banner, such as `libhxcpp 6.0.0` or `hxcpp 4.3.0, fallback`, or
	 *         null for a build that is not hxcpp.
	 */
	public static function describe():Null<String> {
		if (!Context.defined('cpp'))
			return null;

		detect();

		if (library == null)
			return 'C++ runtime unknown';

		var named:String = version == null ? library : '$library $version';
		return library == 'libhxcpp' ? named : '$named, fallback (libhxcpp is what hxScript is tested against)';
	}

	/**
	 * Works out which haxelib the build links as its C++ runtime.
	 *
	 * A build with `-lib hxcpp` or `-lib libhxcpp` says so in its defines: libhxcpp sets both `hxcpp`
	 * and `libhxcpp`, hxcpp only the first. A build without either, which is most of them since the
	 * compiler adds neither, finds its build tool the way the compiler does, as the haxelib called
	 * `hxcpp`, and libhxcpp's setup points that name at itself. So haxelib is asked where `hxcpp` is,
	 * from the directory the compiler runs in so a project's local repository counts, and the
	 * library found there says what it is in its `haxelib.json`.
	 */
	static function detect():Void {
		if (detected)
			return;

		detected = true;

		if (Context.defined('libhxcpp')) {
			library = 'libhxcpp';
			version = Context.definedValue('libhxcpp');
			return;
		}

		if (Context.defined('hxcpp')) {
			library = 'hxcpp';
			version = Context.definedValue('hxcpp');
			return;
		}

		var root:Null<String> = haxelibPath('hxcpp');
		if (root == null)
			return;

		var info:Dynamic = readJson(root + '/haxelib.json');
		if (info == null)
			return;

		library = Std.string(info.name) == 'libhxcpp' ? 'libhxcpp' : 'hxcpp';
		version = info.version == null ? null : Std.string(info.version);
	}

	/**
	 * @param name A haxelib.
	 * @return The folder `haxelib libpath` gives for it, or null when haxelib cannot say.
	 */
	static function haxelibPath(name:String):Null<String> {
		try {
			var process:Process = new Process('haxelib', ['libpath', name]);
			var out:String = process.stdout.readAll().toString();
			var code:Int = process.exitCode();
			process.close();

			if (code != 0)
				return null;

			for (line in out.split('\n')) {
				var path:String = StringTools.trim(line);
				if (path.length > 0 && FileSystem.exists(path) && FileSystem.isDirectory(path))
					return path;
			}
		} catch (e:Dynamic) {}

		return null;
	}

	/** @return The parsed file, or null when it is missing or not JSON. */
	static function readJson(path:String):Dynamic {
		try {
			return FileSystem.exists(path) ? Json.parse(File.getContent(path)) : null;
		} catch (e:Dynamic) {
			return null;
		}
	}
}
#end
