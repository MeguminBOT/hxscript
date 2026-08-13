package hxscript.hl;

/**
 * HashLink's instruction set, by the value the bytecode carries.
 *
 * Mirrors `src/opcodes.h` of hashlink 1.16 in declaration order, because the wire format is the
 * ordinal rather than the name. Generated from that file rather than transcribed, and it has to be
 * regenerated if the VM this targets ever moves.
 */
enum abstract Opcode(Int) to Int {
	var OMov = 0;
	var OInt = 1;
	var OFloat = 2;
	var OBool = 3;
	var OBytes = 4;
	var OString = 5;
	var ONull = 6;
	var OAdd = 7;
	var OSub = 8;
	var OMul = 9;
	var OSDiv = 10;
	var OUDiv = 11;
	var OSMod = 12;
	var OUMod = 13;
	var OShl = 14;
	var OSShr = 15;
	var OUShr = 16;
	var OAnd = 17;
	var OOr = 18;
	var OXor = 19;
	var ONeg = 20;
	var ONot = 21;
	var OIncr = 22;
	var ODecr = 23;
	var OCall0 = 24;
	var OCall1 = 25;
	var OCall2 = 26;
	var OCall3 = 27;
	var OCall4 = 28;
	var OCallN = 29;
	var OCallMethod = 30;
	var OCallThis = 31;
	var OCallClosure = 32;
	var OStaticClosure = 33;
	var OInstanceClosure = 34;
	var OVirtualClosure = 35;
	var OGetGlobal = 36;
	var OSetGlobal = 37;
	var OField = 38;
	var OSetField = 39;
	var OGetThis = 40;
	var OSetThis = 41;
	var ODynGet = 42;
	var ODynSet = 43;
	var OJTrue = 44;
	var OJFalse = 45;
	var OJNull = 46;
	var OJNotNull = 47;
	var OJSLt = 48;
	var OJSGte = 49;
	var OJSGt = 50;
	var OJSLte = 51;
	var OJULt = 52;
	var OJUGte = 53;
	var OJNotLt = 54;
	var OJNotGte = 55;
	var OJEq = 56;
	var OJNotEq = 57;
	var OJAlways = 58;
	var OToDyn = 59;
	var OToSFloat = 60;
	var OToUFloat = 61;
	var OToInt = 62;
	var OSafeCast = 63;
	var OUnsafeCast = 64;
	var OToVirtual = 65;
	var OLabel = 66;
	var ORet = 67;
	var OThrow = 68;
	var ORethrow = 69;
	var OSwitch = 70;
	var ONullCheck = 71;
	var OTrap = 72;
	var OEndTrap = 73;
	var OGetI8 = 74;
	var OGetI16 = 75;
	var OGetMem = 76;
	var OGetArray = 77;
	var OSetI8 = 78;
	var OSetI16 = 79;
	var OSetMem = 80;
	var OSetArray = 81;
	var ONew = 82;
	var OArraySize = 83;
	var OType = 84;
	var OGetType = 85;
	var OGetTID = 86;
	var ORef = 87;
	var OUnref = 88;
	var OSetref = 89;
	var OMakeEnum = 90;
	var OEnumAlloc = 91;
	var OEnumIndex = 92;
	var OEnumField = 93;
	var OSetEnumField = 94;
	var OAssert = 95;
	var ORefData = 96;
	var ORefOffset = 97;
	var ONop = 98;
	var OPrefetch = 99;
	var OAsm = 100;
	var OCatch = 101;
	var OLast = 102;

	/**
	 * How many operands an instruction carries, indexed by opcode.
	 *
	 * `-1` marks the variable-length forms, which write a count and then that many operands. The
	 * numbers come from the same header's own arithmetic over its operand kinds, so a reader and
	 * this writer cannot disagree about how far to advance.
	 */
	public static final ARGS:Array<Int> = [2, 2, 2, 2, 2, 2, 1, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 2, 2, 1, 1, 2, 3, 4, 5, 6, -1, -1, -1, -1, 2, 3, 3, 2, 2, 3, 3, 2, 2, 3, 3, 2, 2, 2, 2, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 1, 2, 2, 2, 2, 2, 2, 2, 0, 1, 1, 1, -1, 1, 2, 1, 3, 3, 3, 3, 3, 3, 3, 3, 1, 2, 2, 2, 2, 2, 2, 2, -1, 2, 2, 4, 3, 0, 2, 3, 0, 3, 3, 1, 0];

	/** @return How many operands this instruction carries, or -1 when it is variable-length. */
	public inline function args():Int {
		return ARGS[this];
	}
}
