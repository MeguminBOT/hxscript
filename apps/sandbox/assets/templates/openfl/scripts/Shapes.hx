import openfl.display.Sprite;
import openfl.events.Event;
import openfl.text.TextField;
import openfl.text.TextFormat;

/**
 * An openfl project: a scripted `openfl.display.Sprite` driving a few dozen more of them.
 *
 * `Shapes` **is** a `Sprite`. `addChild`, `graphics`, `blendMode` and the event dispatcher are the
 * display list's own, so animation is an `ENTER_FRAME` listener exactly as it would be in compiled
 * code, because the host does not drive this and does not need to.
 *
 * `BlendMode.ADD` is the line that would not work without step 3 of the setup. An abstract has no
 * runtime form of its own, so an unwrapped `BlendMode` gives `Unknown identifier: ADD`: an error
 * about a constant, with nothing in it about abstracts or about the build. The openfl preset wraps
 * it, so it means what it says.
 */
class Shapes extends Sprite {
	static var COUNT:Int = 28;

	var blocks:Array<Sprite> = [];
	var phase:Float = 0;
	var last:Float = 0;

	public function new() {
		super();

		for (i in 0...COUNT) {
			var block:Sprite = new Sprite();
			var size:Float = 8 + (COUNT - i) * 0.8;

			block.graphics.beginFill(shade(i, COUNT), 0.85);
			block.graphics.drawRect(-size * 0.5, -size * 0.5, size, size);
			block.graphics.endFill();
			block.blendMode = BlendMode.ADD;

			addChild(block);
			blocks.push(block);
		}

		var label:TextField = new TextField();
		label.defaultTextFormat = new TextFormat('_typewriter', 12, 0xd8d8e0);
		label.width = screenWidth;
		label.x = 12;
		label.y = 12;
		label.selectable = false;
		label.text = '${blocks.length} openfl sprites, drawn by a script, F1 to go back';
		addChild(label);

		last = uptime();
		addEventListener(Event.ENTER_FRAME, onFrame);
	}

	/**
	 * Moves everything, once per frame.
	 *
	 * @param event The frame event, which carries nothing worth reading.
	 */
	function onFrame(event:Event):Void {
		var now:Float = uptime();
		var elapsed:Float = now - last;
		last = now;

		phase += elapsed;

		var midX:Float = screenWidth * 0.5;
		var midY:Float = screenHeight * 0.5;

		for (i in 0...blocks.length) {
			var block:Sprite = blocks[i];
			var t:Float = phase * 0.9 + i * 0.22;

			block.x = midX + Math.cos(t) * (40 + i * 8);
			block.y = midY + Math.sin(t * 1.4) * (30 + i * 6);
			block.rotation = t * 30;
		}
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

		var r:Int = Std.int(60 + t * 180);
		var g:Int = Std.int(120 + (1 - t) * 90);
		var b:Int = Std.int(200 - t * 80);

		return (r << 16) | (g << 8) | b;
	}
}
