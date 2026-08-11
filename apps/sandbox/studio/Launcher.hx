package studio;

import flixel.FlxG;
import flixel.FlxState;
import host.Api;
import host.Project;
import host.Sandbox;
import hxscript.error.Sink;
import hxscript.types.ScriptedClass;
import lime.app.Application;
import lime.ui.KeyCode;
import lime.ui.KeyModifier;
import lime.ui.MouseButton;
import lime.ui.Window;
import openfl.display.Sprite;
import studio.EntryKind;

/**
 * Works out what a project runs, runs it, and gets back out of the way.
 *
 * The design decision worth stating: **a project says what it is by what it declares.** There is no
 * interface to implement and no base every project must extend, because the three libraries this app
 * carries already have the right base in each case, and making a project extend something of ours
 * instead would be wrapping a library rather than using it. So a project that wants flixel's
 * lifecycle extends `FlxState` and gets all of it; one that wants the display list extends `Sprite`;
 * one that wants neither extends `host.Project`; and one that wants to do its own thing declares a
 * `main`.
 *
 * `kind` in `project.json` has no say in this. A project labelled `flixel` that declares an
 * `openfl.display.Sprite` runs, because refusing it on the strength of a string in a file would be
 * inventing a rule with nothing behind it.
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

	/** The instance, for the shapes that have one. */
	static var instance:Dynamic = null;

	/** What a `KSprite` or `KProject` draws into, owned here rather than by the project. */
	static var layer:Sprite = null;

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
				'An entry class has to extend flixel.FlxState, openfl.display.Sprite or host.Project,\n' + 'or declare a static main().');
		}

		for (cls in Sandbox.classes()) {
			if (cls.reflectGetField('entry') == true) {
				var shape:EntryKind = shapeOf(cls);

				if (shape != null)
					return {cls: cls, kind: shape};
			}
		}

		var states:Array<ScriptedClass> = Sandbox.extending(FlxState);
		if (states.length > 0)
			return {cls: states[0], kind: KState};

		var sprites:Array<ScriptedClass> = Sandbox.extending(Sprite);
		if (sprites.length > 0)
			return {cls: sprites[0], kind: KSprite};

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
	 * @param into Where a `KSprite` or `KProject` should draw, given by the shell.
	 * @return Whether anything started.
	 */
	public static function start(project:ProjectInfo, into:Sprite):Bool {
		stop();

		var found:{cls:ScriptedClass, kind:EntryKind} = resolve(project);

		if (found == null) {
			Sink.note(PRun, '${project.name} declares nothing this app knows how to run',
				'A project runs when one of its classes extends flixel.FlxState, openfl.display.Sprite\n'
				+ 'or host.Project, or declares a static main(). Name one explicitly with an "entry"\n'
				+ 'line in project.json, or mark one with `public static var entry:Bool = true`.');
			return false;
		}

		entry = found.cls;
		kind = found.kind;
		layer = into;

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
						+ 'A project that wants to keep going puts something on the screen: switch to a\n'
						+ 'flixel state, add to the layer, or extend host.Project for a frame loop.');
					stop();
					return false;
				}

			case KState:
				instance = Sandbox.make(entry);

				if (instance == null)
					return false;

				running = true;
				FlxG.switchState(function():FlxState return cast instance);

			case KSprite:
				instance = Sandbox.make(entry);

				if (instance == null)
					return false;

				running = true;
				layer.addChild(cast instance);

			case KProject:
				instance = Sandbox.make(entry);

				if (instance == null)
					return false;

				var project:Project = cast instance;
				project.layer = layer;

				running = true;
				listen();

				try {
					project.start();
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
	 * unless it switched flixel somewhere or put something on the layer there is nothing on screen
	 * and nothing to update, so leaving the shell hidden would show an empty window until somebody
	 * guessed at the back key.
	 *
	 * @return Whether something it started is still on screen.
	 */
	static function keepsRunning():Bool {
		if (layer != null && layer.numChildren > 0)
			return true;

		return !Std.isOfType(FlxG.state, studio.Shell);
	}

	/**
	 * Subscribes a `host.Project` to lime's own window events.
	 *
	 * lime's key codes rather than flixel's or openfl's, and that is the whole reason this exists: a
	 * project at this level reaches `lime.ui.KeyCode` by name, so the codes it compares against have
	 * to be the ones lime reports. Routing through flixel would hand it flixel's, and routing through
	 * openfl would hand it Flash-style ones, and both would look correct for the printable keys and
	 * be wrong for every arrow.
	 */
	static function listen():Void {
		var window:Window = Application.current == null ? null : Application.current.window;

		if (window == null)
			return;

		window.onKeyDown.add(keyDown);
		window.onKeyUp.add(keyUp);
		window.onMouseMove.add(mouseMove);
		window.onMouseDown.add(mouseDown);
	}

	/** Unsubscribes from the window events, whether or not they were subscribed. */
	static function deafen():Void {
		var window:Window = Application.current == null ? null : Application.current.window;

		if (window == null)
			return;

		window.onKeyDown.remove(keyDown);
		window.onKeyUp.remove(keyUp);
		window.onMouseMove.remove(mouseMove);
		window.onMouseDown.remove(mouseDown);
	}

	/**
	 * Hands one callback to the running project, ending the run if it throws.
	 *
	 * A project that throws from an input callback is reported and stopped rather than left to throw
	 * again on the next key: a window that fills the log a hundred lines a second is a worse way to
	 * find out than one message and a return to the shell.
	 *
	 * @param name Which callback, for the report.
	 * @param call What to run.
	 */
	static function guard(name:String, call:Project->Void):Void {
		if (!running || kind != KProject || instance == null)
			return;

		try {
			call(cast instance);
		} catch (e:haxe.Exception) {
			Sink.caught(e, PRun, '${entry.name}.$name');
			stop();
		}
	}

	static function keyDown(code:KeyCode, modifier:KeyModifier):Void {
		guard('onKeyDown', function(p:Project):Void p.onKeyDown(cast code));
	}

	static function keyUp(code:KeyCode, modifier:KeyModifier):Void {
		guard('onKeyUp', function(p:Project):Void p.onKeyUp(cast code));
	}

	static function mouseMove(x:Float, y:Float):Void {
		guard('onMouseMove', function(p:Project):Void p.onMouseMove(x, y));
	}

	static function mouseDown(x:Float, y:Float, button:MouseButton):Void {
		guard('onMouseDown', function(p:Project):Void p.onMouseDown(x, y));
	}

	/**
	 * Advances a running project, for the shapes the host drives.
	 *
	 * `KState` and `KSprite` are not driven from here: flixel's state machine and openfl's display
	 * list already call them, and calling them again would double every frame.
	 *
	 * @param elapsed Seconds since the previous frame.
	 */
	public static function update(elapsed:Float):Void {
		if (!running || kind != KProject || instance == null)
			return;

		var project:Project = cast instance;

		try {
			project.update(elapsed);
		} catch (e:haxe.Exception) {
			Sink.caught(e, PRun, '${entry.name}.update');
			stop();
			return;
		}

		if (project.done)
			stop();
	}

	/**
	 * Ends whatever is running and puts the screen back.
	 *
	 * Emptying the layer is the host's job rather than the project's, so a project that forgets to
	 * clean up after itself cannot leak into the next one. Same for the flixel state: switching back
	 * is what disposes it.
	 */
	public static function stop():Void {
		if (!running) {
			clear();
			return;
		}

		running = false;

		if (kind == KProject) {
			deafen();

			if (instance != null) {
				try {
					(cast instance : Project).stop();
				} catch (e:haxe.Exception) {
					Sink.caught(e, PRun, '${entry.name}.stop');
				}
			}
		}

		clear();

		if (onStopped != null)
			onStopped();
	}

	/** Empties the layer and forgets the instance. */
	static function clear():Void {
		if (layer != null)
			while (layer.numChildren > 0)
				layer.removeChildAt(0);

		instance = null;
		kind = null;
		entry = null;
	}

	/**
	 * Which of the four shapes a class is, if any.
	 *
	 * @param cls The scripted class.
	 * @return The shape, or null when it is none of them.
	 */
	static function shapeOf(cls:ScriptedClass):EntryKind {
		if (Sandbox.descendsFrom(cls, FlxState))
			return KState;

		if (Sandbox.descendsFrom(cls, Sprite))
			return KSprite;

		if (Sandbox.descendsFrom(cls, Project))
			return KProject;

		if (hasMain(cls))
			return KMain;

		return null;
	}

	/**
	 * @param cls The scripted class.
	 * @return Whether it declares a callable static `main`.
	 */
	static function hasMain(cls:ScriptedClass):Bool {
		try {
			return Reflect.isFunction(cls.reflectGetField('main'));
		} catch (e:haxe.Exception) {
			return false;
		}
	}

	/**
	 * Looks up a class by the name a manifest gave, which may be short or fully qualified.
	 *
	 * @param name The class name.
	 * @return The class, or null.
	 */
	static function find(name:String):ScriptedClass {
		for (cls in Sandbox.classes())
			if (cls.name == name || cls.path == name)
				return cls;

		return null;
	}
}
