/**
 * A host enum abstract, which is a different runtime form again.
 *
 * It has no class of its own and no enum either: the wrapper turns each constructor into a static
 * getter, so reading one is a property read on a class value rather than a field read. Whether that
 * resolves depends on the target and on how the type was named, which is the pair of questions the
 * probes beside this one ask.
 */
@:build(hxscript.macro.Abstract.build())
@:enum
abstract HostFlag(Int) from Int to Int {
	var None = 0;
	var Add = 1;
	var Mul = 2;
}
