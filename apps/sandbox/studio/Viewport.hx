package studio;

import flixel.FlxG;

/**
 * The band the running project occupies, between the two bars.
 *
 * A project used to have the whole window, which meant the shell had to disappear entirely to get out of its
 * way. A shell that disappears cannot show you anything while the thing you are debugging runs, which is
 * when you most want to be shown something. So the project gets a band instead: the bars keep their space,
 * and what runs is fitted into what is left.
 *
 * **The fitting itself is `ViewportScaleMode`'s**, and this only says where the band is and reports
 * what came of it. That division is the whole correctness argument: flixel's scale mode owns the
 * game's position and scale and rewrites them on every measure, so a viewport implemented as a second
 * transform on top is both compounded with flixel's and undone by it. Expressed as a scale mode, the
 * camera scale, the game's position and the mouse coordinates all follow from one number.
 *
 * The project is told nothing about any of it. `FlxG.width` and `FlxG.height` still describe the space
 * it draws into, so a project written for the whole window needs no change to run in a band of it.
 */
class Viewport {
	/** Height reserved at the top, for the bar. */
	public static inline var TOP:Float = 30;

	/** Height reserved at the bottom, for the status bar. */
	public static inline var BOTTOM:Float = 24;

	/** Width of the band. */
	public static var width(get, never):Float;

	/** Height of the band. */
	public static var height(get, never):Float;

	/** Width the project is actually drawn at, which is the band's width or less. */
	public static var drawnWidth(get, never):Float;

	/** Height it is drawn at. */
	public static var drawnHeight(get, never):Float;

	/** How much it was scaled to fit, never above one. */
	public static var scale(get, never):Float;

	static var mode:ViewportScaleMode = null;

	/**
	 * Installs the scale mode, once.
	 *
	 * Assigning it is also what applies it, since flixel re-measures on assignment, so there is no separate
	 * call to make it take effect, and none needed on resize either: flixel measures again itself.
	 */
	public static function apply():Void {
		if (mode != null)
			return;

		mode = new ViewportScaleMode();
		FlxG.scaleMode = mode;
	}

	static function get_width():Float {
		return FlxG.stage == null ? 0 : FlxG.stage.stageWidth;
	}

	static function get_height():Float {
		return (FlxG.stage == null ? 0 : FlxG.stage.stageHeight) - TOP - BOTTOM;
	}

	static function get_drawnWidth():Float {
		return mode == null ? width : mode.gameSize.x;
	}

	static function get_drawnHeight():Float {
		return mode == null ? height : mode.gameSize.y;
	}

	static function get_scale():Float {
		return (mode == null || FlxG.width <= 0) ? 1 : mode.gameSize.x / FlxG.width;
	}
}
