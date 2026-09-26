/**
 * A bridged base whose constructor walks an array and switches on an enum.
 *
 * Rebuilding that loop prints a comparison between the array and an `Int`.
 */
enum HostCmd {
	BeginFill(color:Int);
	EndFill;
}

class HostCmdList {
	public var commands:Array<HostCmd> = [];

	public function new() {}
}

class HostEnumSwitch {
	public function new() {
		var handler = new HostCmdList();
		for (command in handler.commands) {
			switch (command) {
				case BeginFill(color):
				case EndFill:
			}
		}
	}
}
