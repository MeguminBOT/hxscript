import hxscript.hl.Loader;
import hxscript.hl.Loader.Loaded;

class LoadProbe {
	public static function main():Void {
		var path:String = Sys.args()[0];
		Sys.println('host: loading ' + path);

		var raw:haxe.io.Bytes = sys.io.File.getBytes(path);
		Sys.println('host: ' + raw.length + ' bytes');

		var m:Loaded = Loader.load(raw);
		if (m == null) {
			Sys.println('host: load FAILED: ' + (Loader.error() ?? 'no reason given'));
			return;
		}
		Sys.println('host: loaded and jitted');

		var index:Int = Loader.entryIndex(m);
		Sys.println('host: entry point is function ' + index);

		var entry:Dynamic = Loader.bind(m, index);
		if (entry == null) {
			Sys.println('host: no closure for the entry point');
			return;
		}

		Sys.println('host: calling it');
		Reflect.callMethod(null, entry, []);
		Sys.println('host: returned, still alive');
	}
}
