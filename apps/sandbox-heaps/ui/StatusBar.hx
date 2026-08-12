package ui;

import h2d.Object;
import h2d.Text;

/**
 * The line along the bottom saying what the app is doing.
 *
 * One string, because that is what the sandbox for lime shows and the two have to read the same. It
 * carries an emphasis so an error is visibly one without a second widget.
 */
class StatusBar extends Widget {
	/** What it says. */
	public var text(get, set):String;

	/** How much it is asking to be read. */
	public var emphasis(default, set):Emphasis = Secondary;

	var body:Text;
	var size:Int = 12;

	/**
	 * @param parent What to attach to.
	 */
	public function new(?parent:Object) {
		super(parent);
		body = new Text(Fonts.at(Theme.fs(size)), this);
		body.text = '';
		body.textColor = Theme.text2 & 0xFFFFFF;
	}

	override function redraw():Void {
		canvas.clear();
		if (width <= 0 || height <= 0)
			return;

		fill(Theme.panel, width, height, 0);

		canvas.beginFill(Theme.border & 0xFFFFFF, 1);
		canvas.drawRect(0, 0, width, Theme.px(1));
		canvas.endFill();

		body.font = Fonts.at(Theme.fs(size));
		body.x = Theme.px(10);
		body.y = Math.round((height - body.textHeight) * 0.5);
	}

	function get_text():String {
		return body.text;
	}

	function set_text(v:String):String {
		if (body.text != v) {
			body.text = v;
			redraw();
		}
		return v;
	}

	function set_emphasis(v:Emphasis):Emphasis {
		emphasis = v;
		if (body != null) {
			body.textColor = switch (v) {
				case Primary: Theme.text & 0xFFFFFF;
				case Secondary: Theme.text2 & 0xFFFFFF;
				case Muted: Theme.text3 & 0xFFFFFF;
				case Good: Theme.success & 0xFFFFFF;
				case Bad: Theme.danger & 0xFFFFFF;
				case Warn: Theme.warning & 0xFFFFFF;
			}
		}
		return v;
	}
}
