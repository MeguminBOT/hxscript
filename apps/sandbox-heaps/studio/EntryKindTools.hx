package studio;

/** Puts an `EntryKind` into words, so the window and the headless check say the same thing. */
class EntryKindTools {
	/**
	 * @param kind How the launcher would run it.
	 * @return A phrase naming the shape.
	 */
	public static function describe(kind:EntryKind):String {
		return switch (kind) {
			case KScene: 'an h2d scene';
			case KObject: 'an h2d object';
			case KProject: 'a host.Project';
			case KMain: 'a static main()';
		}
	}
}
