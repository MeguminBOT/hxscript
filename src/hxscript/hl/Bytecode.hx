/*
 * Copyright (c) 2026 MeguminBOT (hxScript)
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 * DEALINGS IN THE SOFTWARE.
 */

package hxscript.hl;

#if hxscript_hl
import haxe.ds.StringMap;
import haxe.io.Bytes;
import hxscript.hl.TypeKind;
import hxscript.hl.TypeEntry.Field;
import hxscript.hl.TypeEntry.Proto;

/** One instruction: its opcode and however many operands that opcode carries. */
@:structInit
class Instruction {
	public var op:Opcode;
	public var args:Array<Int>;
}

/** One native: a function the module calls and does not carry. */
@:structInit
class Native {
	/** The library, as an index into the string pool. */
	public var lib:Int;

	/** The name within it, as an index into the string pool. */
	public var name:Int;

	/** Index into the type table of its signature, which the loader checks against what it finds. */
	public var type:Int;

	/** The index calls reach it by. */
	public var findex:Int;
}

/** One function: what it looks like, where it lives, and what it runs. */
@:structInit
class Function {
	/** Index into the type table of this function's own type. */
	public var type:Int;

	/** The index calls reach it by, which is its identity across the whole module. */
	public var findex:Int;

	/** The type of each register, by register number. */
	public var regs:Array<Int>;

	/** Its body. */
	public var ops:Array<Instruction>;
}

/**
 * A HashLink module under construction: the pools, the type table, the functions, and the layout
 * that turns them into loadable bytes.
 *
 * Pools are content-addressed, so asking for the same value twice gives the same index and the
 * emitter never has to track what it has already added. The type table is the one that matters:
 * the reader identifies a type by its position, so two entries with the same shape are two
 * different types to it, and a function whose signature was pooled twice will not link.
 */
class Bytecode {
	/** The version this writes. Haxe 4.3 emits it and HashLink 1.13 onwards reads it. */
	public static inline var VERSION:Int = 4;

	var ints:Array<Int>;
	var intIds:Map<Int, Int>;

	var floats:Array<Float>;
	var floatIds:StringMap<Int>;

	var strings:Array<String>;
	var stringIds:StringMap<Int>;

	var types:Array<TypeEntry>;
	var typeIds:StringMap<Int>;

	var globals:Array<Int>;
	var natives:Array<Native>;
	var functions:Array<Function>;

	/** The function index the loader starts at. */
	public var entry:Int = 0;

	/** The next unused function index, so a caller does not have to track them. */
	public var nextFindex(default, null):Int = 0;

	/** Starts an empty module. */
	public function new() {
		ints = [];
		intIds = new Map();
		floats = [];
		floatIds = new StringMap();
		strings = [];
		stringIds = new StringMap();
		types = [];
		typeIds = new StringMap();
		globals = [];
		natives = [];
		functions = [];
	}

	/** @return The index of an integer constant, pooling it if it is new. */
	public function intId(v:Int):Int {
		var known:Null<Int> = intIds.get(v);
		if (known != null)
			return known;

		var id:Int = ints.length;
		ints.push(v);
		intIds.set(v, id);
		return id;
	}

	/** @return The index of a float constant, pooling it if it is new. */
	public function floatId(v:Float):Int {
		var key:String = Std.string(v);
		var known:Null<Int> = floatIds.get(key);
		if (known != null)
			return known;

		var id:Int = floats.length;
		floats.push(v);
		floatIds.set(key, id);
		return id;
	}

	/** @return The index of a string, pooling it if it is new. */
	public function stringId(v:String):Int {
		var known:Null<Int> = stringIds.get(v);
		if (known != null)
			return known;

		var id:Int = strings.length;
		strings.push(v);
		stringIds.set(v, id);
		return id;
	}

	/** @return The index of a type, pooling it if its shape is new. */
	public function typeId(t:TypeEntry):Int {
		var key:String = shapeOf(t);
		var known:Null<Int> = typeIds.get(key);
		if (known != null)
			return known;

		var id:Int = types.length;
		types.push(t);
		typeIds.set(key, id);
		return id;
	}

	/** @return The index of a primitive type, pooling it if it is new. */
	public inline function prim(kind:TypeKind):Int {
		return typeId(TPrim(kind));
	}

	/**
	 * Takes a type's place in the table before its shape is known.
	 *
	 * A class's methods take the class as their first argument, so its own index has to exist before
	 * any of them can be typed.
	 *
	 * @return The index to fill in later.
	 */
	public function reserveType():Int {
		types.push(TPrim(HDyn));
		return types.length - 1;
	}

	/** Fills in a reserved type. */
	public function defineType(id:Int, t:TypeEntry):Void {
		types[id] = t;
	}

