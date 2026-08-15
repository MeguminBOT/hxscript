package ui;

import h2d.Graphics;
import h2d.Interactive;
import h2d.Object;
import h2d.Text;

/** A box that is either ticked or not, with a label beside it. */
class Checkbox extends Widget {
	/** Whether it is ticked. */
	public var checked(default, set):Bool = false;

	/** Called when it changes, with the new value. */
	public var onChange:Bool->Void;

	var body:Text;
	var tick:Graphics;
	var hit:Interactive;
	var over:Bool = false;
	var size:Int = 13;

	/**
	 * @param value What the label says.
	 * @param checked Whether it starts ticked.
	 * @param onChange Called when it changes.
	 * @param parent What to attach to.
	 */
	public function new(value:String, checked:Bool = false, ?onChange:Bool->Void, ?parent:Object) {
		super(parent);
		this.onChange = onChange;

		body = new Text(Fonts.at(Theme.fs(size)), this);
		body.text = value;
		body.textColor = Theme.text & 0xFFFFFF;

		tick = new Graphics(this);

		hit = new Interactive(0, 0, this);
		hit.cursor = Button;
		hit.onOver = function(_):Void {
			over = true;
			redraw();
		};
		hit.onOut = function(_):Void {
			over = false;
			redraw();
		};
		hit.onClick = function(_):Void {
			if (!enabled)
				return;
			this.checked = !this.checked;
			if (this.onChange != null)
				this.onChange(this.checked);
		};

		this.checked = checked;
	}

	override function redraw():Void {
		canvas.clear();
		tick.clear();

		if (width <= 0 || height <= 0)
			return;

		hit.width = width;
		hit.height = height;

		var box:Float = Theme.px(16);
		var top:Float = Math.round((height - box) * 0.5);
		var r:Float = Theme.px(4);

		canvas.beginFill((checked ? Theme.accent : Theme.inputBg) & 0xFFFFFF, 1);
		canvas.drawRoundedRect(0, top, box, box, r);
		canvas.endFill();

		var line:Int = checked ? Theme.accent : (over ? Theme.border2 : Theme.border);
		canvas.lineStyle(Theme.px(1), line & 0xFFFFFF, 1);
		canvas.drawRoundedRect(0, top, box, box, r);
		canvas.lineStyle();

		if (checked) {
			tick.lineStyle(Theme.px(2), 0xFFFFFF, 1);
			tick.moveTo(box * 0.24, top + box * 0.52);
			tick.lineTo(box * 0.44, top + box * 0.72);
			tick.lineTo(box * 0.78, top + box * 0.28);
			tick.lineStyle();
		}

		body.font = Fonts.at(Theme.fs(size));
		body.textColor = (enabled ? Theme.text : Theme.text3) & 0xFFFFFF;
		body.x = box + Theme.px(9);
		body.y = Math.round((height - body.textHeight) * 0.5);
	}

	function set_checked(v:Bool):Bool {
		checked = v;
		redraw();
		return v;
	}
}
