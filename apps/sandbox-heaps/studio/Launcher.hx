package studio;

import h2d.Object;
import h2d.Scene;
import h3d.scene.Object as Object3D;
import host.Api;
import host.Project;
import host.Sandbox;
import hxscript.error.Sink;
import hxscript.types.ScriptedClass;

/**
 * Works out what a project runs, runs it, and gets out of the way.
 *
 * **A project says what it is by what it declares.** There is no interface to implement and no base
 * every project must extend, because heaps already has the right bases and making a project extend
 * something of ours instead would be wrapping a library rather than using it.
 *
 * What `project.json` names wins over what the scripts imply, and a name that resolves to something
 * unrunnable is reported rather than silently ignored: a manifest naming a class that extends
 * `h2d.Object` runs, because refusing it on the strength of a string in a file would be inventing a
 * rule with nothing behind it.
 */
class Launcher {
	/** Whether a project is running. */
	public static var running(default, null):Bool = false;

	/** What the running project is, by shape. */
	public static var kind(default, null):EntryKind = null;

	/** The scripted class that was resolved, running or not. */
	public static var entry(default, null):ScriptedClass = null;

	/** Called when a project ends, however it ended, so the shell can come back. */
	public static var onStopped:Void->Void = null;

	/**
	 * Called to put a scripted scene on screen, and again with null to take it off.
	 *
	 * Given by the app rather than reached for, because the scene a project becomes is the app's to
	 * swap and `hxd.App` is the one class nothing here has a reference to.
	 */
	public static var onScene:Null<Scene>->Void = null;

	/** The instance, for the shapes that have one. */
	static var instance:Dynamic = null;

	/** What a `KObject` or `KProject` draws into, owned here rather than by the project. */
	static var layer:Object = null;

	/**
	 * The 3D scene, given by the app for the reason `onScene` is.
	 *
	 * heaps keeps two scene graphs and a project may want either. `hxd.App` makes both and this app
	 * drew only the flat one, so a project reaching for 3D had nowhere to put anything. A script
	 * asks for this through `world()` rather than by extending it: `h3d.scene.Object` inlines an
	 * abstract's constructor, which is the one shape a generated bridge cannot re-emit.
	 */
	public static var world:Object3D = null;

	/** Told when the 3D scene is being used, so the app knows whether to draw it. */
	public static var onWorld:Bool->Void = null;

	/**
	 * @return The 3D scene, and from now on it is drawn.
	 *
	 * Asking is what turns it on. A project that never asks costs nothing, which is most of them.
	 */
	public static function reach3D():Object3D {
		if (world != null && onWorld != null)
			onWorld(true);

		return world;
	}

	/** Whether the input hooks are installed. */
	static var listening:Bool = false;

	/**
	 * Finds the class a project should run.
	 *
	 * The order matters only where a project offers more than one answer, and then it goes from most
	 * explicit to least: what the manifest names, what a script flagged, then the bases, in the order
	 * a project is most likely to have meant.
	 *
	 * @param project The loaded project.
	 * @return The class and how to run it, or null with the reason reported.
	 */
	public static function resolve(project:ProjectInfo):{cls:ScriptedClass, kind:EntryKind} {
		var named:ScriptedClass = project.entry == null ? null : find(project.entry);

		if (project.entry != null && named == null) {
			Sink.note(PRun, 'project.json names an entry class `${project.entry}` that this project does not declare',
				'Either the class is somewhere other than scripts/, or its name is spelled differently.\n'
				+ 'Remove the entry line to let the launcher work it out from what the scripts declare.');
		}

		if (named != null) {
			var shape:EntryKind = shapeOf(named);

			if (shape != null)
				return {cls: named, kind: shape};

			Sink.note(PRun, '`${project.entry}` is not something this app knows how to run',
				'An entry class has to extend h2d.Scene, h2d.Object or host.Project,\n' + 'or declare a static main().');
		}

		for (cls in Sandbox.classes()) {
			if (cls.reflectGetField('entry') == true) {
				var shape:EntryKind = shapeOf(cls);

				if (shape != null)
					return {cls: cls, kind: shape};
			}
		}

		var scenes:Array<ScriptedClass> = Sandbox.extending(Scene);
		if (scenes.length > 0)
			return {cls: scenes[0], kind: KScene};

		var objects:Array<ScriptedClass> = Sandbox.extending(Object);
		if (objects.length > 0)
			return {cls: objects[0], kind: KObject};

		var projects:Array<ScriptedClass> = Sandbox.extending(Project);
		if (projects.length > 0)
			return {cls: projects[0], kind: KProject};

		for (cls in Sandbox.classes())
			if (hasMain(cls))
				return {cls: cls, kind: KMain};

		return null;
	}

