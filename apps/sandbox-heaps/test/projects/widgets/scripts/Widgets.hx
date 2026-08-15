import h2d.Bitmap;
import h2d.Graphics;
import h2d.Interactive;
import h2d.Layers;
import h2d.Mask;
import h2d.Object;
import h2d.ScaleGrid;
import h2d.Text;
import h2d.Tile;
import h2d.TileGroup;

/**
 * The half of `h2d` an interface is built from.
 *
 * The playground moves sprites, which is what a game does with the library. This is the other half:
 * a thing that reacts to a pointer, a thing that clips what is under it, a thing that stretches
 * without stretching its corners, and a thing that draws a thousand tiles in one call. Each is a
 * different path through the library than a sprite that only moves, and each is a shape a script has
 * to be able to build for the library to be useful for tools rather than only for games.
 */
class Widgets extends Object {
	var buttons:Array<Button> = [];
	var readout:Text;
	var strip:TileGroup;
	var masked:Mask;
	var slider:ScaleGrid;
	var scroll:Float = 0;
	var clicks:Int = 0;

	public function new() {
		super();

		var back:Graphics = new Graphics(this);
		back.beginFill(0x14141A);
		back.drawRect(0, 0, screenWidth, screenHeight);
		back.endFill();

		var layers:Layers = new Layers(this);

		for (i in 0...4) {
			var made:Button = new Button(layers, 40, 60 + i * 56, 'Button ' + (i + 1), i);
			made.onPress = pressed;
			buttons.push(made);
		}

		slider = new ScaleGrid(panelTile(0x2A2A38), 6, 6);
		layers.add(slider, 0);
		slider.x = 260;
		slider.y = 60;
		slider.width = 300;
		slider.height = 44;

		masked = new Mask(300, 120, layers);
		masked.x = 260;
		masked.y = 130;

		strip = new TileGroup(cellTile(), masked);
		rebuildStrip();

		readout = new Text(hxd.res.DefaultFont.get(), this);
		readout.textColor = 0xE9E7EF;
		readout.x = 40;
		readout.y = 16;
	}

	/**
	 * Called every frame by the scene graph this is in.
	 *
	 * @param ctx What heaps is drawing with.
	 */
	override function sync(ctx:h2d.RenderContext) {
		super.sync(ctx);
		step(hxd.Timer.dt);
	}

	/**
	 * One frame, with nothing of the scene graph in it, so a test can drive it.
	 *
	 * @param dt Seconds since the previous frame.
	 */
	public function step(dt:Float):Void {
		scroll += dt * 40;

		if (scroll > 60) {
			scroll -= 60;
		}

		strip.x = -scroll;

		readout.text = 'widgets\n' + buttons.length + ' interactive(s), ' + clicks + ' press(es)\n' + 'click one, F1 goes back';
	}

	/** @param which Which button was pressed. */
	function pressed(which:Int):Void {
		clicks++;

		for (i in 0...buttons.length) {
			buttons[i].lit(i == which);
		}
	}

	/** Fills the clipped strip, which is what the mask exists to cut off. */
	function rebuildStrip():Void {
		strip.clear();

		for (i in 0...24) {
			strip.add(i * 26, 20 + Math.sin(i * 0.6) * 12, cellTile());
		}
	}

	/** @return How many presses have landed, for the self test. */
	public function presses():Int {
		return clicks;
	}

	/** @param which Which button. @return It, so a test can press one without a pointer. */
	public function button(which:Int):Button {
		return buttons[which];
	}

	/** @return A flat tile, since this project ships no art. */
	static function cellTile():Tile {
		return Tile.fromColor(0x8A5EE0, 20, 20);
	}

	/**
	 * @param colour What colour.
	 * @return A tile a `ScaleGrid` can stretch without stretching its corners.
	 */
	static function panelTile(colour:Int):Tile {
		return Tile.fromColor(colour, 18, 18);
	}
}

/** One thing that reacts to a pointer, as its own scripted class. */
class Button {
	/** Called when this is pressed, with which one it is. */
	public var onPress:Int->Void;

	var hit:Interactive;
	var body:Graphics;
	var label:Text;
	var which:Int;
	var on:Bool = false;

	public function new(into:Object, x:Float, y:Float, text:String, which:Int) {
		this.which = which;

		body = new Graphics(into);
		body.x = x;
		body.y = y;
		paint();

		label = new Text(hxd.res.DefaultFont.get(), body);
		label.text = text;
		label.x = 12;
		label.y = 10;

		hit = new Interactive(180, 40, body);
		hit.onClick = function(e:hxd.Event):Void press();
		hit.onOver = function(e:hxd.Event):Void lit(true);
		hit.onOut = function(e:hxd.Event):Void lit(false);
	}

	/** Presses it, which is what a pointer would have done. */
	public function press():Void {
		if (onPress != null) {
			onPress(which);
		}
	}

	/** @param yes Whether it is lit. */
	public function lit(yes:Bool):Void {
		if (on == yes) {
			return;
		}

		on = yes;
		paint();
	}

	/** @return Whether it is lit, for the self test. */
	public function isLit():Bool {
		return on;
	}

	function paint():Void {
		body.clear();
		body.beginFill(on ? 0x3A3A52 : 0x24242E);
		body.drawRect(0, 0, 180, 40);
		body.endFill();
	}
}
