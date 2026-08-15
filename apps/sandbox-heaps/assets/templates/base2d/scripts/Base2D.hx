import h2d.Bitmap;
import h2d.BlendMode;
import h2d.Object;
import h2d.Text;
import h2d.Tile;

/**
 * The 2D starting point: sprites in a ring, blended, turning.
 *
 * After the `Base2D` sample that ships with Heaps, rewritten for this app's lifecycle rather than
 * copied: heaps' own samples are an `hxd.App` with a `main()`, and a project here is handed its
 * layer and told when to start and update. Heaps is MIT licensed, (c) 2013 Nicolas Cannasse.
 *
 * **What it is really showing is `Add` blending.** Sixteen copies of one soft tile laid in a circle
 * would be sixteen sprites; with `Add` the overlaps sum, so where they cross reads as light rather
 * than as one sprite drawn over another. Turning the parent rather than each child is the other
 * half: a transform belongs to the object above, so the ring is one rotation and not sixteen.
 */
class Base2D extends host.Project {
	static inline var COUNT:Int = 16;
	static inline var RADIUS:Float = 190;

	var ring:Object;
	var label:Text;
	var elapsed:Float = 0;

	public function new() {
		super();
		title = 'Base 2D';
	}

	/** Called once, when the project starts. */
	override public function start():Void {
		var tile:Tile = hxd.Res.load('gem.png').toTile();
		tile = tile.center();

		ring = new Object(layer);
		ring.x = 683;
		ring.y = 384;

		for (i in 0...COUNT) {
			var at:Float = (i / COUNT) * Math.PI * 2;
			var piece:Bitmap = new Bitmap(tile, ring);

			piece.x = Math.cos(at) * RADIUS;
			piece.y = Math.sin(at) * RADIUS;
			piece.blendMode = BlendMode.Add;
			piece.scale(1.4);
		}

		/**
		 * The shadow is a second copy behind the first, offset. There is no shadow property on
		 * `h2d.Text`, and this is what one is: the same glyphs drawn twice.
		 */
		var shadow:Text = new Text(hxd.res.DefaultFont.get(), layer);
		shadow.text = 'hxScript drawing h2d';
		shadow.textColor = 0x22103A;
		shadow.x = 683 - shadow.textWidth * 0.5 + 2;
		shadow.y = 384 + 2;

		label = new Text(hxd.res.DefaultFont.get(), layer);
		label.text = shadow.text;
		label.textColor = 0xFFE9A8;
		label.x = shadow.x - 2;
		label.y = shadow.y - 2;
	}

	/**
	 * Called every frame by the host.
	 *
	 * @param dt Seconds since the previous frame.
	 */
	override public function update(dt:Float):Void {
		elapsed += dt;

		ring.rotation = elapsed * 0.4;

		/** The ring turns and the text does not, which is the point of them being separate objects. */
		label.alpha = 0.75 + Math.sin(elapsed * 2) * 0.25;
	}
}
