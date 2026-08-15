import h2d.BlendMode;
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
 * What an interface reaches, asked as a list.
 *
 * `--conform widgets` runs each of these interpreted and again compiled and compares. Every type
 * here is a different path through the library than a sprite that moves: a callback field a script
 * assigns and the host calls back, a container that clips, a tile that is not an image, an enum
 * abstract, and a filter that replaces how a whole subtree is drawn.
 */
class SelfTest {
	public static function cases():Array<String> {
		return [
			'tileFromColour', 'tileSub', 'interactive', 'callbackFires', 'layers', 'mask', 'scaleGrid', 'tileGroup', 'blendMode', 'blendModeQualified',
			'filter', 'anim', 'built', 'pressed', 'stepped'
		];
	}

	/** A tile that is not an image, which is what a project with no art draws with. */
	public static function tileFromColour():Dynamic {
		var t:Tile = Tile.fromColor(0xFF0000, 12, 8);
		return t.width + 'x' + t.height;
	}

	/** A region of one, since a tile sheet is read by carving one up. */
	public static function tileSub():Dynamic {
		var t:Tile = Tile.fromColor(0x00FF00, 40, 40);
		var part:Tile = t.sub(4, 4, 16, 12);

		return part.width + 'x' + part.height;
	}

	/** The thing a pointer talks to, built and measured. */
	public static function interactive():Dynamic {
		var root:Object = new Object();
		var hit:Interactive = new Interactive(120, 30, root);

		return hit.width + 'x' + hit.height + ' in ' + root.numChildren;
	}

	/**
	 * A callback field a script assigns and something else calls.
	 *
	 * The shape every interface is built out of, and a different direction from the rest of this
	 * list: everywhere else a script calls the host, and here the host calls a closure the script
	 * made. Calling it directly is the same crossing without a pointer.
	 */
	public static function callbackFires():Dynamic {
		var hit:Interactive = new Interactive(10, 10);
		var seen:Int = 0;

		hit.onClick = function(e:hxd.Event):Void seen++;
		hit.onClick(null);
		hit.onClick(null);

		return seen;
	}

	/** Ordered layers, which is how an interface keeps itself above what it sits on. */
	public static function layers():Dynamic {
		var root:Layers = new Layers();

		root.add(new Object(), 2);
		root.add(new Object(), 0);
		root.add(new Object(), 1);

		return root.numChildren;
	}

	/** A container that clips, which is what a scrolling list is made of. */
	public static function mask():Dynamic {
		var m:Mask = new Mask(100, 50);
		var inside:Graphics = new Graphics(m);

		inside.beginFill(0xFFFFFF);
		inside.drawRect(0, 0, 500, 20);
		inside.endFill();

		return m.width + 'x' + m.height + ' in ' + m.numChildren;
	}

	/** A panel that stretches without stretching its corners. */
	public static function scaleGrid():Dynamic {
		var g:ScaleGrid = new ScaleGrid(Tile.fromColor(0x333333, 18, 18), 6, 6);
		g.width = 200;
		g.height = 60;

		return g.width + 'x' + g.height;
	}

	/** Many tiles in one draw call, which is what a tilemap or a text run is. */
	public static function tileGroup():Dynamic {
		var t:Tile = Tile.fromColor(0x445566, 8, 8);
		var group:TileGroup = new TileGroup(t);

		for (i in 0...16) {
			group.add(i * 8, 0, t);
		}

		return 'built ' + (group != null);
	}

	/**
	 * An enum abstract of the host's, reached through an import.
	 *
	 * **This one disagrees, and the compiled answer is the right one.** `BlendMode.Add` is null in
	 * the interpreter and `Add` compiled, so the write stores nothing on one side and the constant on
	 * the other. The conformance project next door reads the same constant written out in full,
	 * `h2d.BlendMode.Add`, and the two agree there, so what fails is resolving the constructor
	 * through the import rather than the enum abstract itself.
	 */
	public static function blendMode():Dynamic {
		var o:h2d.Bitmap = new h2d.Bitmap(Tile.fromColor(0xFFFFFF, 4, 4));
		o.blendMode = BlendMode.Add;

		return Std.string(o.blendMode);
	}

	/** The same constant written out in full, which is the half that works. */
	public static function blendModeQualified():Dynamic {
		var o:h2d.Bitmap = new h2d.Bitmap(Tile.fromColor(0xFFFFFF, 4, 4));
		o.blendMode = h2d.BlendMode.Add;

		return Std.string(o.blendMode);
	}

	/** A filter, which replaces how a whole subtree is drawn. */
	public static function filter():Dynamic {
		var o:Object = new Object();
		o.filter = new h2d.filter.Glow(0xFFFFFF, 1, 2);

		return 'filter ' + (o.filter != null);
	}

	/** An animation over several tiles, which is the one drawable with its own clock. */
	public static function anim():Dynamic {
		var frames:Array<Tile> = [Tile.fromColor(0x111111, 4, 4), Tile.fromColor(0x222222, 4, 4)];
		var a:h2d.Anim = new h2d.Anim(frames, 12);

		return 'frames ' + a.frames.length;
	}

	/** The project itself, constructed. */
	public static function built():Dynamic {
		var w:Widgets = new Widgets();
		return 'children ' + (w.numChildren > 0);
	}

	/** A press driven without a pointer, which is what makes an interface testable at all. */
	public static function pressed():Dynamic {
		var w:Widgets = new Widgets();

		w.button(0).press();
		w.button(2).press();

		return 'presses ' + w.presses() + ' lit ' + w.button(2).isLit();
	}

	/** Its frame loop, driven without a window. */
	public static function stepped():Dynamic {
		var w:Widgets = new Widgets();

		for (i in 0...30) {
			w.step(1 / 60);
		}

		return 'presses ' + w.presses();
	}
}
