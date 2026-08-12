package ui;

import h2d.Interactive;
import h2d.Object;
import h2d.Text;
import hxd.Key;

/**
 * A control that shows a key and takes a new one when clicked.
 *
 * Zero means unbound, and that is a value rather than a gap: the sandbox binds two of its four
 * shortcuts to nothing on purpose, because a key the shell claims is a key a project never sees.
 */
class Keybind extends Widget {
	/** The key code, or zero for unbound. */
	public var code(default, set):Int = 0;

	/** Called when it changes. */
	public var onChange:Int->Void;

	/** Whether it is waiting for a key. */
	public var listening(default, null):Bool = false;

	var caption:Text;
	var shown:Text;
	var hit:Interactive;
	var over:Bool = false;
	var size:Int = 13;

	/**
	 * @param label What the binding is for.
	 * @param code The key it starts on, or zero.
	 * @param onChange Called when it changes.
	 * @param parent What to attach to.
	 */
	public function new(label:String, code:Int = 0, ?onChange:Int->Void, ?parent:Object) {
		super(parent);
		this.onChange = onChange;

		caption = new Text(Fonts.at(Theme.fs(size)), this);
		caption.text = label;
		caption.textColor = Theme.text2 & 0xFFFFFF;

		shown = new Text(Fonts.at(Theme.fs(size)), this);

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
			listening = true;
			hit.focus();
			redraw();
		};
		hit.onFocusLost = function(_):Void {
			listening = false;
			redraw();
		};
		hit.onKeyDown = function(e:hxd.Event):Void {
			if (!listening)
				return;

			listening = false;
			this.code = e.keyCode == Key.ESCAPE ? 0 : e.keyCode;

			if (this.onChange != null)
				this.onChange(this.code);

			hit.blur();
		};

		this.code = code;
	}

	override function redraw():Void {
		canvas.clear();
		if (width <= 0 || height <= 0)
			return;

		caption.font = Fonts.at(Theme.fs(size));
		shown.font = Fonts.at(Theme.fs(size));

		var box:Float = Theme.px(120);
		var left:Float = width - box;

		caption.x = 0;
		caption.y = Math.round((height - caption.textHeight) * 0.5);

		var face:Int = listening ? Theme.accentDark : (over && enabled ? Theme.panel3 : Theme.inputBg);

		canvas.beginFill(face & 0xFFFFFF, 1);
		canvas.drawRoundedRect(left, 0, box, height, Theme.px(Theme.radius - 2));
		canvas.endFill();

		canvas.lineStyle(Theme.px(1), (listening ? Theme.accent : Theme.border) & 0xFFFFFF, 1);
		canvas.drawRoundedRect(left, 0, box, height, Theme.px(Theme.radius - 2));
		canvas.lineStyle();

		shown.text = listening ? 'press a key' : nameOf(code);
		shown.textColor = (listening ? Theme.highlight : (code == 0 ? Theme.text3 : Theme.text)) & 0xFFFFFF;
		shown.x = Math.round(left + (box - shown.textWidth) * 0.5);
		shown.y = Math.round((height - shown.textHeight) * 0.5);

		hit.x = left;
		hit.y = 0;
		hit.width = box;
		hit.height = height;
	}

	/**
	 * @param code A key code, or zero.
	 * @return What to call it, with zero reading as what it means rather than as a number.
	 */
	public static function nameOf(code:Int):String {
		if (code == 0)
			return 'unbound';

		var known:String = Key.getKeyName(code);
		return known == null ? 'key ' + code : known;
	}

	function set_code(v:Int):Int {
		code = v;
		redraw();
		return v;
	}
}
