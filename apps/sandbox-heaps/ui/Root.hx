package ui;

import h2d.Object;
import h2d.Scene;

/**
 * The scene the interface lives on, and the one thing that knows how big it is.
 *
 * Kept apart from the scene a project draws on so the bars stay the size they were drawn at while
 * what sits between them is fitted to whatever room is left. One scene for both would mean choosing
 * between a project that is never scaled and an interface that always is.
 */
class Root {
	/** The scene itself, which the app renders after the project's. */
	public var scene(default, null):Scene;

	/** What everything is added to. */
	public var content(default, null):Object;

	/** What is over everything else, for a modal. */
	public var above(default, null):Object;

	/** Called after a resize, so the window can lay itself out again. */
	public var onResize:Void->Void;

	/** How wide the interface is, in its own pixels. */
	public var width(default, null):Float = 0;

	/** How tall it is. */
	public var height(default, null):Float = 0;

	/**
	 * Starts a scene sized to the window and never scaled.
	 */
	public function new() {
		scene = new Scene();
		scene.scaleMode = Resize;

		content = new Object(scene);
		above = new Object(scene);

		Theme.onChanged = function():Void {
			Fonts.clear();
			if (onResize != null)
				onResize();
		};
	}

	/**
	 * Tells the interface how much room it has.
	 *
	 * @param w The width in real pixels.
	 * @param h The height in real pixels.
	 */
	public function resize(w:Float, h:Float):Void {
		width = w;
		height = h;

		if (onResize != null)
			onResize();
	}
}
