package ui;

import h2d.Interactive;
import h2d.Mask;
import h2d.Object;

/**
 * A window onto something taller than itself.
 *
 * Whatever is added goes into `content`, which is clipped to the pane and moved rather than resized,
 * so a caller lays its contents out once at whatever height they come to and never has to know how
 * much of them is visible.
 */
class ScrollPane extends Widget {
	/** What to put things in. */
	public var content(default, null):Object;

	/** How tall the contents are. Set it after filling them in. */
	public var extent(default, set):Float = 0;

	/** How far down it is scrolled. */
	public var offset(default, set):Float = 0;

	/** Whether to sit at the bottom when the contents grow, which is what a log wants. */
	public var follow:Bool = false;

	var mask:Mask;
	var hit:Interactive;
	var bar:h2d.Graphics;

	/**
	 * @param parent What to attach to.
	 */
	public function new(?parent:Object) {
		super(parent);

		mask = new Mask(1, 1, this);
		content = new Object(mask);
		bar = new h2d.Graphics(this);

		hit = new Interactive(0, 0, this);
		hit.propagateEvents = true;
		hit.onWheel = function(e:hxd.Event):Void {
			this.offset = offset + e.wheelDelta * Theme.px(48);
		};
	}

	override function redraw():Void {
		canvas.clear();
		if (width <= 0 || height <= 0)
			return;

		mask.width = Math.ceil(width);
		mask.height = Math.ceil(height);

		hit.width = width;
		hit.height = height;

		clamp();
		paintBar();
	}

	/** Puts the view back at the top. */
	public function toTop():Void {
		offset = 0;
	}

	/** Puts the view at the bottom, which is where a log is read from. */
	public function toBottom():Void {
		offset = extent - height;
	}

	function set_extent(v:Float):Float {
		extent = v < 0 ? 0 : v;

		if (follow)
			offset = extent - height;
		else
			clamp();

		paintBar();
		return extent;
	}

	function set_offset(v:Float):Float {
		offset = v;
		clamp();
		paintBar();
		return offset;
	}

	/** Holds the offset inside what there is to look at. */
	function clamp():Void {
		var most:Float = extent - height;
		if (most < 0)
			most = 0;

		if (offset > most)
			offset = most;
		if (offset < 0)
			offset = 0;

		content.y = -Math.round(offset);
	}

	/** Draws the bar down the right, when there is more than fits. */
	function paintBar():Void {
		bar.clear();

		if (width <= 0 || height <= 0 || extent <= height)
			return;

		var w:Float = Theme.px(5);
		var left:Float = width - w - Theme.px(2);

		bar.beginFill(Theme.panel2 & 0xFFFFFF, 1);
		bar.drawRoundedRect(left, 0, w, height, w * 0.5);
		bar.endFill();

		var span:Float = height * (height / extent);
		if (span < Theme.px(24))
			span = Theme.px(24);

		var room:Float = height - span;
		var most:Float = extent - height;
		var at:Float = most <= 0 ? 0 : (offset / most) * room;

		bar.beginFill(Theme.border2 & 0xFFFFFF, 1);
		bar.drawRoundedRect(left, at, w, span, w * 0.5);
		bar.endFill();
	}
}
