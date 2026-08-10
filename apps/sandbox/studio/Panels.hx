package studio;

import flixel.FlxG;
import host.Sandbox;
import smidr.UIRoot;
import smidr.widgets.UILabel;
import smidr.widgets.UITextArea;
import smidr.widgets.UIWindow;

/**
 * The three windows that can be up while a project runs.
 *
 * Windows rather than panes, and floating rather than docked, because what they are for is watching
 * something else: they have to be movable out of the way of whatever they are reporting on, and they
 * have to be closable without the layout underneath them changing. SmidrUI's `UIWindow` is draggable
 * and collapsible already, so this is mostly deciding what goes in them.
 *
 * The split between the first two is the honest one and not the obvious one. It is tempting to put `fps`
 * under **Script environment**, since the script is what is running, but there is one frame loop and it
 * belongs to the application, so it goes under **Sandbox** with the memory and the draw calls.
 *
 * That last group deserves its label. The counters cover interpreted work only, so a fully compiled project
 * reads zero across them, which is the compiler working rather than the readout breaking, and the window
 * says which by showing the compiled/interpreted split right above them.
 */
class Panels {
	/** How often the readouts are rewritten, in seconds. */
	static inline var PERIOD:Float = 0.25;

	/** How many console lines to keep. */
	static inline var LINES:Int = 500;

	static var script:UIWindow = null;
	static var sandbox:UIWindow = null;
	static var console:UIWindow = null;

	static var scriptText:UILabel = null;
	static var sandboxText:UILabel = null;
	static var consoleText:UITextArea = null;

	static var lines:Array<String> = [];
	static var since:Float = 0;
	static var root:UIRoot = null;

	/** Seconds the script counters have been accumulating for, so a count becomes a rate. */
	static var counted:Float = 0;

	/** Builds all three, hidden. */
	public static function mount(into:UIRoot):Void {
		if (root != null)
			return;

		root = into;

		script = window('Script environment', 300, 210, 12, Viewport.TOP + 12);
		scriptText = readout(script);

		sandbox = window('Sandbox', 260, 150, 324, Viewport.TOP + 12);
		sandboxText = readout(sandbox);

		console = window('Console', 520, 220, 12, Viewport.TOP + 240);

		consoleText = new UITextArea(520 - 20, 220 - 46, '');
		consoleText.x = 10;
		consoleText.y = 8;
		consoleText.readOnly = true;
		consoleText.fontSize = 11;
		consoleText.wordWrap = false;
		console.content.addChild(consoleText);
	}


	/**
	 * Keeps every window inside the application window.
	 *
	 * They are placed at fixed points and dragged from there, so shrinking the application would
	 * otherwise strand one past the edge, title bar included, with no way to drag it back.
	 */
	public static function layout():Void {
		inside(script);
		inside(sandbox);
		inside(console);
	}

	/**
	 * Moves one window back inside the visible area.
	 *
	 * @param window The window to clamp.
	 */
	static function inside(window:UIWindow):Void {
		if (window == null)
			return;

		var right:Float = FlxG.stage.stageWidth - window.w;
		var bottom:Float = FlxG.stage.stageHeight - Viewport.BOTTOM - window.h;

		if (window.x > right)
			window.x = right;
		if (window.y > bottom)
			window.y = bottom;

		if (window.x < 0)
			window.x = 0;
		if (window.y < Viewport.TOP)
			window.y = Viewport.TOP;
	}

	/**
	 * Whether each window is up, so the bar can show what it toggles.
	 *
	 * @return Three flags, in the order the bar puts them.
	 */
	public static function shown():{script:Bool, sandbox:Bool, console:Bool} {
		return {
			script: script != null && script.visible,
			sandbox: sandbox != null && sandbox.visible,
			console: console != null && console.visible
		};
	}

	public static function toggleScript():Void
		flip(script);

	public static function toggleSandbox():Void
		flip(sandbox);

	public static function toggleConsole():Void
		flip(console);

	/** Whether anything is up, so the caller can skip the work of filling them. */
	public static function any():Bool {
		var up = shown();
		return up.script || up.sandbox || up.console;
	}

	/**
	 * Appends a line to the console.
	 *
	 * Kept whether or not the window is open, so opening it shows what has already happened rather than
	 * starting blank. That is the difference between a console and a live feed, and the one that matters
	 * when something has just gone wrong.
	 *
	 * @param text What to append; may be several lines.
	 */
	public static function print(text:String):Void {
		for (line in text.split('\n'))
			lines.push(line);

		while (lines.length > LINES)
			lines.shift();

		if (consoleText != null && console.visible)
			consoleText.text = lines.join('\n');
	}

