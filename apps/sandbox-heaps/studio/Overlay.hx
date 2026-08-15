package studio;

import h2d.Object;
import ui.Label;
import ui.Panel;
import ui.Root;
import ui.Theme;

/**
 * A strip that stays above a running project, for the things worth watching while it runs.
 *
 * Off by default, like everything else the shell could put on a project's screen. A prototyping app
 * is not the subject; the thing being prototyped is.
 *
 * `info` is the cheap half and is meant to be called every frame: naming a value means its label is
 * built once and only the text changes afterwards. `surface` is the other half, for a project that
 * has outgrown a readout and wants a control of its own. Everything a project adds is dropped when
 * it stops, so nothing of one run reaches the next.
 */
class Overlay {
	static var root:Root;
	static var strip:Panel;
	static var title:Label;
	static var host:Object;
	static var names:Array<String> = [];
	static var values:Map<String, Label> = new Map();
	static var running:Bool = false;

	/**
	 * Builds it, hidden.
	 *
	 * @param into Where it lives, which is above the project and below the panels.
	 */
	public static function mount(into:Root):Void {
		root = into;

		strip = new Panel(Theme.panel, Theme.border, into.content);
		strip.visible = false;

		title = new Label('', 12, Muted, strip);
		host = new Object(strip);
	}

	/**
	 * A run started.
	 *
	 * @param project What is running, shown at the left so a strip with nothing in it still says
	 *        what it belongs to.
	 */
	public static function begin(project:String):Void {
		running = true;
		title.text = project;
		clear();
		refresh();
	}

	/** A run ended. Everything the project added goes with it. */
	public static function end():Void {
		running = false;
		clear();
		refresh();
	}

	/** @return Whether anyone is looking, so a project can skip the work of filling it. */
	public static function shown():Bool {
		return running && Settings.overlay;
	}

	/** Shows or hides it, and remembers which. */
	public static function toggle():Void {
		Settings.overlay = !Settings.overlay;
		Settings.save();
		refresh();
	}

	/**
	 * Sets whether it is shown.
	 *
	 * @param on Whether to show it.
	 */
	public static function show(on:Bool):Void {
		Settings.overlay = on;
		refresh();
	}

	/**
	 * Puts a named value on the strip, replacing what was there under that name.
	 *
	 * @param name What to call it.
	 * @param value What it is now.
	 */
	public static function set(name:String, value:Dynamic):Void {
		if (strip == null)
			return;

		var line:Label = values.get(name);

		if (line == null) {
			line = new Label('', 12, Secondary, host);
			values.set(name, line);
			names.push(name);
			layout();
		}

		line.text = '$name  ${Std.string(value)}';
	}

	/** Drops every named value, and anything a project put in `surface`. */
	public static function clear():Void {
		for (line in values)
			line.remove();

		values = new Map();
		names = [];

		if (host != null)
			host.removeChildren();

		layout();
	}

	/** @return Where a project puts a control of its own. */
	public static function surface():Object {
		return host;
	}

	/**
	 * @param dt Seconds since the previous frame.
	 */
	public static function tick(dt:Float):Void {}

	/** Puts it where it goes and sizes it to what is on it. */
	public static function layout():Void {
		if (strip == null || root == null)
			return;

		var tall:Float = Theme.px(26);

		strip.place(0, Viewport.TOP, root.width, tall);

		title.rescale();
		title.x = Theme.px(10);
		title.y = Math.round((tall - title.textHeight) * 0.5);

		var at:Float = Theme.px(120);

		for (name in names) {
			var line:Label = values.get(name);
			if (line == null)
				continue;

			line.rescale();
			line.x = at;
			line.y = Math.round((tall - line.textHeight) * 0.5);
			at += line.textWidth + Theme.px(18);
		}
	}

	/** Puts `Settings.overlay` into effect. */
	static function refresh():Void {
		if (strip != null)
			strip.visible = shown();

		layout();
	}
}
