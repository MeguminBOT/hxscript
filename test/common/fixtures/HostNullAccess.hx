/**
 * Switches `Config.strictNullAccess` from inside a script, which cannot name `hxscript.Config`.
 *
 * The flag is read at the access in every mode, so a case can turn it on around the access it checks
 * and the same case runs interpreted and compiled.
 */
class HostNullAccess {
	/**
	 * @param on The value to set.
	 * @return The value it had.
	 */
	public static function strict(on:Bool):Bool {
		var was:Bool = hxscript.Config.strictNullAccess;
		hxscript.Config.strictNullAccess = on;
		return was;
	}
}
