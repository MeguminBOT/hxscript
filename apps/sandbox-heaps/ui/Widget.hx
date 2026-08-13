package ui;

import h2d.Graphics;
import h2d.Object;

/**
 * What every widget is: something with a size, that redraws when the size changes.
 *
 * Position is `x` and `y`, which come from `h2d.Object`, and size is `resize`. That is deliberately
 * not a layout system. The window places everything by hand from one `layout` function, the way the
 * sandbox for lime does, because the two apps have to agree pixel for pixel and a solver that
 * arrived at the same numbers by a different route would only agree until one of them was retuned.
 */
class Widget extends Object {
	/** How wide it was last told to be. */
	public var width(default, null):Float = 0;

	/** How tall it was last told to be. */
	public var height(default, null):Float = 0;

	/** Whether it answers to the pointer. A widget that does not is also drawn dimmer. */
	public var enabled(default, set):Bool = true;

	/** What this draws itself on. */
	var canvas:Graphics;

	/**
	 * @param parent What to attach to, if anything.
	 */
	public function new(?parent:Object) {
		super(parent);
		canvas = new Graphics(this);
	}

	/**
	 * Sets the size and redraws.
	 *
	 * @param w The width.
	 * @param h The height.
	 */
	public function resize(w:Float, h:Float):Void {
		width = w;
		height = h;
		redraw();
	}

	/** Places and sizes in one call, for a layout that knows both. */
	public inline function place(px:Float, py:Float, w:Float, h:Float):Void {
		x = px;
		y = py;
		resize(w, h);
	}

	/**
	 * Draws whatever this looks like now.
	 *
	 * Called whenever the size changes and whenever the widget's own state does. Everything a widget
	 * draws goes through here rather than being edited in place, so there is one description of what
	 * it looks like rather than one per way of reaching it.
	 */
	function redraw():Void {}

	function set_enabled(v:Bool):Bool {
		if (enabled == v)
			return v;

		enabled = v;
		redraw();
		return v;
	}

	/**
	 * Fills a rounded rectangle, which is the shape almost everything here is.
	 *
	 * @param colour The fill.
	 * @param w The width.
	 * @param h The height.
	 * @param radius The corner radius, or -1 for the theme's.
	 */
	function fill(colour:Int, w:Float, h:Float, radius:Float = -1):Void {
		var r:Float = radius < 0 ? Theme.px(Theme.radius) : radius;

		canvas.beginFill(colour & 0xFFFFFF, alphaOf(colour));
		if (r <= 0)
			canvas.drawRect(0, 0, w, h);
		else
			canvas.drawRoundedRect(0, 0, w, h, r);
		canvas.endFill();
	}

	/**
	 * Draws the line around a rounded rectangle.
	 *
	 * @param colour The line.
	 * @param w The width.
	 * @param h The height.
	 * @param radius The corner radius, or -1 for the theme's.
	 * @param thickness How thick, before scaling.
	 */
	function outline(colour:Int, w:Float, h:Float, radius:Float = -1, thickness:Float = 1):Void {
		var r:Float = radius < 0 ? Theme.px(Theme.radius) : radius;
		var t:Float = Theme.px(thickness);

		canvas.lineStyle(t, colour & 0xFFFFFF, alphaOf(colour));
		if (r <= 0)
			canvas.drawRect(t * 0.5, t * 0.5, w - t, h - t);
		else
			canvas.drawRoundedRect(t * 0.5, t * 0.5, w - t, h - t, r);
		canvas.lineStyle();
	}

	/** @return The alpha packed into a colour, as heaps wants it separately. */
	inline function alphaOf(colour:Int):Float {
		return ((colour >>> 24) & 0xFF) / 255;
	}
}
