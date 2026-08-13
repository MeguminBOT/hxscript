package ui;

import h2d.Object;

/** A filled, outlined rectangle that other things sit on. */
class Panel extends Widget {
	/** What it is filled with. */
	public var background(default, set):Int;

	/** The line around it, or zero for none. */
	public var edge(default, set):Int;

	/** How round the corners are, before scaling. */
	public var radius(default, set):Float;

	/**
	 * @param background What to fill it with, defaulting to the theme's panel.
	 * @param edge The line around it, defaulting to the theme's border.
	 * @param parent What to attach to.
	 */
	public function new(background:Int = -1, edge:Int = -1, ?parent:Object) {
		super(parent);
		this.background = background < 0 ? Theme.panel : background;
		this.edge = edge < 0 ? Theme.border : edge;
		this.radius = Theme.radius;
	}

	override function redraw():Void {
		canvas.clear();
		if (width <= 0 || height <= 0)
			return;

		fill(background, width, height, Theme.px(radius));

		if (edge != 0)
			outline(edge, width, height, Theme.px(radius));
	}

	function set_background(v:Int):Int {
		background = v;
		redraw();
		return v;
	}

	function set_edge(v:Int):Int {
		edge = v;
		redraw();
		return v;
	}

	function set_radius(v:Float):Float {
		radius = v;
		redraw();
		return v;
	}
}
