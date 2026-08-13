import hxscript.hl.Loader;
import hxscript.hl.Loader.Loaded;

/**
 * That a HashLink process can load bytecode that did not exist when it started, and is unchanged for
 * having done it.
 *
 * The second half is the part worth a test. `hl_module_init` ends by taking libhl's stack hooks for
 * itself, and the copy of module.c doing the taking can only see the modules loaded through it, so a
 * host that loads a script silently loses its own exception traces. Nothing about that is visible
 * until something goes wrong in production, which is exactly when a trace is wanted.
 */
class LoadProbe {
	static var failures:Int = 0;

	static function check(what:String, ok:Bool, ?detail:String):Void {
		Sys.println((ok ? '  ok   ' : '  FAIL ') + what + (detail == null ? '' : ': ' + detail));
		if (!ok)
			failures++;
	}

	static function deep(n:Int):Void {
		if (n == 0)
			throw 'from the host';
		deep(n - 1);
	}

	/** @return How many frames the host gets in an exception trace of its own. */
	static function hostTrace():Int {
		try {
			deep(3);
		} catch (e:Dynamic) {
			return haxe.CallStack.exceptionStack().length;
		}
		return 0;
	}

	public static function main():Void {
		var path:String = Sys.args()[0] == null ? 'guest.hl' : Sys.args()[0];

		if (!Loader.available) {
			Sys.println('  FAIL the loader is not usable: ' + Loader.why());
			Sys.exit(1);
		}

		var before:Int = hostTrace();
		check('the host has an exception trace to start with', before > 0, before + ' frames');

		var raw:haxe.io.Bytes = sys.io.File.getBytes(path);
		var module:Null<Loaded> = Loader.load(raw);
		check('the module reads, links and jits', module != null, Loader.error());

		if (module == null) {
			Sys.exit(1);
		}

		var index:Int = Loader.entryIndex(module);
		check('it names an entry point', index >= 0, 'function ' + index);

		var entry:Dynamic = Loader.bind(module, index);
		check('the entry point comes back as a closure', entry != null);

		if (sys.FileSystem.exists('guest.out'))
			sys.FileSystem.deleteFile('guest.out');

		Reflect.callMethod(null, entry, []);

		check('calling it ran the module\'s code', sys.FileSystem.exists('guest.out')
			&& StringTools.trim(sys.io.File.getContent('guest.out')) == '285');

		var after:Int = hostTrace();
		check('the host still has its own exception trace', after == before, after + ' frames, was ' + before);

		Sys.println(failures == 0 ? 'loader: all checks passed' : 'loader: ' + failures + ' FAILED');
		Sys.exit(failures == 0 ? 0 : 1);
	}
}
