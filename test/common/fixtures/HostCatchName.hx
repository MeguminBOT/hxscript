/**
 * A bridged base whose constructor catches into a variable named like another class's static.
 *
 * Inside the catch, `e` is the caught value. Qualified by its name alone, it read
 * `CatchNameOther.e` instead.
 */
class CatchNameOther {
	public static var e:String = "static";
}

class HostCatchName {
	public var got:String;

	public function new() {
		got = CatchNameOther.e;
		try {
			throw "thrown";
		} catch (e:String) {
			got += "|" + e;
		}
	}
}
