package studio;

import flixel.FlxG;
import flixel.system.scaleModes.BaseScaleMode;

/**
 * Fits the running project into the band between the bars, by being flixel's scale mode rather than
 * by fighting it.
 *
 * The first attempt at the viewport scaled `FlxG.game` directly, and it was wrong in a way worth recording:
 * **flixel already owns that transform.** A scale mode sets `FlxG.game.x` and `y` and each camera's internal
 * scale on every measure, so a second transform applied on top compounds with it and is then overwritten the
 * next time the window changes. It happened to look right at startup only because both agreed on 1, then
 * went to 133% the moment the window went fullscreen, magnifying a 1120x720 game past its own resolution.
 *
 * So the rect is expressed the way flixel expresses one. Everything downstream follows for free: camera
 * scale, `FlxG.game`'s position, and mouse coordinates, which is the one that would otherwise have been
 * silently wrong, because flixel derives the pointer from the scale mode and a hand-rolled transform means
 * clicks land somewhere other than where they look.
 *
 * **It never magnifies.** A project is shown at its own resolution or smaller, never larger: a window bigger
 * than the game is extra room around it, not a reason to blow it up. Which also means the readout's
 * percentage is a number worth reading, since below 100 is how much was given up to fit.
 */
class ViewportScaleMode extends BaseScaleMode {
	public function new() {
		super();
	}

	/**
	 * Measures into the viewport instead of the window.
	 *
	 * @param Width The window width, as flixel measured it.
	 * @param Height The window height.
	 */
	override public function onMeasure(Width:Int, Height:Int):Void {
		setGlobalSize(FlxG.initialWidth, FlxG.initialHeight);

		var band:Int = Height - Std.int(Viewport.TOP) - Std.int(Viewport.BOTTOM);
		if (band < 1)
			band = 1;

		updateGameSize(Width, band);
		updateDeviceSize(Width, band);
		updateScaleOffset();

		offset.y += Viewport.TOP;

		updateGamePosition();
	}

	/**
	 * Sizes the game to fit the band, keeping its aspect ratio and its own resolution as a ceiling.
	 *
	 * @param Width The band width.
	 * @param Height The band height.
	 */
	override function updateGameSize(Width:Int, Height:Int):Void {
		if (FlxG.width <= 0 || FlxG.height <= 0) {
			gameSize.set(Width, Height);
			return;
		}

		var byWidth:Float = Width / FlxG.width;
		var byHeight:Float = Height / FlxG.height;
		var fit:Float = byWidth < byHeight ? byWidth : byHeight;

		if (fit > 1)
			fit = 1;

		gameSize.set(Math.floor(FlxG.width * fit), Math.floor(FlxG.height * fit));
	}
}
