package studio;

import h2d.Scene;

/**
 * The band the running project occupies, between the two bars.
 *
 * A project used to have the whole window in apps like this, which meant the shell had to disappear
 * entirely to get out of its way. A shell that disappears cannot show you anything while the thing
 * you are debugging runs, which is when you most want to be shown something. So the project gets a
 * band instead: the bars keep their space, and what runs is fitted into what is left.
 *
 * **The fitting is the scene's own `scaleMode`, not a transform laid over one**, and that is the
 * whole correctness argument. Heaps derives an `Interactive`'s local coordinates by inverting the
 * scene's viewport transform, so a viewport implemented as a second transform means every click
 * lands somewhere other than where it looks. Expressed as a scale mode, the drawing and the pointer
 * both follow from one number and neither can disagree with the other.
 *
 * **The two bars are the same height on purpose.** `Fixed` centres in the window, and the band's
 * centre is the window's centre only when what is taken off the top equals what is taken off the
 * bottom. Heaps does not offer a settable viewport offset, so the alternative was rendering the
 * project to a texture and placing it, which would have taken the pointer back out of heaps' hands
 * and put it in this file. Six pixels of status bar is a cheaper price than that.
 *
 * The project is told nothing about any of it. Its canvas is 1366x768 whatever the window is doing,
 * so a project written for the whole of one needs no change to run in a band of it.
 */
class Viewport {
	/** Height reserved at the top, for the bar. */
	public static inline var TOP:Float = 30;

	/** Height reserved at the bottom, which equals the top for the reason above. */
	public static inline var BOTTOM:Float = 30;

	/** How wide a project's canvas is, whatever the window is doing. */
	public static inline var CANVAS_WIDTH:Int = 1366;

	/** How tall it is. */
	public static inline var CANVAS_HEIGHT:Int = 768;

	/** How much the canvas was scaled to fit, never above one. */
	public static var scale(default, null):Float = 1;

	/** How wide the band is. */
	public static var width(default, null):Float = 0;

	/** How tall the band is. */
	public static var height(default, null):Float = 0;

	/** How wide the canvas is actually drawn, which is the band's width or less. */
	public static var drawnWidth(get, never):Float;

	/** How tall it is actually drawn. */
	public static var drawnHeight(get, never):Float;

	/**
	 * Fits a project's scene into the band.
	 *
	 * @param scene The scene the project draws on.
	 * @param windowWidth How wide the window is, in real pixels.
	 * @param windowHeight How tall it is.
	 */
	public static function fit(scene:Scene, windowWidth:Float, windowHeight:Float):Void {
		width = windowWidth;
		height = windowHeight - TOP - BOTTOM;

		if (width <= 0 || height <= 0) {
			scale = 1;
			return;
		}

		var across:Float = width / CANVAS_WIDTH;
		var down:Float = height / CANVAS_HEIGHT;
		var fits:Float = across < down ? across : down;

		// Never magnified. A window bigger than the project is extra room around it rather than a
		// reason to blow it up, so the readout is only ever how much had to be given up.
		scale = fits > 1 ? 1 : fits;

		scene.scaleMode = Fixed(CANVAS_WIDTH, CANVAS_HEIGHT, scale, Center, Center);
	}

	static function get_drawnWidth():Float {
		return CANVAS_WIDTH * scale;
	}

	static function get_drawnHeight():Float {
		return CANVAS_HEIGHT * scale;
	}
}
