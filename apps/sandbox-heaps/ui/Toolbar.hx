package ui;

import h2d.Object;

/** One thing sitting in a bar, and how wide it asked to be. */
private typedef Slot = {
	var widget:Null<Widget>;
	var width:Float;
	var spacer:Bool;
};

/**
 * A bar of buttons along the top, filled left to right.
 *
 * A spacer takes whatever is left over, so what is added after one is pushed to the right edge and
 * stays there as the window changes width.
 */
class Toolbar extends Widget {
	var slots:Array<Slot> = [];
	var pad:Float = 8;
	var gap:Float = 6;

	/**
	 * @param parent What to attach to.
	 */
	public function new(?parent:Object) {
		super(parent);
	}

	/**
	 * Adds a button.
	 *
	 * @param text What it says.
	 * @param width How wide, in design pixels.
	 * @param onClick What to run.
	 * @param weight How loudly it asks.
	 * @return It, for a caller that wants to keep hold of it.
	 */
	public function addButton(text:String, width:Float, ?onClick:Void->Void, weight:Weight = Quiet):Button {
		var made:Button = new Button(text, onClick, weight, this);
		slots.push({widget: made, width: width, spacer: false});
		redraw();
		return made;
	}

	/** Adds a label, for a bar that says something as well as offering things. */
	public function addLabel(text:String, width:Float, emphasis:Emphasis = Secondary):Label {
		var made:Label = new Label(text, 12, emphasis, this);
		slots.push({widget: made, width: width, spacer: false});
		redraw();
		return made;
	}

	/** Adds the gap that pushes everything after it to the right. */
	public function addSpacer():Void {
		slots.push({widget: null, width: 0, spacer: true});
		redraw();
	}

	override function redraw():Void {
		canvas.clear();
		if (width <= 0 || height <= 0)
			return;

		fill(Theme.panel, width, height, 0);

		canvas.beginFill(Theme.border & 0xFFFFFF, 1);
		canvas.drawRect(0, height - Theme.px(1), width, Theme.px(1));
		canvas.endFill();

		var padding:Float = Theme.px(pad);
		var spacing:Float = Theme.px(gap);

		var fixed:Float = 0;
		var spacers:Int = 0;

		for (slot in slots) {
			if (slot.spacer)
				spacers++;
			else
				fixed += Theme.px(slot.width) + spacing;
		}

		var slack:Float = width - padding * 2 - fixed;
		if (slack < 0)
			slack = 0;

		var share:Float = spacers == 0 ? 0 : slack / spacers;
		var at:Float = padding;
		var tall:Float = height - padding * 2;

		for (slot in slots) {
			if (slot.spacer) {
				at += share;
				continue;
			}

			var w:Float = Theme.px(slot.width);

			if (slot.widget != null) {
				slot.widget.x = Math.round(at);

				if (slot.widget is Label) {
					var it:Label = cast slot.widget;
					it.rescale();
					slot.widget.y = Math.round((height - it.textHeight) * 0.5);
				} else {
					slot.widget.y = Math.round(padding);
					slot.widget.resize(w, tall);
				}
			}

			at += w + spacing;
		}
	}
}