	/**
	 * Starts a project.
	 *
	 * @param project The loaded project.
	 * @param into Where a `KObject` or `KProject` should draw, given by the shell.
	 * @return Whether anything started.
	 */
	public static function start(project:ProjectInfo, into:Object):Bool {
		stop();

		var found:{cls:ScriptedClass, kind:EntryKind} = resolve(project);

		if (found == null) {
			Sink.note(PRun, '${project.name} declares nothing this app knows how to run',
				'A project runs when one of its classes extends h2d.Scene, h2d.Object or host.Project,\n'
				+ 'or declares a static main(). Name one explicitly with an "entry" line in\n'
				+ 'project.json, or mark one with `public static var entry:Bool = true`.');
			return false;
		}

		entry = found.cls;
		kind = found.kind;
		layer = into;

		/** Its own `res/` if it has one, the app's otherwise, before a line of it runs. */
		host.Assets.useFor(project.path);

		Api.onQuit = stop;

		switch (kind) {
			case KMain:
				var main:Dynamic = entry.reflectGetField('main');

				if (!Reflect.isFunction(main)) {
					Sink.note(PRun, '${entry.name}.main is not callable');
					return false;
				}

				running = true;

				try {
					Reflect.callMethod(null, main, []);
				} catch (e:haxe.Exception) {
					Sink.caught(e, PRun, '${entry.name}.main');
					stop();
					return false;
				}

				if (!keepsRunning()) {
					Sink.note(PRun, '${entry.name}.main returned', 'Nothing was left running, so the shell is back.\n'
						+ 'A project that wants to keep going puts something on the screen: become a\n'
						+ 'scene, add to the layer, or extend host.Project for a frame loop.');
					stop();
					return false;
				}

			case KScene:
				instance = Sandbox.make(entry);

				if (instance == null)
					return false;

				running = true;

				if (onScene != null)
					onScene(cast instance);

			case KObject:
				instance = Sandbox.make(entry);

				if (instance == null)
					return false;

				running = true;
				layer.addChild(cast instance);

			case KProject:
				instance = Sandbox.make(entry);

				if (instance == null)
					return false;

				var made:Project = cast instance;
				made.layer = layer;

				running = true;
				listen();

				try {
					made.start();
				} catch (e:haxe.Exception) {
					Sink.caught(e, PRun, '${entry.name}.start');
					stop();
					return false;
				}
		}

		return running;
	}

	/**
	 * Whether a `main()` that has returned left anything behind that is still going.
	 *
	 * A project with no framework under it is the one shape that can finish. It runs, returns, and
	 * unless it became a scene or put something on the layer there is nothing on screen and nothing
	 * to update, so leaving the shell hidden would show an empty window until somebody guessed at
	 * the back key.
	 *
	 * @return Whether something it started is still on screen.
	 */
	static function keepsRunning():Bool {
		return layer != null && layer.numChildren > 0;
	}

	/** Starts hearing the input a `host.Project` is handed. */
	static function listen():Void {
		if (listening)
			return;

		listening = true;
		hxd.Window.getInstance().addEventTarget(onEvent);
	}

	/** Stops. */
	static function deafen():Void {
		if (!listening)
			return;

		listening = false;
		hxd.Window.getInstance().removeEventTarget(onEvent);
	}

	/**
	 * Hands one window event to a running `host.Project`.
	 *
	 * Pointer coordinates are put into the project's own canvas rather than the window's, because a
	 * project is told its canvas is 1366x768 and coordinates in anything else would not agree with
	 * what it draws.
	 */
	static function onEvent(e:hxd.Event):Void {
		if (!running || kind != KProject || instance == null)
			return;

		var made:Project = cast instance;

		try {
			switch (e.kind) {
				case EKeyDown:
					made.onKeyDown(e.keyCode);

				case EKeyUp:
					made.onKeyUp(e.keyCode);

				case EMove:
					var at = canvasPoint(e);
					made.onMouseMove(at.x, at.y);

				case EPush:
					var at = canvasPoint(e);
					made.onMouseDown(at.x, at.y);
					made.onMouseButton(e.button, true, at.x, at.y);

				case ERelease, EReleaseOutside:
					var at = canvasPoint(e);
					made.onMouseButton(e.button, false, at.x, at.y);

				case _:
			}
		} catch (ex:haxe.Exception) {
			Sink.caught(ex, PRun, '${entry.name} input');
			stop();
		}
	}

