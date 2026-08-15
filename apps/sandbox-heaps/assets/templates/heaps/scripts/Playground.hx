import h2d.Bitmap;
import h2d.Graphics;
import h2d.Object;
import h2d.Text;
import hxd.Key;

/**
 * A scripted `h2d.Object`, which is the shape most heaps projects want.
 *
 * It is the library's own class, not a wrapper. `addChild`, `x`, `y`, `alpha` and the rest are
 * heaps', and this really is in the scene graph: what is added here is drawn because it is in it.
 *
 * The launcher adds this to the project's layer and empties the layer when the run ends, so nothing
 * here has to clean up after itself.
 */
class Playground extends Object {
	static inline var COUNT:Int = 40;

	var movers:Array<Mover> = [];
	var readout:Text;
	var elapsed:Float = 0;
	var paused:Bool = false;

	public function new() {
		super();

		var back:Graphics = new Graphics(this);
		back.beginFill(0x14141A);
		back.drawRect(0, 0, screenWidth, screenHeight);
		back.endFill();

		for (i in 0...COUNT) {
			var shade:Shade = i % 3 == 0 ? Warm : (i % 3 == 1 ? Cool : Bright);
			movers.push(new Mover(this, shade, i));
		}

		readout = new Text(hxd.res.DefaultFont.get(), this);
		readout.textColor = 0xE9E7EF;
		readout.x = 16;
		readout.y = 16;
	}

	/**
	 * Called every frame by the scene graph this is in.
	 *
	 * @param dt Seconds since the previous frame.
	 */
	override function sync(ctx:h2d.RenderContext) {
		super.sync(ctx);

		var dt:Float = hxd.Timer.dt;
		elapsed += dt;

		if (Key.isPressed(Key.SPACE))
			paused = !paused;

		if (!paused) {
			for (mover in movers)
				mover.step(dt);
		}

		readout.text = 'heaps playground\n'
			+ '${movers.length} movers, ${paused ? "paused" : "running"}\n'
			+ 'space pauses, F1 goes back\n'
			+ 'up ${Math.round(elapsed * 10) / 10}s';

		// Reaches the strip above the project, when it is on. Naming a value means its label is
		// built once and only the text changes afterwards, so this is cheap to call every frame.
		if (overlayShown()) {
			info('elapsed', Math.round(elapsed * 10) / 10);
			info('paused', paused);
		}
	}
}

/** Which of the three palettes a mover took, as a scripted enum. */
enum Shade {
	Warm;
	Cool;
	Bright;
}

/**
 * A speed, as a scripted abstract over a float.
 *
 * Here to show that an abstract declared in a script is a real one: it has an operator, and the
 * operator runs the body written for it rather than the arithmetic underneath.
 */
abstract Speed(Float) from Float to Float {
	public function new(v:Float) {
		this = v;
	}

	@:op(A + B) public function faster(by:Float):Speed {
		return new Speed(this + by);
	}

	public function describe():String {
		return Math.round(this) + ' px/s';
	}
}

/** One drifting square. */
class Mover {
	var body:Graphics;
	var speed:Speed;
	var angle:Float;

	public function new(into:Object, shade:Shade, seed:Int) {
		var size:Float = 8 + (seed % 5) * 4;

		body = new Graphics(into);
		body.beginFill(colourOf(shade));
		body.drawRect(-size * 0.5, -size * 0.5, size, size);
		body.endFill();

		body.x = 80 + (seed * 97) % 1200;
		body.y = 80 + (seed * 53) % 600;

		speed = new Speed(40 + (seed % 7) * 18);
		angle = (seed * 0.37) % (Math.PI * 2);
	}

	/**
	 * Moves it, turning it around at the edges.
	 *
	 * @param dt Seconds since the previous frame.
	 */
	public function step(dt:Float):Void {
		var rate:Float = speed;

		body.x += Math.cos(angle) * rate * dt;
		body.y += Math.sin(angle) * rate * dt;

		if (body.x < 20 || body.x > screenWidth - 20)
			angle = Math.PI - angle;

		if (body.y < 20 || body.y > screenHeight - 20)
			angle = -angle;

		body.rotation += dt * 0.8;
	}

	static function colourOf(shade:Shade):Int {
		return switch (shade) {
			case Warm: 0xF05C7C;
			case Cool: 0x8A5EE0;
			case Bright: 0xFFCA6E;
		}
	}
}
