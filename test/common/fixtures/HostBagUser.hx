/**
 * A bridged base whose constructor inlines a cast to a private typedef.
 */
class HostBagUser {
	public var n:Int;

	public function new() {
		var slot = new hostslot.HostSlot();
		n = HostBag.stamp(slot);
	}
}
