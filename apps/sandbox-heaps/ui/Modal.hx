package ui;

import h2d.Interactive;
import h2d.Object;
import h2d.Text;

/**
 * A panel over everything, that has to be answered before anything else can be.
 *
 * The sheet it covers with is not decoration: it takes the pointer, so what is behind cannot be
 * clicked while the question is open. Escape is deliberately not bound to close, for the reason the
 * shell does not claim it either.
 */
class Modal extends Widget {
	/** What to put things in. Its own coordinates start under the title. */
	public var content(default, null):Object;

	/** How wide the panel is, before scaling. */
	public var panelWidth:Float = 420;

	/** How tall the panel is, before scaling. */
	public var panelHeight:Float = 260;

	var sheet:Interactive;
	var panel:Panel;
	var caption:Text;
	var buttons:Array<Button> = [];
	var size:Int = 14;

	/**
	 * @param title What it asks.
	 * @param parent What to attach to.
	 */
	public function new(title:String, ?parent:Object) {
		super(parent);

		sheet = new Interactive(0, 0, this);
		sheet.cursor = Default;
		sheet.backgroundColor = 0xA0000000;

		panel = new Panel(Theme.panel, Theme.border2, this);

		caption = new Text(Fonts.at(Theme.fs(size)), panel);
		caption.text = title;
		caption.textColor = Theme.text & 0xFFFFFF;

		content = new Object(panel);
	}

	/**
	 * Adds a button along the bottom, filled right to left in the order added.
	 *
	 * @param text What it says.
	 * @param onClick What to run.
	 * @param weight How loudly it asks.
	 * @return It.
	 */
	public function addButton(text:String, ?onClick:Void->Void, weight:Weight = Normal):Button {
		var made:Button = new Button(text, onClick, weight, panel);
		buttons.push(made);
		redraw();
		return made;
	}

	override function redraw():Void {
		canvas.clear();
		if (width <= 0 || height <= 0)
			return;

		sheet.width = width;
		sheet.height = height;

		var w:Float = Theme.px(panelWidth);
		var h:Float = Theme.px(panelHeight);

		panel.x = Math.round((width - w) * 0.5);
		panel.y = Math.round((height - h) * 0.5);
		panel.resize(w, h);

		caption.font = Fonts.at(Theme.fs(size));
		caption.x = Theme.px(16);
		caption.y = Theme.px(14);

		content.x = Theme.px(16);
		content.y = Theme.px(46);

		var pad:Float = Theme.px(16);
		var tall:Float = Theme.px(30);
		var gap:Float = Theme.px(8);
		var at:Float = w - pad;

		for (button in buttons) {
			var wide:Float = Theme.px(96);
			at -= wide;
			button.place(Math.round(at), Math.round(h - pad - tall), wide, tall);
			at -= gap;
		}
	}

	/** How much room the content area has, so a caller can lay out inside it. */
	public function inner():{width:Float, height:Float} {
		return {
			width: Theme.px(panelWidth) - Theme.px(32),
			height: Theme.px(panelHeight) - Theme.px(46) - Theme.px(62)
		};
	}
}
