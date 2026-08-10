package studio;

import smidr.UIComponent;
import smidr.UIRoot;
import smidr.widgets.UILabel;
import smidr.widgets.UIPanel;

/**
 * A strip of UI that stays above whatever is running.
 *
 * A shell that covers the thing it is running is worse than no shell, so a file browser over somebody's game
 * is not information, it is furniture. But there is a narrow band of things worth seeing *while* a project
 * runs, such as a value it is computing, a state it thinks it is in, or how fast it is going, and no good
 * place to put them. A project can draw its own readout, and every project doing that writes the same code.
 *
 * So this is the place. It is SmidrUI, which means a project reaches it the same way the shell does,
 * and it is a sibling of the shell's panes rather than a part of them, so hiding one does not hide the
 * other.
 *
 * Two ways in, and they answer different needs:
 *
 * - `set` names a value and shows it, replacing whatever that name showed before. This is what a
 *   frame-by-frame readout wants, and it is one call with nothing to hold on to.
 * - `content` is an empty container. Anything SmidrUI can build goes in it, such as a slider that
 *   drives a constant or a button that resets the thing being tested. This is what a project
 *   outgrowing a readout wants.
 *
 * Off by default, like everything else here that takes screen away from a project.
 */
class Overlay {
	/** Left edge and gap, matching the shell's own padding. */
	static inline var PAD:Float = 8;

	/** Height of one readout line. */
	static inline var LINE:Float = 16;

	/** Width of the panel. */
	static inline var WIDTH:Float = 240;

	/** Everything below, so the shell can show and hide it in one move. */
	public static var layer(default, null):UIComponent = null;

	/**
	 * Where a project puts widgets of its own.
	 *
	 * Positioned below the readout lines and left alone otherwise: what goes in it, where, and how big
	 * is the project's business. It is emptied when a project stops, so nothing survives into the next.
	 */
	public static var content(default, null):UIComponent = null;

	/** The readout labels, by the name they were set under. */
	static var rows:Map<String, UILabel> = [];

	/** The order they were first set in, so a value does not move when another changes. */
	static var order:Array<String> = [];

	static var panel:UIPanel = null;
	static var frames:Int = 0;
	static var since:Float = 0;

	/**
	 * Builds the layer, once.
	 *
	 * @param root The UI the shell mounted.
	 */
	public static function mount(root:UIRoot):Void {
		if (layer != null)
			return;

		layer = new UIComponent(false, false);
		layer.visible = false;
		root.content.addChild(layer);

		layer.y = Viewport.TOP;

		panel = new UIPanel(WIDTH, PAD * 2);
		panel.x = PAD;
		panel.y = PAD;
		layer.addChild(panel);

		content = new UIComponent(false, false);
		content.x = PAD;
		content.y = PAD;
		layer.addChild(content);
	}

	/**
	 * Shows the overlay for a run, if the settings allow it.
	 *
	 * @param project The project's name, so there is something in it before the project says anything.
	 */
	public static function begin(project:String):Void {
		if (layer == null)
			return;

		clear();
		set('project', project);
		layer.visible = Settings.overlay;
	}

	/** Hides it and drops everything a project put in it. */
	public static function end():Void {
		if (layer == null)
			return;

		layer.visible = false;
		clear();
	}

	/** Whether it is currently on screen. */
	public static function shown():Bool {
		return layer != null && layer.visible;
	}

	/**
	 * Shows it or hides it, without changing what the settings say.
	 *
	 * The distinction matters: this is the key binding, which is a thing somebody does mid-run and
	 * expects to undo mid-run, not a preference they are editing.
	 */
	public static function toggle():Void {
		show(layer != null && !layer.visible);
	}

	/**
	 * Shows or hides it now.
	 *
	 * @param on Whether it should be on screen.
	 */
	public static function show(on:Bool):Void {
		if (layer != null)
			layer.visible = on;
	}

	/**
	 * Sets a named readout line.
	 *
	 * @param name What it is. Setting the same name again replaces the value rather than adding a line.
	 * @param value Anything; stringified.
	 */
	public static function set(name:String, value:Dynamic):Void {
		if (layer == null)
			return;

		var text:String = name + '   ' + Std.string(value);
		var row:UILabel = rows.get(name);

		if (row != null) {
			row.text = text;
			return;
		}

		row = new UILabel(text, 11);
		row.x = PAD * 2;
		row.y = PAD * 2 + order.length * LINE;
		panel.addChild(row);

		rows.set(name, row);
		order.push(name);
		layout();
	}

	/** Drops every readout line and everything in `content`. */
	public static function clear():Void {
		if (layer == null)
			return;

		for (row in rows)
			panel.removeChild(row);

		rows = [];
		order = [];

		while (content.numChildren > 0)
			content.removeChild(content.getChildAt(0));

		layout();
	}

	/**
	 * Updates the frame counter and keeps the panel the size of what is in it.
	 *
	 * @param elapsed Seconds since the previous frame.
	 */
	public static function tick(elapsed:Float):Void {
		if (layer == null || !layer.visible)
			return;

		frames++;
		since += elapsed;

		if (since < 0.5)
			return;

		set('fps', Math.round(frames / since));
		frames = 0;
		since = 0;
	}

	/** Resizes the panel to its rows and puts `content` below it. */
	static function layout():Void {
		var height:Float = PAD * 3 + order.length * LINE;

		panel.resize(WIDTH, height);
		content.y = PAD + height + PAD;
	}
}
