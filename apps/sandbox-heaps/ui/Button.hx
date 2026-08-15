package ui;

import h2d.Interactive;
import h2d.Object;
import h2d.Text;

/** A rectangle that runs something when it is clicked. */
class Button extends Widget {
	/** What it says. */
	public var text(get, set):String;

	/** How loudly it asks. */
	public var weight(default, set):Weight = Normal;

	/** What to run. */
	public var onClick:Void->Void;

	var body:Text;
	var hit:Interactive;
	var over:Bool = false;
	var down:Bool = false;
	var size:Int;

	/**
	 * @param value What it says.
	 * @param onClick What to run when it is pressed.
	 * @param weight How loudly it asks.
	 * @param parent What to attach to.
	 */
	public function new(value:String, ?onClick:Void->Void, weight:Weight = Normal, ?parent:Object) {
		super(parent);
		this.onClick = onClick;
		this.weight = weight;
		this.size = 13;

		body = new Text(Fonts.at(Theme.fs(size)), this);
		body.text = value;

		hit = new Interactive(0, 0, this);
		hit.cursor = Button;
		hit.onOver = function(_):Void {
			over = true;
			redraw();
		};
		hit.onOut = function(_):Void {
			over = false;
			down = false;
			redraw();
		};
		hit.onPush = function(_):Void {
			down = true;
			redraw();
		};
		hit.onRelease = function(_):Void {
			down = false;
			redraw();
		};
		hit.onClick = function(_):Void {
			if (enabled && this.onClick != null)
				this.onClick();
		};
	}

	override function redraw():Void {
		canvas.clear();
		if (width <= 0 || height <= 0)
			return;

		hit.width = width;
		hit.height = height;

		var face:Int = surface();
		fill(face, width, height);

		if (weight != Strong && weight != Destructive)
			outline(enabled ? Theme.border : Theme.border & 0x60FFFFFF, width, height);

		body.font = Fonts.at(Theme.fs(size));
		body.textColor = ink();
		body.x = Math.round((width - body.textWidth) * 0.5);
		body.y = Math.round((height - body.textHeight) * 0.5);
	}

	/** @return What the body is filled with, given weight and what the pointer is doing. */
	function surface():Int {
		if (!enabled)
			return Theme.panel2;

		return switch (weight) {
			case Strong: down ? Theme.accentDark : (over ? lift(Theme.accent) : Theme.accent);
			case Destructive: down ? shade(Theme.danger) : (over ? lift(Theme.danger) : Theme.danger);
			case Quiet: down ? Theme.panel2 : (over ? Theme.panel2 : Theme.panel);
			case Normal: down ? Theme.panel2 : (over ? Theme.panel3 : Theme.panel2);
		}
	}

	/** @return What the text is drawn in. */
	function ink():Int {
		if (!enabled)
			return Theme.text3 & 0xFFFFFF;

		return switch (weight) {
			case Strong | Destructive: 0xFFFFFF;
			case _: Theme.text & 0xFFFFFF;
		}
	}

	/** @return A colour a step brighter, for a hover. */
	static function lift(c:Int):Int {
		return blend(c, 0xFFFFFFFF, 0.12);
	}

	/** @return A colour a step darker, for a press. */
	static function shade(c:Int):Int {
		return blend(c, 0xFF000000, 0.18);
	}

	/** @return Two colours mixed, keeping the first one's alpha. */
	static function blend(a:Int, b:Int, amount:Float):Int {
		var ar:Int = (a >> 16) & 0xFF;
		var ag:Int = (a >> 8) & 0xFF;
		var ab:Int = a & 0xFF;

		var br:Int = (b >> 16) & 0xFF;
		var bg:Int = (b >> 8) & 0xFF;
		var bb:Int = b & 0xFF;

		var r:Int = Math.round(ar + (br - ar) * amount);
		var g:Int = Math.round(ag + (bg - ag) * amount);
		var bl:Int = Math.round(ab + (bb - ab) * amount);

		return (a & 0xFF000000) | (r << 16) | (g << 8) | bl;
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

	function set_weight(v:Weight):Weight {
		weight = v;
		redraw();
		return v;
	}
}
