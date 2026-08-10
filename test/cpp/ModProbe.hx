import hxscript.compile.Cppia;
import hxscript.compile.Unit;
import hxscript.compile.Result;

/**
 * Finds which class of a real mod produces bytecode the cppia loader will not accept.
 *
 * The loader reports a fault in the module as a whole, such as "Bad move target" or "Bad link", and names
 * nothing inside it, so a mod of forty classes gives no clue which one is at fault. Compiling and booting
 * each on its own turns that into a filename.
 *
 * Run with the class root as the first argument.
 */
class ModProbe {
	public static function main():Void {
		cpp.cppia.Host.enableJit(true);

		var root:String = Sys.args()[0];
		if (root == null) {
			Sys.println('usage: ModProbe <classes root>');
			return;
		}

		var files:Array<String> = [];
		walk(root, '', files);
		Sys.println('found ' + files.length + ' classes under ' + root);

		var paths:Array<String> = [];
		for (file in files) {
			paths.push(pathOf(file));
		}

		// The engine compiles the whole world in one batch, and a fault can belong to the combination
		// rather than to any one class. So try the batch first, and only fall back to picking classes
		// off one at a time if the batch is clean.
		var whole:String = tryBatch(root, files, paths, indices(files.length));
		Sys.println(whole == null ? 'the whole batch loaded' : 'whole batch: ' + whole);

		if (whole != null) {
			var culprits:Array<Int> = narrow(root, files, paths, indices(files.length));
			for (i in culprits) {
				Sys.println('  needed: ' + files[i]);
			}
			return;
		}

		var bad:Int = 0;

		for (i in 0...files.length) {
			var file:String = files[i];
			var src:String = sys.io.File.getContent(root + '/' + file);

			var parts:Array<String> = file.split('/');
			var name:String = parts.pop();
			name = name.substr(0, name.length - 3);

			var outside:Array<String> = [];
			for (j in 0...paths.length) {
				if (j != i) {
					outside.push(paths[j]);
				}
			}

			var problem:String = null;
			try {
				var decls = new hxscript.syntax.Parser().parseModule(src, name, 0, parts);
				var res:Result = Cppia.compile([{name: name, decls: decls}], null, outside, []);

				if (res.bytes == null) {
					problem = 'refused: ' + (res.skipped.length > 0 ? res.skipped[0].reason : 'no reason');
				} else {
					var loaded = cpp.cppia.Module.fromData(res.bytes.getData());
					loaded.boot();
				}
			} catch (e:Dynamic) {
				problem = 'LOADER: ' + Std.string(e);
			}

			if (problem != null && problem.indexOf('refused:') != 0) {
				Sys.println('  ' + file + '  ->  ' + problem);
				bad++;
			}
		}

		Sys.println(bad == 0 ? 'every class loaded on its own' : bad + ' classes the loader rejected');
	}

	static function indices(n:Int):Array<Int> {
		var out:Array<Int> = [];
		for (i in 0...n) out.push(i);
		return out;
	}

	/** Compiles a subset together and boots it, returning the loader's complaint or null. */
	static function tryBatch(root:String, files:Array<String>, paths:Array<String>, pick:Array<Int>):String {
		var inputs:Array<Unit> = [];
		var outside:Array<String> = [];
		var chosen:Map<Int, Bool> = new Map();
		for (i in pick) chosen.set(i, true);

		for (i in 0...files.length) {
			if (!chosen.exists(i)) { outside.push(paths[i]); continue; }
			var file:String = files[i];
			var parts:Array<String> = file.split('/');
			var name:String = parts.pop();
			name = name.substr(0, name.length - 3);
			try {
				var decls = new hxscript.syntax.Parser().parseModule(sys.io.File.getContent(root + '/' + file), name, 0, parts);
				inputs.push({name: name, decls: decls});
			} catch (e:Dynamic) {}
		}

		if (inputs.length == 0) return null;

		try {
			var res:Result = Cppia.compile(inputs, null, outside, []);
			if (res.bytes == null) return null;
			var loaded = cpp.cppia.Module.fromData(res.bytes.getData());
			loaded.boot();
		} catch (e:Dynamic) {
			return Std.string(e);
		}
		return null;
	}

	/** Shrinks a failing set to the smallest subset that still fails. */
	static function narrow(root:String, files:Array<String>, paths:Array<String>, pick:Array<Int>):Array<Int> {
		var current:Array<Int> = pick;
		var changed:Bool = true;

		while (changed && current.length > 1) {
			changed = false;
			var i:Int = 0;
			while (i < current.length) {
				var trial:Array<Int> = current.copy();
				trial.splice(i, 1);
				if (tryBatch(root, files, paths, trial) != null) {
					current = trial;
					changed = true;
				} else {
					i++;
				}
			}
		}

		return current;
	}

	static function pathOf(file:String):String {
		var p:String = file.substr(0, file.length - 3);
		return StringTools.replace(p, '/', '.');
	}

	static function walk(root:String, rel:String, out:Array<String>):Void {
		var dir:String = rel.length == 0 ? root : root + '/' + rel;
		for (entry in sys.FileSystem.readDirectory(dir)) {
			var sub:String = rel.length == 0 ? entry : rel + '/' + entry;
			if (sys.FileSystem.isDirectory(dir + '/' + entry)) {
				walk(root, sub, out);
			} else if (entry.length > 3 && entry.substr(entry.length - 3) == '.hx') {
				out.push(sub);
			}
		}
	}
}
