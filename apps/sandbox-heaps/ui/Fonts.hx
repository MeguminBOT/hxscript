package ui;

import h2d.Font;

/**
 * The fonts every widget draws with, one per size.
 *
 * Built from a system face rather than scaled from one bitmap, because a readout at 11 and a heading
 * at 16 both have to be legible and a scaled bitmap font is only crisp at the size it was baked. The
 * faces are tried in order and the first the machine has wins; a machine with none of them still
 * gets text, from the font heaps embeds.
 *
 * Cached by the size actually asked for, which is the size after `Theme.fs` has applied the scale and
 * the boost, so changing either builds new faces rather than stretching the ones already made.
 */
class Fonts {
	/** Tried in order. The first three are the same shape on the three platforms. */
	static var FACES:Array<String> = ['Segoe UI', 'Helvetica Neue', 'DejaVu Sans', 'Arial'];

	static var built:Map<Int, Font> = new Map();

	/**
	 * @param size The size in real pixels, which is what `Theme.fs` returns.
	 * @return A font at that size.
	 */
	public static function at(size:Int):Font {
		var known:Null<Font> = built.get(size);
		if (known != null)
			return known;

		var made:Font = null;

		for (face in FACES) {
			try {
				made = hxd.res.FontBuilder.getFont(face, size);
			} catch (e:Dynamic) {
				made = null;
			}
			if (made != null)
				break;
		}

		if (made == null)
			made = hxd.res.DefaultFont.get();

		built.set(size, made);
		return made;
	}

	/** Drops every face, for when the scale changed and the sizes asked for will be different. */
	public static function clear():Void {
		built = new Map();
	}
}
