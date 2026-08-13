package ui;

import h2d.Object;
import h2d.Text;

/**
 * A line of text with a name beside it.
 *
 * The editing is heaps' own `h2d.TextInput`, which already has a caret, a selection and the platform
 * key handling. What this adds is the label, the box it sits in and the theme.
 */
class TextInput extends Widget {
	/** What is in it. */
	public var value(get, set):String;

	/** How wide the editable part is. The label takes whatever is left. */
	public var controlWidth:Float = 0;

	/** Called as it changes. */
	public var onChange:String->Void;

	var caption:Text;
	var field:h2d.TextInput;
	var size:Int = 13;

	/**
	 * @param label What the field is called, or empty for a field with no name.
	 * @param value What it starts with.
	 * @param onChange Called as it changes.
	 * @param parent What to attach to.
	 */
	public function new(label:String = '', value:String = '', ?onChange:String->Void, ?parent:Object) {
		super(parent);
		this.onChange = onChange;

		caption = new Text(Fonts.at(Theme.fs(size)), this);
		caption.text = label;
		caption.textColor = Theme.text2 & 0xFFFFFF;

		field = new h2d.TextInput(Fonts.at(Theme.fs(size)), this);
		field.text = value;
		field.textColor = Theme.text & 0xFFFFFF;
		field.onChange = function():Void {
			if (this.onChange != null)
				this.onChange(field.text);
		};
	}

	/** Puts the caret in it. */
	public function focus():Void {
		field.focus();
	}

	override function redraw():Void {
		canvas.clear();
		if (width <= 0 || height <= 0)
			return;

		caption.font = Fonts.at(Theme.fs(size));
		field.font = Fonts.at(Theme.fs(size));

		var gap:Float = caption.text.length == 0 ? 0 : Theme.px(8);
		var named:Float = caption.text.length == 0 ? 0 : caption.textWidth + gap;
		var box:Float = controlWidth > 0 ? controlWidth : width - named;

		if (box < Theme.px(40))
			box = Theme.px(40);

		var left:Float = width - box;

		caption.x = 0;
		caption.y = Math.round((height - caption.textHeight) * 0.5);

		canvas.beginFill(Theme.inputBg & 0xFFFFFF, 1);
		canvas.drawRoundedRect(left, 0, box, height, Theme.px(Theme.radius - 2));
		canvas.endFill();

		canvas.lineStyle(Theme.px(1), Theme.border & 0xFFFFFF, 1);
		canvas.drawRoundedRect(left, 0, box, height, Theme.px(Theme.radius - 2));
		canvas.lineStyle();

		field.x = left + Theme.px(7);
		field.y = Math.round((height - field.textHeight) * 0.5);
		field.inputWidth = Std.int(box - Theme.px(14));
	}

	function get_value():String {
		return field.text;
	}

	function set_value(v:String):String {
		if (field.text != v)
			field.text = v;
		return v;
	}
}
