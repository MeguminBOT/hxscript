import hostslot.HostSlot;

private typedef HostAlias = HostSlot;

/**
 * An inline helper that names a private typedef in a cast.
 *
 * Inlined into a constructor, `getTypedExpr` can keep that private name. The bridge module does
 * not have it.
 */
class HostBag {
	public static inline function stamp(slot:HostAlias):Int {
		var typed:HostAlias = slot;
		return typed.n;
	}
}
