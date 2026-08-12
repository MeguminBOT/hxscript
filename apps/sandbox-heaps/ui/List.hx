package ui;

import h2d.Graphics;
import h2d.Interactive;
import h2d.Object;
import h2d.Text;

/** One row: what it says, and what the caller wanted to remember about it. */
private typedef Row = {
	var body:Text;
	var hit:Interactive;
};

/**
 * A column of choices, one of which is selected.
 *
 * Clicking selects, and clicking again on what is already selected activates, which is what a list
 * of projects wants: one click to look at it, another to run it.
 */
class List extends Widget {
	/** Which row is selected, or -1 for none. */
	public var index(default, set):Int = -1;

	/** Called when the selection changes. */
	public var onSelect:Int->Void;

	/** Called when the selected row is chosen again. */
	public var onActivate:Int->Void;

	/** How tall a row is, before scaling. */
	public var rowHeight:Float = 26;

	var pane:ScrollPane;
	var marks:Graphics;
	var rows:Array<Row> = [];
	var labels:Array<String> = [];
	var over:Int = -1;
	var size:Int = 13;

	/**
	 * @param parent What to attach to.
	 */
	public function new(?parent:Object) {
		super(parent);
		pane = new ScrollPane(this);
		marks = new Graphics(pane.content);
	}

	/**
	 * Replaces everything in it.
	 *
	 * @param items What the rows say.
	 */
	public function setItems(items:Array<String>):Void {
		for (row in rows) {
			row.body.remove();
			row.hit.remove();
		}
		rows = [];
		labels = items.copy();

		for (i in 0...items.length) {
			var body:Text = new Text(Fonts.at(Theme.fs(size)), pane.content);
			body.text = items[i];

			var hit:Interactive = new Interactive(0, 0, pane.content);
			hit.cursor = Button;

			var slot:Int = i;
			hit.onOver = function(_):Void {
				over = slot;
				paint();
			};
			hit.onOut = function(_):Void {
				if (over == slot)
					over = -1;
				paint();
			};
			hit.onClick = function(_):Void {
				if (!enabled)
					return;

				if (index == slot) {
					if (onActivate != null)
						onActivate(slot);
					return;
				}

				this.index = slot;
				if (onSelect != null)
					onSelect(slot);
			};

			rows.push({body: body, hit: hit});
		}

		if (index >= items.length)
			index = items.length - 1;

		redraw();
	}

	/** @return How many rows there are. */
	public inline function count():Int {
		return labels.length;
	}

	override function redraw():Void {
		canvas.clear();
		if (width <= 0 || height <= 0)
			return;

		fill(Theme.inputBg, width, height);
		outline(Theme.border, width, height);

		var pad:Float = Theme.px(3);
		pane.x = pad;
		pane.y = pad;
		pane.resize(width - pad * 2, height - pad * 2);

		paint();
	}

	/** Lays the rows out and draws what is under them. */
	function paint():Void {
		marks.clear();

		var tall:Float = Theme.px(rowHeight);
		var wide:Float = pane.width;

		for (i in 0...rows.length) {
			var row:Row = rows[i];
			var top:Float = tall * i;

			if (i == index) {
				marks.beginFill(Theme.accent & 0xFFFFFF, 1);
				marks.drawRoundedRect(0, top, wide, tall, Theme.px(4));
				marks.endFill();
			} else if (i == over && enabled) {
				marks.beginFill(Theme.panel2 & 0xFFFFFF, 1);
				marks.drawRoundedRect(0, top, wide, tall, Theme.px(4));
				marks.endFill();
			}

			row.body.font = Fonts.at(Theme.fs(size));
			row.body.textColor = i == index ? 0xFFFFFF : ((enabled ? Theme.text : Theme.text3) & 0xFFFFFF);
			row.body.x = Theme.px(8);
			row.body.y = Math.round(top + (tall - row.body.textHeight) * 0.5);

			row.hit.x = 0;
			row.hit.y = top;
			row.hit.width = wide;
			row.hit.height = tall;
		}

		pane.extent = tall * rows.length;
	}

	function set_index(v:Int):Int {
		index = v;
		paint();
		return v;
	}
}
