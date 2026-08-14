import crowplexus.iris.Iris;
import crowplexus.iris.IrisConfig;

/** Runner for hscript-iris. */
class RunIris {
	static function main():Void {
		XBench.run(Sys.args()[0], prepare, exec);
	}

	static function prepare(src:String):Dynamic {
		// Iris keeps every instance in a static map and uniquifies names against it, so it is cleared
		// between preparations to keep that bookkeeping out of the measurement.
		Iris.instances.clear();
		var it = new Iris(src, new IrisConfig("bench", false, true, []));
		it.parse(true);
		return it;
	}

	static function exec(h:Dynamic):Dynamic {
		var it:Iris = cast h;
		return it.execute();
	}
}
