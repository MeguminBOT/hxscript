package ui;

/** How loudly a button asks to be pressed. */
enum abstract Weight(Int) {
	/** The one thing on the screen to do. */
	var Strong;

	/** One of several equal things. */
	var Normal;

	/** There, but not the point. */
	var Quiet;

	/** Something that cannot be undone. */
	var Destructive;
}
