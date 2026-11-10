/**
 * A host enum abstract with no wrapper, the shape of OpenFL's `TextFieldAutoSize` before its preset
 * scanned for it: nothing gives it an `AbstractValue_*` class, so a script reading one of its values
 * writes a static the loader cannot link.
 */
@:keep
enum abstract HostAutoSize(Null<Int>) {
	var CENTER = 0;
	var RIGHT = 3;
}
