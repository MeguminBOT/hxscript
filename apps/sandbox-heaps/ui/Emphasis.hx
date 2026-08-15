package ui;

/** How much a piece of text is asking to be read. */
enum abstract Emphasis(Int) {
	/** What the eye should go to. */
	var Primary;

	/** What is worth reading second. */
	var Secondary;

	/** There, but not being offered. */
	var Muted;

	/** It worked. */
	var Good;

	/** It did not. */
	var Bad;

	/** It might not. */
	var Warn;
}
