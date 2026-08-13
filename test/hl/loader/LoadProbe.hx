import hxscript.hl.Loader;
import hxscript.hl.Loader.Loaded;

/**
 * That a HashLink process can load bytecode that did not exist when it started, and is unchanged for
 * having done it.
 *
 * The second half is the part worth a test. Loading writes to `hl_setup`, libhl's one table of how
 * this process resolves symbols, walks stacks, makes dynamic calls and unwinds out of a throw:
 * `module.c` takes two of those fields and `jit.c` takes four more, because in hl.exe that happens
 * once at startup for the program's own module and never again. Every one of them is something the
 * host's own code is already using, and nothing about losing them is visible until whatever used
 * them next runs, which may be a stack trace nobody reads until production.
 *
 * So each is measured before the load and again after it, and has to answer the same.
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

	static function twice(v:Int):Int {
		return v * 2;
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

	/** @return Whether the host can still throw and catch, which is `hl_setup.throw_jump`. */
	static function hostCatches():Bool {
		try {
			deep(2);
		} catch (e:Dynamic) {
			return e == 'from the host';
		}
		return false;
	}

	/** @return A call made through libhl's dynamic path, which is `hl_setup.static_call`. */
	static function hostDynamicCall():Int {
		var fn:Dynamic = twice;
		return Reflect.callMethod(null, fn, [21]);
	}

	/** @return A call through a closure whose type had to be adapted, which reaches `get_wrapper`. */
	static function hostWrappedCall():Int {
		var loose:Dynamic = twice;
		var typed:Int->Int = loose;
		return typed(50);
	}

	/** Everything the host does that a load could have taken out from under it. */
	static function state():String {
		return hostTrace() + '/' + hostCatches() + '/' + hostDynamicCall() + '/' + hostWrappedCall();
	}

	public static function main():Void {
		var path:String = Sys.args()[0] == null ? 'guest.hl' : Sys.args()[0];

		if (!Loader.available) {
			Sys.println('  FAIL the loader is not usable: ' + Loader.why());
			Sys.exit(1);
		}

		var before:String = state();
		check('the host can trace, throw, call dynamically and call through a wrapper', before == '5/true/42/100', before);

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

		var after:String = state();
		check('the host is unchanged for having loaded it', after == before, after + ', was ' + before);

		var again:Null<Loaded> = Loader.load(raw);
		check('a second module loads', again != null, Loader.error());

		var third:String = state();
		check('the host is still unchanged after a second load', third == before, third + ', was ' + before);

		var taken:Int = Loader.hooks();
		check('every hl_setup field the load took is one this build knows about', (taken & Loader.HOOK_UNKNOWN) == 0,
			'hooks ' + taken);

		Sys.println(failures == 0 ? 'loader: all checks passed' : 'loader: ' + failures + ' FAILED');
		Sys.exit(failures == 0 ? 0 : 1);
	}
}