	/**
	 * Hands relative pointer movement to the running project.
	 *
	 * Called by the app while the pointer is captured, since that is the only mode in which there is
	 * movement without a position.
	 *
	 * @param dx How far across, in window pixels.
	 * @param dy How far down, in window pixels.
	 */
	public static function look(dx:Float, dy:Float):Void {
		if (!running || kind != KProject || instance == null)
			return;

		var made:Project = cast instance;

		try {
			made.onMouseLook(dx, dy);
		} catch (ex:haxe.Exception) {
			Sink.caught(ex, PRun, '${entry.name} input');
			stop();
		}
	}

	/**
	 * @param e A window event.
	 * @return Where it happened, in the project's canvas.
	 */
	static function canvasPoint(e:hxd.Event):{x:Float, y:Float} {
		var scale:Float = Viewport.scale <= 0 ? 1 : Viewport.scale;
		var left:Float = (Viewport.width - Viewport.drawnWidth) * 0.5;
		var top:Float = Viewport.TOP + (Viewport.height - Viewport.drawnHeight) * 0.5;

		return {x: (e.relX - left) / scale, y: (e.relY - top) / scale};
	}

	/**
	 * Advances a running project by one frame.
	 *
	 * Only `KProject` needs this. A scene and an object are drawn by being on screen, and a `main()`
	 * owns whatever it started.
	 *
	 * @param dt Seconds since the previous frame.
	 */
	public static function update(dt:Float):Void {
		if (!running || kind != KProject || instance == null)
			return;

		var made:Project = cast instance;

		try {
			made.update(dt);
		} catch (e:haxe.Exception) {
			Sink.caught(e, PRun, '${entry.name}.update');
			stop();
			return;
		}

		if (made.done)
			stop();
	}

	/** Ends whatever is running and empties what it drew into. */
	public static function stop():Void {
		if (!running) {
			clear();
			return;
		}

		running = false;
		deafen();

		if (kind == KProject && instance != null) {
			try {
				(cast instance : Project).stop();
			} catch (e:haxe.Exception) {
				Sink.caught(e, PRun, '${entry.name}.stop');
			}
		}

		if (kind == KScene && onScene != null)
			onScene(null);

		clear();

		if (onStopped != null)
			onStopped();
	}

	/** Empties the layer, so nothing of one project reaches the next. */
	static function clear():Void {
		instance = null;
		kind = null;

		/**
		 * The pointer comes back before anything else, so a project that captured it and then failed
		 * cannot leave somebody unable to reach the window they would fix it in.
		 */
		host.Api.captureMouse(false);

		if (layer != null)
			layer.removeChildren();

		/**
		 * The camera goes back too, not just the objects.
		 *
		 * A 3D project has to point the camera at what it built, so it is the one piece of the scene
		 * that a project changes without adding anything, and emptying the children leaves it wherever
		 * the last project put it. The next one then opens looking somewhere chosen by a project that
		 * is no longer running, which reads as its own bug.
		 */
		if (world != null) {
			world.removeChildren();

			var view:h3d.Camera = (cast world : h3d.scene.Scene).camera;
			view.fovY = 25;
			view.pos.set(2, 3, 4);
			view.target.set(0, 0, 0);
			view.up.set(0, 0, 1);
		}

		if (onWorld != null)
			onWorld(false);

		Api.onQuit = null;
	}

	/**
	 * @param cls A scripted class.
	 * @return How it would be run, or null when it is not something this app runs.
	 */
	static function shapeOf(cls:ScriptedClass):EntryKind {
		if (Sandbox.descendsFrom(cls, Scene))
			return KScene;
		if (Sandbox.descendsFrom(cls, Object))
			return KObject;
		if (Sandbox.descendsFrom(cls, Project))
			return KProject;
		if (hasMain(cls))
			return KMain;

		return null;
	}

	/**
	 * @param cls A scripted class.
	 * @return Whether it declares a callable static `main`.
	 */
	static function hasMain(cls:ScriptedClass):Bool {
		var main:Dynamic = cls.reflectGetField('main');
		return Reflect.isFunction(main);
	}

	/**
	 * @param name A class name, with or without its package.
	 * @return The scripted class, or null when the project has none by that name.
	 */
	static function find(name:String):ScriptedClass {
		for (cls in Sandbox.classes()) {
			if (cls.name == name || cls.path == name)
				return cls;
		}
		return null;
	}
}
