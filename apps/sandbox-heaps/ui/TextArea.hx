package ui;

import h2d.Object;
import h2d.Text;

/**
 * Text that is read rather than written, as much of it as there is.
 *
 * The log. It keeps the lines rather than one string so a line can carry its own emphasis, which is
 * what makes an error visibly one without anything having to parse the log back out again.
 */
class TextArea extends Widget {
	/** Whether new lines scroll the view to the bottom. */
	public var follow(get, set):Bool;

	var pane:ScrollPane;
	var lines:Array<Text> = [];
	var size:Int = 12;

	/**
	 * @param parent What to attach to.
	 */
	public function new(?parent:Object) {
		super(parent);
		pane = new ScrollPane(this);
		pane.follow = true;
	}

	/**
	 * Adds a line at the bottom.
	 *
	 * @param text What it says.
	 * @param emphasis How much it is asking to be read.
	 */
	public function add(text:String, emphasis:Emphasis = Secondary):Void {
		var body:Text = new Text(Fonts.at(Theme.fs(size)), pane.content);
		body.text = text;
		body.textColor = colourFor(emphasis);
		body.maxWidth = pane.width > 0 ? pane.width - Theme.px(10) : -1;
		lines.push(body);
		reflow();
	}

	/** Drops every line. */
	public function clear():Void {
		for (line in lines)
			line.remove();
		lines = [];
		reflow();
	}

	/** @return How many lines there are, for a caller that trims its own history. */
	public inline function count():Int {
		return lines.length;
	}

	/** Drops the oldest lines until only this many are left. */
	public function keep(most:Int):Void {
		while (lines.length > most) {
			var gone:Text = lines.shift();
			gone.remove();
		}
		reflow();
	}

	override function redraw():Void {
		canvas.clear();
		if (width <= 0 || height <= 0)
			return;

		fill(Theme.inputBg, width, height);
		outline(Theme.border, width, height);

		var pad:Float = Theme.px(5);
		pane.x = pad;
		pane.y = pad;
		pane.resize(width - pad * 2, height - pad * 2);

		for (line in lines)
			line.maxWidth = pane.width - Theme.px(6);

		reflow();
	}

	/** Stacks the lines, which have their own heights once they have wrapped. */
	function reflow():Void {
		var at:Float = 0;

		for (line in lines) {
			line.x = Theme.px(3);
			line.y = Math.round(at);
			at += line.textHeight + Theme.px(2);
		}

		pane.extent = at;
	}

	function get_follow():Bool {
		return pane.follow;
	}

	function set_follow(v:Bool):Bool {
		return pane.follow = v;
	}

	static function colourFor(e:Emphasis):Int {
		return switch (e) {
			case Primary: Theme.text & 0xFFFFFF;
			case Secondary: Theme.text2 & 0xFFFFFF;
			case Muted: Theme.text3 & 0xFFFFFF;
			case Good: Theme.success & 0xFFFFFF;
			case Bad: Theme.danger & 0xFFFFFF;
			case Warn: Theme.warning & 0xFFFFFF;
		}
	}
}
