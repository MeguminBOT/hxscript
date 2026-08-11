private typedef HxsModule = hl.Abstract<"hxs_module">;

class LoadProbe {
	@:hlNative("hxscript", "load") static function hxsLoad(data:hl.Bytes, size:Int):HxsModule {
		return null;
	}

	@:hlNative("hxscript", "last_error") static function hxsLastError():hl.Bytes {
		return null;
	}

	@:hlNative("hxscript", "entry_index") static function hxsEntryIndex(m:HxsModule):Int {
		return -1;
	}

	@:hlNative("hxscript", "closure") static function hxsClosure(m:HxsModule, findex:Int):Void->Dynamic {
		return null;
	}

	public static function main():Void {
		var path:String = Sys.args()[0];
		Sys.println('host: loading ' + path);

		var raw:haxe.io.Bytes = sys.io.File.getBytes(path);
		Sys.println('host: ' + raw.length + ' bytes');

		var m:HxsModule = hxsLoad(@:privateAccess raw.b, raw.length);
		if (m == null) {
			var e:hl.Bytes = hxsLastError();
			Sys.println('host: load FAILED: ' + (e == null ? 'no reason given' : @:privateAccess String.fromUTF8(e)));
			return;
		}
		Sys.println('host: loaded and jitted');

		var index:Int = hxsEntryIndex(m);
		Sys.println('host: entry point is function ' + index);

		var entry:Void->Dynamic = hxsClosure(m, index);
		if (entry == null) {
			Sys.println('host: no closure for the entry point');
			return;
		}

		Sys.println('host: calling it');
		entry();
		Sys.println('host: returned, still alive');
	}
}
