class Guest {
	public static function main():Void {
		var total:Int = 0;
		for (i in 0...10)
			total += i;
		Sys.println('  [guest] hello from a module loaded at runtime, total=' + total);
	}
}
