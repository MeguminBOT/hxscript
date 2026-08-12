package ui;

import h2d.Object;
import h2d.Text;

/** A run of text, at a size and an emphasis. */
class Label extends Widget {
	/** What it says. */
	public var text(get, set):String;

	/** How much it is asking to be read. */
	public var emphasis(default, set):Emphasis;

	/** Wraps at this width when it is above zero. */
	public var wrapAt(default, set):Float = 0;

	/** How wide the text actually came out. */
	public var textWidth(get, never):Float;

	/** How tall the text actually came out, which is what a wrapped label is measured by. */
	public var textHeight(get, never):Float;

	var body:Text;
	var size:Int;

	/**
	 * @param value What it says.
	 * @param size The text size in design pixels.
	 * @param emphasis How much it is asking to be read.
	 * @param parent What to attach to.
	 */
	public function new(value:String, size:Int = 13, emphasis:Emphasis = Primary, ?parent:Object) {
		super(parent);
		this.size = size;
		this.emphasis = emphasis;

		body = new Text(Fonts.at(Theme.fs(size)), this);
		body.text = value;
		body.textColor = colourFor(emphasis);
	}

	/** Rebuilds the face, for when the theme's scale or boost has moved. */
	public function rescale():Void {
		body.font = Fonts.at(Theme.fs(size));
	}

	function get_text():String {
		return body.text;
	}

	function set_text(v:String):String {
		if (body.text != v)
			body.text = v;
		return v;
	}

	function set_emphasis(v:Emphasis):Emphasis {
		emphasis = v;
		if (body != null)
			body.textColor = colourFor(v);
		return v;
	}

	function set_wrapAt(v:Float):Float {
		wrapAt = v;
		if (body != null)
			body.maxWidth = v <= 0 ? -1 : v;
		return v;
	}

	function get_textWidth():Float {
		return body.textWidth;
	}

	function get_textHeight():Float {
		return body.textHeight;
	}

	/** @return The colour an emphasis means, which is the theme's and nothing of this class's own. */
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
