package host;

#if smidr
import smidr.UIComponent;
#end

/**
 * What a running project can put on the shell's overlay.
 *
 * Separate from `Api` because it answers a different question. `Api` is what every backend can tell a script
 * about itself, such as the screen, the clock and how to stop. This is a place to put things, and it is the
 * shell's screen rather than the project's, so a project reaching it is asking the host for space rather
 * than drawing on its own.
 *
 * Marked the same way, so a script writes `info('speed', v)` rather than `host.Hud.info(...)`, and
 * gets the same name whether its module ends up interpreted or compiled.
 *
 * Nothing here fails when the overlay is off, and nothing here fails in a build with no UI in it either,
 * since the headless check is exactly that build. A project that reports values unconditionally is doing the
 * right thing; whether anything shows them is the host's business and the watcher's, not the project's.
 */
@:scriptAmbient
class Hud {
	/**
	 * Shows a named value, replacing what that name showed before.
	 *
	 * Meant to be called every frame with a value that changes. Naming it is what makes that cheap:
	 * the label is made once and its text is replaced afterwards, so a readout costs a string per
	 * frame rather than a widget.
	 *
	 * @param name What the value is.
	 * @param value Anything; stringified.
	 */
	@:scriptStatic('info')
	public static function info(name:String, value:Dynamic):Void {
		#if smidr
		studio.Overlay.set(name, value);
		#end
	}

	/** Drops every line and every widget the project added. */
	@:scriptStatic('infoClear')
	public static function infoClear():Void {
		#if smidr
		studio.Overlay.clear();
		#end
	}

	#if smidr
	/**
	 * The container a project adds its own widgets to.
	 *
	 * Anything SmidrUI can build goes in here, positioned by the project. Emptied when the project
	 * stops, so nothing has to be cleaned up on the way out.
	 *
	 * @return The container, or null before the shell has mounted one.
	 */
	@:scriptStatic('overlay')
	public static function overlay():UIComponent {
		return studio.Overlay.content;
	}
	#end

	/** Whether the overlay is on screen, for a project that would rather not compute what nobody sees. */
	@:scriptStatic('overlayShown')
	public static function overlayShown():Bool {
		#if smidr
		return studio.Overlay.shown();
		#else
		return false;
		#end
	}
}