	/** Empties it. */
	public static function clear():Void {
		lines = [];

		if (consoleText != null)
			consoleText.text = '';
	}

	/**
	 * Rewrites the readouts, a few times a second.
	 *
	 * @param elapsed Seconds since the previous frame.
	 */
	public static function tick(elapsed:Float):Void {
		Metrics.tick(elapsed);
		counted += elapsed;

		if (root == null || !any())
			return;

		since += elapsed;

		if (since < PERIOD)
			return;

		since = 0;

		if (script.visible)
			scriptText.text = describeScripts();

		if (sandbox.visible)
			sandboxText.text = describeSandbox();
	}

	/**
	 * What the script window says.
	 *
	 * The timings come first because they are the only per-frame measurement that covers compiled code as
	 * well as interpreted. cppia has no counters to read, since its whole runtime surface is load, boot, run
	 * and resolve, so what a compiled class costs cannot be asked of it. What can be taken is the clock, and
	 * while a project is the state, the time between flixel's own signals is the project's.
	 */
	static function describeScripts():String {
		var project:String = Sandbox.current == null ? 'nothing loaded' : Sandbox.current.name;

		var out:Array<String> = [
			'project      $project',
			'mode         ' + Settings.mode,
			'classes      ' + Sandbox.classes().length + ' declared, ' + Sandbox.classCount + ' compiled',
			'bytecode     ' + (Sandbox.bytecode > 0 ? Math.round(Sandbox.bytecode / 102.4) / 10 + ' KB' : 'none'),
			'',
			'per frame, whichever way it runs',
			'  update     ' + Metrics.updateMs + ' ms',
			'  draw       ' + Metrics.drawMs + ' ms',
			''
		];

		if (hxscript.debug.Metrics.on) {
			out.push('interpreter work, per second');
			out.push('  calls      ' + rate(hxscript.debug.Metrics.calls));
			out.push('  reads      ' + rate(hxscript.debug.Metrics.reads));
			out.push('  writes     ' + rate(hxscript.debug.Metrics.writes));
			out.push('  instances  ' + rate(hxscript.debug.Metrics.instances));
			out.push('');
			out.push('compiled classes pass through');
			out.push('none of it, so zero here means');
			out.push('compiled, not idle.');

			hxscript.debug.Metrics.reset();
			counted = 0;
		}

		return out.join('\n');
	}

	/**
	 * Turns a count into a rate, over the time it was counted for.
	 *
	 * Measured rather than assumed to be the refresh period: the counters run whether or not the
	 * window is open, so the first reading after opening it covers however long it was shut.
	 *
	 * @param count The raw count since the last reset.
	 * @return The per-second figure.
	 */
	static function rate(count:Int):String {
		return counted <= 0 ? Std.string(count) : Std.string(Math.round(count / counted));
	}

	/** What the sandbox window says. */
	static function describeSandbox():String {
		return [
			'fps          ' + Metrics.fps + (Settings.fps > 0 ? '  (capped ' + Settings.fps + ')' : ''),
			'draw calls   ' + Metrics.drawCalls,
			'memory       ' + Metrics.memory + ' MB',
			'band         ' + Math.round(Viewport.width) + ' x ' + Math.round(Viewport.height),
			'drawn        ' + Math.round(Viewport.drawnWidth) + ' x ' + Math.round(Viewport.drawnHeight) + '  at '
			+ Math.round(Viewport.scale * 100) + '%',
			'game         ' + FlxG.width + ' x ' + FlxG.height
		].join('\n');
	}

	/** Shows or hides one window, bringing it to the front when it appears. */
	static function flip(window:UIWindow):Void {
		if (window == null)
			return;

		window.visible = !window.visible;

		if (window.visible && window.parent != null)
			window.parent.setChildIndex(window, window.parent.numChildren - 1);
	}

	/**
	 * Builds one window, hidden, at a starting position.
	 *
	 * @param title What it is called.
	 * @param width Its width.
	 * @param height Its height.
	 * @param x Where it starts.
	 * @param y Where it starts.
	 * @return The window.
	 */
	static function window(title:String, width:Float, height:Float, x:Float, y:Float):UIWindow {
		var made:UIWindow = new UIWindow(title, width, height);
		made.x = x;
		made.y = y;
		made.visible = false;
		made.collapsible = true;
		made.closable = true;
		made.onClose = function():Void made.visible = false;
		root.content.addChild(made);
		return made;
	}

	/** The label a readout window writes into. */
	static function readout(window:UIWindow):UILabel {
		var label:UILabel = new UILabel('', 11);
		label.x = 10;
		label.y = 8;
		window.content.addChild(label);
		return label;
	}
}
