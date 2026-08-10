package studio;

import flixel.FlxG;
import flixel.graphics.tile.FlxDrawBaseItem;
import haxe.Timer;

/**
 * What the two readout windows show, measured rather than estimated.
 *
 * The rule this file follows, and the reason it is worth stating: **every number here is something
 * that was actually counted.** A performance readout that guesses is worse than no readout, because
 * it is trusted and then acted on, and the thing that gets optimised is whatever the guess happened to
 * blame. So where a number cannot be separated it is not separated, and the window says which of the
 * two it belongs to.
 *
 * Draw calls are flixel's counter, reset per frame by flixel itself and read after the cameras have
 * rendered, so they are the project's too, for the same reason. Memory is not divisible at all: one heap,
 * one collector, no way to ask which allocation came from a script. It is reported once, as the process's.
 */
class Metrics {
	/** How often the readouts are recomputed, in seconds. Faster than this is unreadable anyway. */
	static inline var PERIOD:Float = 0.5;

	/** Frames per second, averaged over the last period. */
	public static var fps(default, null):Int = 0;

	/** Milliseconds the last period spent in the running project's update, per frame. */
	public static var updateMs(default, null):Float = 0;

	/** Milliseconds per frame in its draw. */
	public static var drawMs(default, null):Float = 0;

	/** Draw calls flixel issued on the last frame. */
	public static var drawCalls(default, null):Int = 0;

	/** Process memory in megabytes, which is the whole process and says so. */
	public static var memory(default, null):Float = 0;

	static var frames:Int = 0;
	static var elapsed:Float = 0;
	static var updateTotal:Float = 0;
	static var drawTotal:Float = 0;
	static var updateBegan:Float = 0;
	static var drawBegan:Float = 0;
	static var hooked:Bool = false;

	/**
	 * Subscribes to the signals that bracket a frame.
	 *
	 * flixel's own, rather than a timer of our own around something: `preUpdate` to `postUpdate` is
	 * exactly the state's update and nothing else, and while a scripted state is the state, that is
	 * exactly the script's update. Measuring it any other way would include the shell's own work and
	 * attribute it to the project.
	 */
	public static function hook():Void {
		if (hooked)
			return;

		hooked = true;

		FlxG.signals.preUpdate.add(function():Void updateBegan = Timer.stamp());
		FlxG.signals.postUpdate.add(function():Void updateTotal += Timer.stamp() - updateBegan);
		FlxG.signals.preDraw.add(function():Void drawBegan = Timer.stamp());
		FlxG.signals.postDraw.add(function():Void {
			drawTotal += Timer.stamp() - drawBegan;

			if (FlxG.renderTile)
				drawCalls = FlxDrawBaseItem.drawCalls;
		});
	}

	/**
	 * Folds one frame in, and recomputes the averages when a period is up.
	 *
	 * @param seconds Seconds since the previous frame.
	 */
	public static function tick(seconds:Float):Void {
		frames++;
		elapsed += seconds;

		if (elapsed < PERIOD)
			return;

		fps = Math.round(frames / elapsed);
		updateMs = round(updateTotal * 1000 / frames);
		drawMs = round(drawTotal * 1000 / frames);
		memory = round(bytes() / 1048576);

		frames = 0;
		elapsed = 0;
		updateTotal = 0;
		drawTotal = 0;
	}

	/**
	 * The process's memory, in bytes.
	 *
	 * The collector's own figure where there is one, which on hxcpp is the honest answer and the one
	 * that moves when a script allocates. openfl's is the fallback, since it is the only one every
	 * target has.
	 */
	static function bytes():Float {
		#if cpp
		return cpp.vm.Gc.memUsage();
		#elseif openfl
		return #if (openfl >= "9.4.0") openfl.system.System.totalMemoryNumber #else openfl.system.System.totalMemory #end;
		#else
		return 0;
		#end
	}

	static inline function round(value:Float):Float {
		return Math.round(value * 100) / 100;
	}
}