	/**
	 * @return A key that is equal exactly when two types would be the same entry.
	 *
	 * A class is keyed by its own name rather than by its shape, so two classes that happen to
	 * declare the same fields stay two types.
	 */
	function shapeOf(t:TypeEntry):String {
		return switch (t) {
			case TPrim(kind): 'p' + (kind : Int);
			case TFun(args, ret): 'f' + args.join(',') + '>' + ret;
			case TObj(name, _, _, _, _): 'o' + name;
		}
	}

	/**
	 * Adds a global.
	 *
	 * @param type Its type. Only a pointer type may be written into after loading, which is what the
	 *        VM roots and therefore what the collector can see.
	 * @return Its index.
	 */
	public function global(type:Int):Int {
		globals.push(type);
		return globals.length - 1;
	}

	/**
	 * Reserves the next function index.
	 *
	 * Indices are handed out before bodies are written, because a function that calls another needs
	 * the other's index and the two may call each other.
	 *
	 * @return The reserved index.
	 */
	public function reserve():Int {
		return nextFindex++;
	}

	/**
	 * Declares a function the module calls and does not carry.
	 *
	 * @param lib Where it comes from. `hxs` is hxScript's own runtime, in this same binary.
	 * @param name Its name there.
	 * @param type Index into the type table of its signature.
	 * @return The index calls reach it by.
	 */
	public function native(lib:String, name:String, type:Int):Int {
		var findex:Int = nextFindex++;
		natives.push({
			lib: stringId(lib),
			name: stringId(name),
			type: type,
			findex: findex
		});
		return findex;
	}

	/** Adds a finished function. */
	public function add(f:Function):Void {
		functions.push(f);
	}

	/**
	 * Lays the module out.
	 *
	 * @return The bytes, ready for the loader.
	 */
	public function pack():Bytes {
		var w:Writer = new Writer();

		w.byte('H'.code);
		w.byte('L'.code);
		w.byte('B'.code);
		w.byte(VERSION);

		w.uindex(0);
		w.uindex(ints.length);
		w.uindex(floats.length);
		w.uindex(strings.length);
		w.uindex(types.length);
		w.uindex(globals.length);
		w.uindex(natives.length);
		w.uindex(functions.length);
		w.uindex(0);
		w.uindex(entry);

		for (v in ints)
			w.int32(v);
		for (v in floats)
			w.float64(v);

		w.stringPool(strings);

		for (t in types)
			writeType(w, t);

		for (g in globals)
			w.index(g);

		for (n in natives) {
			w.index(n.lib);
			w.index(n.name);
			w.index(n.type);
			w.uindex(n.findex);
		}

		for (f in functions)
			writeFunction(w, f);

		return w.done();
	}

	/** Writes one type-table entry. */
	function writeType(w:Writer, t:TypeEntry):Void {
		switch (t) {
			case TPrim(kind):
				w.byte(kind);

			case TFun(args, ret):
				w.byte(HFun);
				w.byte(args.length);
				for (a in args)
					w.index(a);
				w.index(ret);

			case TObj(name, fields, protos, base, global):
				w.byte(HObj);
				w.index(name);
				w.index(base);
				w.uindex(global);
				w.uindex(fields.length);
				w.uindex(protos.length);
				w.uindex(0);

				for (f in fields) {
					w.index(f.name);
					w.index(f.type);
				}

				for (p in protos) {
					w.index(p.name);
					w.uindex(p.findex);
					w.index(p.pindex);
				}
		}
	}

	/** Writes one function: its shape, its registers, then its body. */
	function writeFunction(w:Writer, f:Function):Void {
		w.index(f.type);
		w.uindex(f.findex);
		w.uindex(f.regs.length);
		w.uindex(f.ops.length);

		for (r in f.regs)
			w.index(r);

		for (op in f.ops)
			writeInstr(w, op);
	}

	/**
	 * Writes one instruction.
	 *
	 * The operand count comes from the opcode rather than from the caller, so an instruction built
	 * with the wrong number of operands is caught here instead of desynchronising the reader and
	 * failing somewhere unrelated.
	 *
	 * @param w Where to write.
	 * @param instr The instruction.
	 * @throws String If it carries the wrong number of operands.
	 */
	function writeInstr(w:Writer, instr:Instruction):Void {
		var expected:Int = Opcode.ARGS[instr.op];
		w.byte(instr.op);

		if (expected >= 0) {
			if (instr.args.length != expected)
				throw 'opcode ' + (instr.op : Int) + ' takes ' + expected + ' operands, got ' + instr.args.length;

			for (a in instr.args)
				w.index(a);
			return;
		}

		if (instr.args.length < 2)
			throw 'variable-length opcode ' + (instr.op : Int) + ' needs a destination and a target';

		w.index(instr.args[0]);
		w.index(instr.args[1]);
		w.byte(instr.args.length - 2);
		for (i in 2...instr.args.length)
			w.index(instr.args[i]);
	}
}
#end
