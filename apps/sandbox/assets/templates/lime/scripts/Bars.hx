import lime.ui.KeyCode;
import openfl.display.Sprite;

/**
 * A project with no game framework under it: the frame loop and the input callbacks, and nothing
 * else.
 *
 * `host.Project` exists because a script **cannot** subclass `lime.app.Application`. That class is
 * the process entry, so anything extending it would have had to exist before the program started,
 * which a script by definition did not. The sandbox owns the `Application` and hands the same
 * lifecycle down: `start` once, `update` per frame, `stop` on the way out, plus the key and mouse
 * callbacks.
 *
 * Nothing is lost by the arrangement. `lime.ui`, `lime.system` and `lime.math` are all reachable by
 * name from inside these methods. `KeyCode` below is lime's own, wrapped for scripting by the lime
 * preset so its constants mean something.
 *
 * `layer` is given by the host before `start` and emptied after `stop`, so a project that forgets to
 * clean up after itself cannot leak into the next one.
 */
class Bars extends Project {
	static var COUNT:Int = 40;

	var bars:Array<Sprite> = [];
	var phase:Float = 0;
	var speed:Float = 1.0;
	var paused:Bool = false;

	public function new() {
		super();
		title = 'lime lifecycle';
	}

	override public function start():Void {
		var width:Float = screenWidth / COUNT;

		for (i in 0...COUNT) {
			var bar:Sprite = new Sprite();

			bar.graphics.beginFill(shade(i, COUNT));
			bar.graphics.drawRect(0, 0, width - 2, 1);
			bar.graphics.endFill();

			bar.x = i * width;
			bar.y = screenHeight * 0.5;

			layer.addChild(bar);
			bars.push(bar);
		}

		log('$title: left and right change speed, space pauses, F1 goes back');
	}

	override public function update(elapsed:Float):Void {
		if (paused)
			return;

		phase += elapsed * speed;

		for (i in 0...bars.length) {
			var bar:Sprite = bars[i];
			var height:Float = 20 + Math.abs(Math.sin(phase + i * 0.22)) * (screenHeight * 0.34);

			bar.scaleY = height;
			bar.y = screenHeight * 0.5 - height * 0.5;
		}
	}

	override public function onKeyDown(code:Int):Void {
		if (code == KeyCode.SPACE)
			paused = !paused;

		if (code == KeyCode.LEFT)
			speed = Math.max(0.1, speed - 0.2);

		if (code == KeyCode.RIGHT)
			speed = Math.min(6.0, speed + 0.2);
	}

	override public function stop():Void {
		bars = [];
	}

	/**
	 * A colour along a ramp.
	 *
	 * @param index Which step.
	 * @param count How many steps there are.
	 * @return A packed 0xRRGGBB colour.
	 */
	function shade(index:Int, count:Int):Int {
		var t:Float = count <= 1 ? 0 : index / (count - 1);

		var r:Int = Std.int(70 + t * 150);
		var g:Int = Std.int(150 - t * 40);
		var b:Int = Std.int(210 - t * 60);

		return (r << 16) | (g << 8) | b;
	}
}
