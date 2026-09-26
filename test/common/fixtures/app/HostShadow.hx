package app;

import demo.Service;

/**
 * A bridged base whose constructor argument is named like a package.
 *
 * The source writes `Service.ping()`. Rebuilding qualifies it as `demo.Service.ping()`, and the
 * argument called `demo` hides that package, so the bridge does not compile.
 */
class HostShadow {
	public function new(demo:Service) {
		var s:String = Service.ping();
		if (demo == null || s == null)
			s = "x";
	}
}
