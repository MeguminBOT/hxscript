package studio;

import host.Sandbox;
import ui.Label;
import ui.Root;
import ui.TextArea;
import ui.Theme;
import ui.Window;

/**
 * The three windows the top bar toggles, which stay up while a project runs.
 *
 * They are the reason the shell occupies a band rather than the whole window: something has to be
 * readable *while* the thing being debugged is running, which is when there is most to read.
 *
 * What goes in which follows from what can honestly be attributed. **Script environment** is the
 * interpreter's and the compiler's, and only theirs. **Sandbox** is the application's, because there
 * is one frame loop and one heap and neither can be divided by who asked for the work. **Console** is
 * everything printed, from the shell and from the project alike.
 */
class Panels {
	static var script:Window;
	static var sandbox:Window;
	static var console:Window;

	static var scriptText:Label;
	static var sandboxText:Label;
	static var consoleLog:TextArea;

	static var root:Root;
	static var since:Float = 0;

	/** How often the two readouts are rewritten, in seconds. */
	static inline var PERIOD:Float = 0.25;

	/**
	 * Builds them, hidden.
	 *
	 * @param into Where they live, which is above everything the shell draws.
	 */
	public static function mount(into:Root):Void {
		root = into;

		script = new Window('Script environment', into.above);
		script.x = Theme.px(40);
		script.y = Theme.px(60);
		script.visible = false;
		script.onClose = function():Void script.visible = false;

		scriptText = new Label('', 12, Secondary, script.content);
		scriptText.x = Theme.px(10);
		scriptText.y = Theme.px(8);

		sandbox = new Window('Sandbox', into.above);
		sandbox.x = Theme.px(360);
		sandbox.y = Theme.px(60);
		sandbox.visible = false;
		sandbox.onClose = function():Void sandbox.visible = false;

		sandboxText = new Label('', 12, Secondary, sandbox.content);
		sandboxText.x = Theme.px(10);
		sandboxText.y = Theme.px(8);

		console = new Window('Console', into.above);
		console.x = Theme.px(680);
		console.y = Theme.px(60);
		console.visible = false;
		console.onClose = function():Void console.visible = false;

		consoleLog = new TextArea(console.content);
	}

	/** Sizes them and keeps them on screen after the window changed. */
	public static function layout():Void {
		if (script == null)
			return;

		script.resize(Theme.px(300), Theme.px(190));
		sandbox.resize(Theme.px(300), Theme.px(160));
		console.resize(Theme.px(460), Theme.px(240));

		consoleLog.place(Theme.px(8), Theme.px(6), Theme.px(444), Theme.px(240) - Theme.px(Window.BAR) - Theme.px(14));

		script.keepInside(root.width, root.height);
		sandbox.keepInside(root.width, root.height);
		console.keepInside(root.width, root.height);
	}

	/** @return Which of them are up, for the bar's labels. */
	public static function shown():{script:Bool, sandbox:Bool, console:Bool} {
		if (script == null)
			return {script: false, sandbox: false, console: false};

		return {script: script.visible, sandbox: sandbox.visible, console: console.visible};
	}

	/** Shows or hides the script environment. */
	public static function toggleScript():Void {
		if (script != null)
			script.visible = !script.visible;
	}

	/** Shows or hides the sandbox readout. */
	public static function toggleSandbox():Void {
		if (sandbox != null)
			sandbox.visible = !sandbox.visible;
	}

	/** Shows or hides the console. */
	public static function toggleConsole():Void {
		if (console != null)
			console.visible = !console.visible;
	}

	/** @return Whether any of them is up. */
	public static function any():Bool {
		var up = shown();
		return up.script || up.sandbox || up.console;
	}

	/**
	 * Adds to the console, wherever it came from.
	 *
	 * @param text What to add; may be several lines.
	 */
	public static function print(text:String):Void {
		if (consoleLog == null)
			return;

		for (line in text.split('\n'))
			consoleLog.add(line, Secondary);

		consoleLog.keep(400);
	}

	/** Empties the console. */
	public static function clear():Void {
		if (consoleLog != null)
			consoleLog.clear();
	}

	/**
	 * Rewrites the two readouts, at most a few times a second and only while they are up.
	 *
	 * @param dt Seconds since the previous frame.
	 */
	public static function tick(dt:Float):Void {
		if (script == null)
			return;

		since += dt;
		if (since < PERIOD)
			return;

		since = 0;

		if (script.visible && !script.collapsed)
			scriptText.text = describeScripts();

		if (sandbox.visible && !sandbox.collapsed)
			sandboxText.text = describeSandbox();
	}

	/**
	 * What the interpreter and the compiler are doing.
	 *
	 * The counters need their label read: they count the interpreter, and a module the runtime
	 * compiler took runs as bytecode and passes through none of it, so **zero there means compiled,
	 * not idle**. That is why the split sits directly above them.
	 */
	static function describeScripts():String {
		var lines:Array<String> = [];

		if (Sandbox.current == null) {
			lines.push('nothing loaded');
		} else {
			lines.push('project   ${Sandbox.current.name}');
			lines.push('scripts   ${Sandbox.current.scripts.length} file(s)');
			lines.push('classes   ${Sandbox.classes().length}');
			lines.push('');
			lines.push('mode      ${Settings.mode}');
			lines.push(Sandbox.compiled);
		}

		return lines.join('\n');
	}

	/** What the application is doing, which is the frame and the heap and neither is divisible. */
	static function describeSandbox():String {
		return [
			'fps         ${Metrics.fps}',
			'update      ${Metrics.updateMs} ms',
			'draw        ${Metrics.drawMs} ms',
			'draw calls  ${Metrics.drawCalls}',
			'triangles   ${Metrics.triangles}',
			'memory      ${Metrics.memory} MB',
			'',
			'viewport    ${Math.round(Viewport.drawnWidth)}x${Math.round(Viewport.drawnHeight)}  (${Math.round(Viewport.scale * 100)}%)'
		].join('\n');
	}
}
