package ui;

import h2d.Interactive;
import h2d.Object;
import h2d.Text;

/** A row of choices where exactly one is taken. */
class SegmentedControl extends Widget {
	/** Which one is taken. */
	public var index(default, set):Int = 0;

	/** Called when that changes, with the new index. */
	public var onChange:Int->Void;

	var options:Array<String>;
	var bodies:Array<Text> = [];
	var hits:Array<Interactive> = [];
	var over:Int = -1;
	var size:Int = 12;

	/**
	 * @param options What the choices say.
	 * @param index Which starts taken.
	 * @param onChange Called when that changes.
	 * @param parent What to attach to.
	 */
	public function new(options:Array<String>, index:Int = 0, ?onChange:Int->Void, ?parent:Object) {
		super(parent);
		this.options = options;
		this.onChange = onChange;

		for (i in 0...options.length) {
			var body:Text = new Text(Fonts.at(Theme.fs(size)), this);
			body.text = options[i];
			bodies.push(body);

			var hit:Interactive = new Interactive(0, 0, this);
			hit.cursor = Button;

			var slot:Int = i;
			hit.onOver = function(_):Void {
				over = slot;
				redraw();
			};
			hit.onOut = function(_):Void {
				if (over == slot)
					over = -1;
				redraw();
			};
			hit.onClick = function(_):Void {
				if (!enabled || this.index == slot)
					return;
				this.index = slot;
				if (this.onChange != null)
					this.onChange(slot);
			};

			hits.push(hit);
		}

		this.index = index;
	}

	override function redraw():Void {
		canvas.clear();
		if (width <= 0 || height <= 0 || options.length == 0)
			return;

		fill(Theme.inputBg, width, height);
		outline(Theme.border, width, height);

		var pad:Float = Theme.px(3);
		var inner:Float = width - pad * 2;
		var each:Float = inner / options.length;

		for (i in 0...options.length) {
			var left:Float = pad + each * i;

			if (i == index) {
				canvas.beginFill(Theme.accent & 0xFFFFFF, 1);
				canvas.drawRoundedRect(left, pad, each, height - pad * 2, Theme.px(Theme.radius - 2));
				canvas.endFill();
			} else if (i == over && enabled) {
				canvas.beginFill(Theme.panel2 & 0xFFFFFF, 1);
				canvas.drawRoundedRect(left, pad, each, height - pad * 2, Theme.px(Theme.radius - 2));
				canvas.endFill();
			}

			var body:Text = bodies[i];
			body.font = Fonts.at(Theme.fs(size));
			body.textColor = i == index ? 0xFFFFFF : ((enabled ? Theme.text2 : Theme.text3) & 0xFFFFFF);
			body.x = Math.round(left + (each - body.textWidth) * 0.5);
			body.y = Math.round((height - body.textHeight) * 0.5);

			var hit:Interactive = hits[i];
			hit.x = left;
			hit.y = pad;
			hit.width = each;
			hit.height = height - pad * 2;
		}
	}

	function set_index(v:Int):Int {
		index = v < 0 ? 0 : (v >= options.length ? options.length - 1 : v);
		redraw();
		return index;
	}
}
