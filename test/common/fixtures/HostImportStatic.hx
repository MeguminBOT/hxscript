/**
 * A bridged base whose constructor switches on a static reached through an import.
 *
 * The bridge module does not have that import, so the short name does not resolve.
 */
import other.Elsewhere;
import other.AudioKind;

class HostImportStatic {
	public function new(stream:String = null) {
		if (stream == null && Elsewhere.context != null) {
			switch (Elsewhere.context.type) {
				case OPENAL:
					Elsewhere.context.openal;
				default:
			}
		}
	}
}
