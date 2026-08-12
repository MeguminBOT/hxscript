package studio;

import haxe.Timer;

/**
 * What the frame cost, counted rather than estimated.
 *
 * Averaged over a period rather than reported per frame, because a number that changes sixty times a
 * second cannot be read and a number that changes twice a second can.
 *
 * The split between update and draw follows from where the app can honestly put a bracket. This one
 * drives its own frame, so the two halves are its own calls and the time in them is the project's
 * while a project is what is in them. Memory is not divisible: there is one heap, one collector and
 * no way to ask which allocation came from a script, so it is reported once as the process's and
 * labelled that way.
 */
class Metrics {
	/** How long an average is taken over, in seconds. */
	static inline var PERIOD:Float = 0.5;

	/** Frames per second. */
	public static var fps(default, null):Int = 0;

	/** Milliseconds per frame in its update. */
	public static var updateMs(default, null):Float = 0;

	/** Milliseconds per frame in its draw. */
	public static var drawMs(default, null):Float = 0;

	/** Draw calls the engine issued on the last frame. */
	public static var drawCalls(default, null):Int = 0;

	/** Triangles it drew, which heaps counts and is worth seeing beside the calls. */
	public static var triangles(default, null):Int = 0;

	/** Process memory in megabytes, which is the whole process and says so. */
	public static var memory(default, null):Float = 0;

	static var frames:Int = 0;
	static var elapsed:Float = 0;
	static var updateTotal:Float = 0;
	static var drawTotal:Float = 0;
	static var began:Float = 0;

	/** Starts timing the update half. */
	public static inline function beginUpdate():Void {
		began = Timer.stamp();
	}

	/** Ends it. */
	public static inline function endUpdate():Void {
		updateTotal += Timer.stamp() - began;
	}

	/** Starts timing the draw half. */
	public static inline function beginDraw():Void {
		began = Timer.stamp();
	}

	/**
	 * Ends it, and reads what the engine drew.
	 *
	 * @param engine The engine, asked after it has rendered so the counters are the frame's.
	 */
	public static function endDraw(engine:h3d.Engine):Void {
		drawTotal += Timer.stamp() - began;

		if (engine != null) {
			drawCalls = engine.drawCalls;
			triangles = engine.drawTriangles;
		}
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
	 * The collector's own figure, which is the honest answer and the one that moves when a script
	 * allocates.
	 */
	static function bytes():Float {
		#if hl
		var stats = hl.Gc.stats();
		return stats.currentMemory;
		#else
		return 0;
		#end
	}

	static inline function round(value:Float):Float {
		return Math.round(value * 100) / 100;
	}
}
