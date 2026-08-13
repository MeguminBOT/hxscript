package ui;

/**
 * The palette and the metrics every widget reads.
 *
 * These are SmiðrUI's own values rather than an approximation of them. The sandbox for lime is
 * built on that library and this one cannot be, so the two apps agree by carrying the same numbers:
 * anything read off a screenshot would drift the first time either side was retuned.
 *
 * Sizes go through `px` and text through `fs`, so a display that needs everything larger is one
 * number rather than an edit per widget.
 */
class Theme {
	/** Behind everything. */
	public static var bg:Int = 0xFF121214;

	/** A panel sitting on the background. */
	public static var panel:Int = 0xFF1E1E21;

	/** A panel on a panel. */
	public static var panel2:Int = 0xFF26262B;

	/** The one above that, for a raised row or a hovered control. */
	public static var panel3:Int = 0xFF34343B;

	/** A card, which is a panel that holds one thing. */
	public static var card:Int = 0xFF2C2C32;

	/** Behind anything typed into. */
	public static var inputBg:Int = 0xFF17171B;

	/** The line around a panel. */
	public static var border:Int = 0xFF3C3C44;

	/** The line around something focused. */
	public static var border2:Int = 0xFF585864;

	/** What is being read. */
	public static var text:Int = 0xFFE9E7EF;

    /** What is worth reading second. */
	public static var text2:Int = 0xFFB2B0BC;

	/** What is there but not being offered. */
	public static var text3:Int = 0xFF7F7D8A;

	/** What the eye should go to. */
	public static var accent:Int = 0xFF8A5EE0;

	/** The accent, pressed. */
	public static var accentDark:Int = 0xFF6B3FC4;

	/** The accent's other half, for a two-tone control. */
	public static var accentAlt:Int = 0xFFC558D6;

	/** Brighter than the accent, for the one thing that has to win. */
	public static var highlight:Int = 0xFFE6AEEF;

	/** It worked. */
	public static var success:Int = 0xFF63D68A;

	/** It did not. */
	public static var danger:Int = 0xFFF05C7C;

	/** It might not. */
	public static var warning:Int = 0xFFFFCA6E;

	/** How round a corner is, before scaling. */
	public static var radius:Float = 7;

	/** What every size is multiplied by. */
	public static var scale(default, null):Float = 1.0;

	/** What every text size has added to it, for a display that needs the words larger and not the boxes. */
	public static var fontBoost(default, null):Int = 0;

	/** Called when anything here changes, so what is already on screen can be rebuilt. */
	public static var onChanged:Void->Void = null;

	/**
	 * @param base A size in design pixels.
	 * @return It in real ones.
	 */
	public static inline function px(base:Float):Float {
		return base * scale;
	}

	/**
	 * @param base A text size in design pixels.
	 * @return It in real ones, which is the scale and the boost, never below 8.
	 */
	public static inline function fs(base:Int):Int {
		var out:Int = Math.round(base * scale) + fontBoost;
		return out < 8 ? 8 : out;
	}

	/**
	 * Sets what every size is multiplied by.
	 *
	 * @param value The new scale, held between a half and four.
	 */
	public static function setScale(value:Float):Void {
		var next:Float = value < 0.5 ? 0.5 : (value > 4 ? 4 : value);
		if (next == scale)
			return;

		scale = next;
		refresh();
	}

	/**
	 * Sets what every text size has added to it.
	 *
	 * @param value The boost, held between -4 and 12.
	 */
	public static function setFontBoost(value:Int):Void {
		var next:Int = value < -4 ? -4 : (value > 12 ? 12 : value);
		if (next == fontBoost)
			return;

		fontBoost = next;
		refresh();
	}

	/** Tells whatever is on screen that it was built against numbers that have changed. */
	public static function refresh():Void {
		if (onChanged != null)
			onChanged();
	}
}
