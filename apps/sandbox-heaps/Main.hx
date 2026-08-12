import ui.Gallery;
import ui.Root;
import ui.Theme;

/**
 * The process entry, and the one class a script cannot be.
 *
 * `hxd.App` starts the window, owns the engine and drives the frame, so anything extending it would
 * have had to exist before the program did. A project that wants a loop of its own extends
 * `host.Project` instead and is handed the same lifecycle.
 */
class Main extends hxd.App {
	static var showGallery:Bool = false;

	static function main():Void {
		for (arg in Sys.args()) {
			if (arg == '--gallery')
				showGallery = true;
		}

		new Main();
	}

	var root:Root;
	var gallery:Null<Gallery>;

	override function init():Void {
		engine.backgroundColor = Theme.bg & 0xFFFFFF;

		root = new Root();
		setScene(root.scene);

		root.onResize = function():Void {
			if (gallery != null)
				gallery.layout();
		};

		if (showGallery)
			gallery = new Gallery(root);

		onResize();
	}

	override function onResize():Void {
		root.resize(engine.width, engine.height);
	}

	override function update(dt:Float):Void {}
}
