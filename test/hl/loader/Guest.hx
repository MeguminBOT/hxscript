/**
 * A module that did not exist when the host was built, for the host to load and run.
 *
 * It leaves a file behind rather than printing, so that what the probe checks is that this code ran
 * inside the host process, rather than that some text appeared somewhere.
 */
class Guest {
	public static function main():Void {
		var total:Int = 0;
		for (i in 0...10)
			total += i * i;

		sys.io.File.saveContent('guest.out', Std.string(total));
		Sys.println('  [guest] ran inside the host, total ' + total);
	}
}
