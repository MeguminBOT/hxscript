package ui;

import h2d.Interactive;
import h2d.Object;
import h2d.Text;

/**
 * A panel with a title bar, that can be moved, collapsed and closed.
 *
 * The three readouts the sandbox puts over its window are these. Dragging is captured at the scene
 * rather than tracked on the bar, because a window followed only while the pointer stays over its own
 * title bar is one that gets dropped the moment it is moved quickly.
 */
class Window extends Widget {
	/** What to put things in. Its own coordinates start under the title bar. */
	public var content(default, null):Object;

	/** Whether the body is hidden and only the bar is showing. */
	public var collapsed(default, set):Bool = false;

	/** How tall the body is when it is not collapsed. */
	public var bodyHeight:Float = 0;

	/** Called when the close button is pressed. */
	public var onClose:Void->Void;

	/** How tall the title bar is, before scaling. */
	public static inline var BAR:Float = 26;

	var caption:Text;
	var chevron:Text;
	var cross:Text;
	var grip:Interactive;
	var foldHit:Interactive;
	var closeHit:Interactive;
	var holding:Bool = false;
	var grabX:Float = 0;
	var grabY:Float = 0;
	var size:Int = 12;

	/**
	 * @param title What the bar says.
	 * @param parent What to attach to.
	 */
	public function new(title:String, ?parent:Object) {
		super(parent);

		content = new Object(this);

		grip = new Interactive(0, 0, this);
		grip.cursor = Move;
		grip.onPush = function(_):Void take();

		caption = new Text(Fonts.at(Theme.fs(size)), this);
		caption.text = title;
		caption.textColor = Theme.text & 0xFFFFFF;

		chevron = new Text(Fonts.at(Theme.fs(size)), this);
		chevron.textColor = Theme.text2 & 0xFFFFFF;

		cross = new Text(Fonts.at(Theme.fs(size)), this);
		cross.text = 'x';
		cross.textColor = Theme.text2 & 0xFFFFFF;

		foldHit = new Interactive(0, 0, this);
		foldHit.cursor = Button;
		foldHit.onClick = function(_):Void collapsed = !collapsed;

		closeHit = new Interactive(0, 0, this);
		closeHit.cursor = Button;
		closeHit.onClick = function(_):Void {
			if (onClose != null)
				onClose();
		};
	}

	override function redraw():Void {
		canvas.clear();
		if (width <= 0)
			return;

		var bar:Float = Theme.px(BAR);
		var whole:Float = collapsed ? bar : height;
		var r:Float = Theme.px(Theme.radius);

		fill(Theme.panel, width, whole, r);
		outline(Theme.border, width, whole, r);

		canvas.beginFill(Theme.panel2 & 0xFFFFFF, 1);
		canvas.drawRoundedRect(0, 0, width, bar, r);
		if (!collapsed)
			canvas.drawRect(0, bar - r, width, r);
		canvas.endFill();

		caption.font = Fonts.at(Theme.fs(size));
		caption.x = Theme.px(10);
		caption.y = Math.round((bar - caption.textHeight) * 0.5);

		chevron.font = Fonts.at(Theme.fs(size));
		chevron.text = collapsed ? '+' : '-';
		chevron.x = width - Theme.px(44);
		chevron.y = Math.round((bar - chevron.textHeight) * 0.5);

		cross.font = Fonts.at(Theme.fs(size));
		cross.x = width - Theme.px(20);
		cross.y = Math.round((bar - cross.textHeight) * 0.5);

		grip.width = width - Theme.px(52);
		grip.height = bar;

		foldHit.x = width - Theme.px(50);
		foldHit.y = 0;
		foldHit.width = Theme.px(26);
		foldHit.height = bar;

		closeHit.x = width - Theme.px(26);
		closeHit.y = 0;
		closeHit.width = Theme.px(26);
		closeHit.height = bar;

		content.y = bar;
		content.visible = !collapsed;
	}

	/** Starts following the pointer, until it is let go. */
	function take():Void {
		var scene:h2d.Scene = getScene();
		if (scene == null || holding)
			return;

		holding = true;
		grabX = scene.mouseX - x;
		grabY = scene.mouseY - y;

		scene.startCapture(function(e:hxd.Event):Void {
			switch (e.kind) {
				case ERelease, EReleaseOutside:
					holding = false;
					scene.stopCapture();

				case EMove, EPush:
					x = Math.round(scene.mouseX - grabX);
					y = Math.round(scene.mouseY - grabY);

				case _:
			}
		}, function():Void {
			holding = false;
		});
	}

	/** Holds the window inside a region, for after the window it sits in has been resized. */
	public function keepInside(w:Float, h:Float):Void {
		var bar:Float = Theme.px(BAR);

		if (x > w - Theme.px(60))
			x = w - Theme.px(60);
		if (y > h - bar)
			y = h - bar;
		if (x < 0)
			x = 0;
		if (y < 0)
			y = 0;
	}

	function set_collapsed(v:Bool):Bool {
		collapsed = v;
		redraw();
		return v;
	}
}
