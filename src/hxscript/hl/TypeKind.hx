package hxscript.hl;

/**
 * HashLink's type kinds, by the value the bytecode carries.
 *
 * Mirrors `hl_type_kind` in hashlink's `src/hl.h`. Only the ones this emitter can produce are named
 * here; the rest exist in the VM and are simply not reachable from a script yet.
 */
enum abstract TypeKind(Int) to Int {
	var HVoid = 0;
	var HI32 = 3;
	var HF64 = 6;
	var HBool = 7;
	var HBytes = 8;
	var HDyn = 9;
	var HFun = 10;
	var HObj = 11;
	var HArray = 12;
	var HNull = 19;
	var HMethod = 20;
}
