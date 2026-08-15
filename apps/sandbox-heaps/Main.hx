import h2d.Object;
import h2d.Scene;
import host.Api;
import studio.Launcher;
import studio.Metrics;
import studio.Projects;
import studio.Shell;
import studio.Viewport;
import ui.Gallery;
import ui.Root;
import ui.Theme;

/**
 * The process entry, and the one class a script cannot be.
 *
 * `hxd.App` starts the window, owns the engine and drives the frame, so anything extending it would
 * have had to exist before the program did. A project that wants a loop of its own extends
 * `host.Project` instead and is handed the same lifecycle.
 *
 * **Two scenes, rendered in order.** The project has one, fitted to the band between the bars and
 * scaled with it; the interface has another that is never scaled, which is what lets the bars keep
 * their size while what sits between them changes. One scene for both would mean choosing between a
 * project that is never scaled and an interface that always is.
 *
 * The shell's shortcuts are read from the window rather than from either scene, because the one that
 * matters is the way back and it has to keep working while a project owns everything else.
 */
class Main extends hxd.App {
	static var wantsGallery:Bool = false;

	/** The project `--conform` named, or null when this is an ordinary run. */
	static var conformProject:Null<String> = null;

	static function main():Void {
		for (arg in Sys.args()) {
			if (arg == '--gallery')
				wantsGallery = true;
		}

		if (!Projects.open(argument('--projects')))
			Api.log('could not open a projects folder at ' + Projects.root);

		Shell.autoRun = argument('--run');
		conformProject = argument('--conform');

		new Main();
	}

	/**
	 * Reads a `--name value` command-line argument.
	 *
	 * @param name The flag, including its dashes.
	 * @return The value after it, or null when the flag is absent.
	 */
	static function argument(name:String):Null<String> {
		var args:Array<String> = Sys.args();

		for (i in 0...args.length) {
			if (args[i] == name && i + 1 < args.length)
				return args[i + 1];
		}

		return null;
	}

	/** The interface. */
	var root:Root;

	/** What a project draws on, unless it becomes a scene of its own. */
	var stage:Scene;

	/** What the launcher adds a project's object to. */
	var surface:Object;

	/** A scene a project became, which replaces `stage` until it stops. */
	var borrowed:Null<Scene>;

	var gallery:Null<Gallery>;

	/** Whether a 3D project is running, which is the only time that scene is worth drawing. */
	var drawing3D:Bool = false;

	override function init():Void {
		/**
		 * The conformance run, before anything is mounted.
		 *
		 * Here rather than in `main` because heaps has to be up: a case that builds an `h2d.Object`
		 * needs the engine to exist, and the engine is what `hxd.App` starts on its way to this
		 * method. The window opens and the process ends without ever drawing, which is what makes it
		 * something a script can drive.
		 */
		/**
		 * A loader before anything can ask for one.
		 *
		 * `hxd.Res.loader` throws rather than answering null when nothing has set it, so a script
		 * that so much as asks whether an asset exists ends the process if this has not run. It used
		 * to run from `Launcher.start`, which is every way of starting a project except the one the
		 * conformance pass uses, and that is exactly where it was found missing.
		 *
		 * Pointed at the app's own folder here. A project with assets of its own gets it repointed
		 * when it starts.
		 */
		host.Assets.useFor();

		if (conformProject != null) {
			studio.Conform.run(conformProject);
			return;
		}

		engine.backgroundColor = Theme.bg & 0xFFFFFF;

		stage = new Scene();
		surface = new Object(stage);

		root = new Root();
		setScene(root.scene, false);
		sevents.addScene(stage, 1);

		root.onResize = function():Void {
			if (gallery != null)
				gallery.layout();
			else
				Shell.layout();

			Viewport.fit(borrowed != null ? borrowed : stage, engine.width, engine.height);
		};

		if (wantsGallery) {
			gallery = new Gallery(root);
		} else {
			Api.backend = 'heaps';
			Api.screenWidth = Viewport.CANVAS_WIDTH;
			Api.screenHeight = Viewport.CANVAS_HEIGHT;

			Launcher.onScene = borrow;
			Launcher.world = s3d;
			Launcher.onWorld = function(on:Bool):Void drawing3D = on;
			Api.onWorld = Launcher.reach3D;
			Shell.mount(root, surface);

			hxd.Window.getInstance().addEventTarget(function(e:hxd.Event):Void {
				if (e.kind == EKeyDown)
					Shell.pressed(e.keyCode);
			});
		}

		onResize();
	}

	/**
	 * Takes a scene a project became, or gives it back.
	 *
	 * @param scene The project's scene, or null when it has stopped.
	 */
	function borrow(scene:Null<Scene>):Void {
		if (borrowed != null) {
			sevents.removeScene(borrowed);
			borrowed = null;
		}

		borrowed = scene;

		if (borrowed != null)
			sevents.addScene(borrowed, 1);

		Viewport.fit(borrowed != null ? borrowed : stage, engine.width, engine.height);
	}

	override function onResize():Void {
		root.resize(engine.width, engine.height);
	}

	override function update(dt:Float):Void {
		Metrics.beginUpdate();

		if (gallery == null) {
			Launcher.update(dt);
			Shell.tick(dt);
		}

		Metrics.tick(dt);
		Metrics.endUpdate();
	}

	/**
	 * Draws the project, then the interface over it.
	 *
	 * The order is the whole arrangement: the interface has to be on top, and the project has to be
	 * scaled without it.
	 */
	override function render(e:h3d.Engine):Void {
		Metrics.beginDraw();

		/**
		 * The 3D scene first, when there is one running. It fills the frame and the flat scenes are
		 * drawn over it, which is the order every heaps program uses and the only one where a 2D
		 * interface on top of a 3D world is visible.
		 */
		if (drawing3D)
			s3d.render(e);

		var below:Scene = borrowed != null ? borrowed : stage;
		below.render(e);
		root.scene.render(e);

		Metrics.endDraw(e);
	}
}
