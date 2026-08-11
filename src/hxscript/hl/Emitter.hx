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
import hxscript.hl.TypeKind;
import hxscript.hl.Binding;
import hxscript.hl.Binding.BindingKind;
import hxscript.hl.Bytecode.Instruction;
import hxscript.compile.Unsupported;
import hxscript.hl.TypeEntry.Field;
import hxscript.hl.TypeEntry.Proto;
import hxscript.syntax.Expr;

/** What a batch function looks like to a caller, before or after its body has been written. */
@:structInit
class Signature {
	/** The index calls reach it by. */
	public var findex:Int;

	/** Its argument types, as indices into the module's type table. */
	public var args:Array<Int>;

	/** Its return type. */
	public var ret:Int;

	/** The type table entry for the function itself. */
	public var type:Int;
}

/**
 * Turns a script's declarations into HashLink instructions.
 *
 * Two things make this harder than writing cppia. Registers are typed and allocated per function
 * rather than being a stack, so every value needs somewhere with the right type to live. And there
 * is no instruction that produces a boolean from a comparison: comparisons ARE jumps. A condition
 * is therefore emitted as control flow, and only a comparison read as a value pays for the pair of
 * jumps that turns it back into one.
 *
 * What it will not compile it refuses, which leaves the module interpreted and correct.
 */
class Emitter {
	/** The module being filled. */
	var module:Bytecode;

	/** Every batch function a call can reach, by the name a script writes. */
	var signatures:StringMap<Signature>;

	/** The instructions of the function being written. */
	var ops:Array<Instruction>;

	/** The type of each register in the function being written. */
	var regs:Array<Int>;

	/** Local name to register, innermost scope last. */
	var scopes:Array<StringMap<Int>>;

	/** Where each `break` in the loop being written is, so its jump can be filled in at the end. */
	var breaks:Array<Array<Int>>;

	/** Where each `continue` is, filled in the same way. */
	var continues:Array<Array<Int>>;

	/** The declared return type of the function being written. */
	var returns:Int;

	/** The class whose body is being written, which is what an unqualified call names. */
	var owning:String;

	/** The type index of each class in the batch. */
	var classes:StringMap<Int>;

	/** Which slot each instance field sits in, by class then field name. */
	var members:StringMap<StringMap<Int>>;

	/** The type of each instance field, by class then slot. */
	var memberTypes:StringMap<Array<Int>>;

	/** The class the body being written belongs to, or null when it is a static. */
	var inside:Null<String>;

	/** The global each bound value sits in, by what identifies it. */
	var hostSlots:StringMap<Int>;

	/**
	 * Every value this module needs handed to it, in the order the globals were made.
	 *
	 * A compiled function cannot link to anything outside its own module, so what it names is
	 * fetched once after loading and left in a global. The alternative is a lookup per use, which is
	 * most of what makes the interpreter slow in the first place.
	 */
	public var bindings(default, null):Array<Binding>;

	var tVoid:Int;
	var tI32:Int;
	var tF64:Int;
	var tBool:Int;
	var tDyn:Int;

	/** Starts an emitter over a fresh module. */
	public function new() {
		module = new Bytecode();
		signatures = new StringMap();
		ops = [];
		regs = [];
		scopes = [];
		breaks = [];
		continues = [];
		returns = 0;
		owning = '';
		classes = new StringMap();
		members = new StringMap();
		memberTypes = new StringMap();
		inside = null;
		hostSlots = new StringMap();
		bindings = [];

		tVoid = module.prim(HVoid);
		tI32 = module.prim(HI32);
		tF64 = module.prim(HF64);
		tBool = module.prim(HBool);
		tDyn = module.prim(HDyn);
	}

	/**
	 * Declares every static function a batch offers, before any body is written.
	 *
	 * Two passes are not optional: a function may call one declared after it, or call itself, and a
	 * call needs the callee's index and shape.
	 *
	 * @param decls The declarations to scan.
	 * @param owner How to name the class they belong to.
	 */
	public function declare(decls:Array<ModuleDecl>, owner:String):Void {
		for (decl in decls) {
			switch (decl.d) {
				case DClass(c):
					classes.set(c.name, module.reserveType());
				case _:
			}
		}

		for (decl in decls) {
			switch (decl.d) {
				case DClass(c):
					shape(c);
				case _:
			}
		}
	}

	/**
	 * Works out a class's instance shape and declares everything it offers.
	 *
	 * Its own type index already exists, because its methods take it as their first argument and a
	 * class whose methods could not be typed until the class was typed could never be declared.
	 *
	 * @param c The class.
	 */
	function shape(c:ClassDecl):Void {
		var self:Int = classes.get(c.name);
		var fields:Array<Field> = [];
		var protos:Array<Proto> = [];
		var slots:StringMap<Int> = new StringMap();

		for (f in c.fields) {
			if (isStatic(f))
				continue;

			switch (f.kind) {
				case KVar(v):
					slots.set(f.name, fields.length);
					fields.push({name: module.stringId(f.name), type: typeOf(v.type)});
				case _:
			}
		}

		members.set(c.name, slots);
		memberTypes.set(c.name, [for (f in fields) f.type]);

		for (f in c.fields) {
			var fn:Null<FunctionDecl> = switch (f.kind) {
				case KFunction(d): d;
				case _: null;
			}
			if (fn == null)
				continue;

			var args:Array<Int> = [];

			if (!isStatic(f))
				args.push(self);

			for (a in fn.args)
				args.push(typeOf(a.t));

			// A function that declares no return type still returns something, unless it is a
			// constructor. Reading it as `Void` would compile away the value it hands back.
			var ret:Int = fn.ret != null ? typeOf(fn.ret) : (f.name == 'new' ? tVoid : tDyn);

			var sig:Signature = {
				findex: module.reserve(),
				args: args,
				ret: ret,
				type: module.typeId(TFun(args, ret))
			};

			if (isStatic(f)) {
				signatures.set(c.name + '.' + f.name, sig);
			} else {
				signatures.set(c.name + '#' + f.name, sig);
				protos.push({name: module.stringId(f.name), findex: sig.findex});
			}
		}

		module.defineType(self, TObj(module.stringId(c.name), fields, protos));
	}

	/**
	 * Writes the bodies of everything `declare` accepted.
	 *
	 * @param decls The declarations.
	 * @param owner How to name the class they belong to.
	 * @throws Unsupported If a body uses something with no instruction here.
	 */
	public function emit(decls:Array<ModuleDecl>, owner:String):Void {
		for (decl in decls) {
			switch (decl.d) {
				case DClass(c):
					owning = c.name;
					for (f in c.fields) {
						switch (f.kind) {
							case KFunction(fn):
								var key:String = c.name + (isStatic(f) ? '.' : '#') + f.name;
								var sig:Null<Signature> = signatures.get(key);
								if (sig == null)
									throw new Unsupported(key + ', whose signature this cannot express', decl.pos);
								emitFunction(sig, fn, decl.pos, isStatic(f) ? null : c.name);

							case KVar(v):
								if (isStatic(f))
									throw new Unsupported('the static ' + f.name + ', which is not a function', decl.pos);
						}
					}

				case DPackage(_) | DImport(_, _):

				case _:
					throw new Unsupported('a declaration that is not a class', decl.pos);
			}
		}
	}

	/** @return The module, once every body has been written. */
	public function finish():Bytecode {
		return module;
	}

	/** @return The reserved index of a batch function, or null when there is none. */
	public function indexOf(name:String):Null<Int> {
		var sig:Null<Signature> = signatures.get(name);
		return sig == null ? null : sig.findex;
	}

	/**
	 * Wraps a batch function in one that boxes its result, so a host can call it.
	 *
	 * A host reads a result through a closure it has to be able to type, and the value a script
	 * produced has no type the host knows until it is boxed. Rather than make every function return
	 * `Dynamic` and lose the typed registers that make this worth doing, the typed function stays as
	 * it is and this stands in front of it.
	 *
	 * @param name The function to wrap.
	 * @return The wrapper's index, or null when there is no such function.
	 */
	public function expose(name:String):Null<Int> {
		var sig:Null<Signature> = signatures.get(name);
		if (sig == null)
			return null;

		var findex:Int = module.reserve();
		var body:Array<Instruction> = [];
		var slots:Array<Int> = sig.args.copy();

		var result:Int = slots.length;
		slots.push(sig.ret);

		var pass:Array<Int> = [result, sig.findex];
		for (i in 0...sig.args.length)
			pass.push(i);

		body.push({op: callFor(sig.args.length), args: pass});

		// Only a value with a type of its own needs boxing. Boxing one that is already dynamic wraps
		// the pointer rather than the value, and what comes back reads as its own address.
		if (sig.ret == tDyn) {
			body.push({op: ORet, args: [result]});
		} else if (sig.ret == tVoid) {
			var empty:Int = slots.length;
			slots.push(tDyn);
			body.push({op: ONull, args: [empty]});
			body.push({op: ORet, args: [empty]});
		} else {
			var boxed:Int = slots.length;
			slots.push(tDyn);
			body.push({op: OToDyn, args: [boxed, result]});
			body.push({op: ORet, args: [boxed]});
		}

		module.add({
			type: module.typeId(TFun(sig.args, tDyn)),
			findex: findex,
			regs: slots,
			ops: body
		});

		return findex;
	}

	/**
	 * Writes one function's registers and body.
	 *
	 * @param sig Its shape.
	 * @param fn Its declaration.
	 * @param pos Where it appears.
	 * @param host The class it belongs to, or null when it is a static.
	 */
	function emitFunction(sig:Signature, fn:FunctionDecl, pos:Position, ?host:String):Void {
		ops = [];
		regs = [];
		scopes = [];
		breaks = [];
		continues = [];
		returns = sig.ret;
		inside = host;

		push();

		var first:Int = 0;
		if (host != null) {
			regs.push(sig.args[0]);
			scopes[scopes.length - 1].set('this', 0);
			first = 1;
		}

		for (i in 0...fn.args.length) {
			regs.push(sig.args[i + first]);
			scopes[scopes.length - 1].set(fn.args[i].name, i + first);
		}

		statement(fn.expr);

		// Whether every path returns is not worked out here, so a body that can fall off its end gets
		// the value Haxe would have given it. Refusing instead would turn a `while (true)` whose exit
		// is a `return` into a module nobody compiles.
		if (ops.length == 0 || ops[ops.length - 1].op != ORet) {
			var slot:Int = reg(sig.ret);

			if (sig.ret == tI32)
				ops.push({op: OInt, args: [slot, module.intId(0)]});
			else if (sig.ret == tF64)
				ops.push({op: OFloat, args: [slot, module.floatId(0)]});
			else if (sig.ret == tBool)
				ops.push({op: OBool, args: [slot, 0]});
			else if (sig.ret != tVoid)
				ops.push({op: ONull, args: [slot]});

			ops.push({op: ORet, args: [slot]});
		}

		pop();

		module.add({
			type: sig.type,
			findex: sig.findex,
			regs: regs,
			ops: ops
		});
	}

	/**
	 * Writes an expression for its effect rather than its value.
	 *
	 * @param e The expression.
	 * @throws Unsupported If it has no instruction here.
	 */
	function statement(e:Expr):Void {
		switch (e.e) {
			case EBlock(body):
				push();
				for (item in body)
					statement(item);
				pop();

			case EVar(n, t, init, get, set, _):
				if (get != null || set != null)
					throw new Unsupported('a local with accessors', e.pos);
				if (init == null)
					throw new Unsupported('a local declared without a value', e.pos);

				var declared:Null<Int> = t == null ? null : typeOf(t);
				var slot:Int = reg(declared == null ? infer(init) : declared);
				into(init, slot);
				scopes[scopes.length - 1].set(n, slot);

			case EBinop('=', target, value):
				switch (target.e) {
					case EIdent(name) if (lookup(name) != null):
						into(value, lookup(name));

					case EIdent(name) if (fieldOf(thisExpr(e.pos), name) != null):
						setField(thisExpr(e.pos), name, value, e.pos);

					case EField(obj, name, _):
						setField(obj, name, value, e.pos);

					case EIdent(name):
						throw new Unsupported('an assignment to ' + name + ', which is not a local here', e.pos);

					case _:
						throw new Unsupported('an assignment to something that is neither a local nor a field', e.pos);
				}

			case EBinop(op, target, value) if (op.length > 1 && op.charAt(op.length - 1) == '=' && ASSIGNABLE.indexOf(op) >= 0):
				statement({e: EBinop('=', target, {e: EBinop(op.substr(0, op.length - 1), target, value), pos: e.pos}), pos: e.pos});

			case EIf(cond, yes, no):
				var toElse:Array<Int> = [];
				condition(cond, false, toElse);
				statement(yes);

				if (no == null) {
					land(toElse);
				} else {
					var over:Int = jump(OJAlways);
					land(toElse);
					statement(no);
					land([over]);
				}

			case EWhile(cond, body):
				var head:Int = mark();
				var out:Array<Int> = [];
				condition(cond, false, out);

				breaks.push([]);
				continues.push([]);
				statement(body);

				land(continues.pop());
				back(head);
				land(out);
				land(breaks.pop());

			case EFor(name, it, body):
				forRange(name, it, body, e.pos);

			case EReturn(value):
				if (value == null) {
					var slot:Int = reg(tVoid);
					ops.push({op: ORet, args: [slot]});
					return;
				}

				var slot:Int = reg(returns);
				into(value, slot);
				ops.push({op: ORet, args: [slot]});

			case EBreak:
				if (breaks.length == 0)
					throw new Unsupported('a break outside a loop', e.pos);
				breaks[breaks.length - 1].push(jump(OJAlways));

			case EContinue:
				if (continues.length == 0)
					throw new Unsupported('a continue outside a loop', e.pos);
				continues[continues.length - 1].push(jump(OJAlways));

			case EUnop(op, _, target) if (op == '++' || op == '--'):
				switch (target.e) {
					case EIdent(name):
						var slot:Null<Int> = lookup(name);
						if (slot == null)
							throw new Unsupported(name + ', which is not a local here', e.pos);
						if (regs[slot] != tI32)
							throw new Unsupported(op + ' on something that is not an Int', e.pos);
						ops.push({op: op == '++' ? OIncr : ODecr, args: [slot]});
					case _:
						throw new Unsupported(op + ' on something that is not a local', e.pos);
				}

			case ECall(_, _) | ENew(_, _):
				var slot:Int = reg(infer(e));
				into(e, slot);

			case EParent(inner):
				statement(inner);

			case _:
				throw new Unsupported('this expression as a statement', e.pos);
		}
	}

	/** Writes a `for` over an integer range, which is the only iterable here. */
	function forRange(name:String, it:Expr, body:Expr, pos:Position):Void {
		var low:Expr;
		var high:Expr;

		switch (it.e) {
			case EBinop('...', a, b):
				low = a;
				high = b;
			case EParent({e: EBinop('...', a, b)}):
				low = a;
				high = b;
			case _:
				throw new Unsupported('a for over something that is not an integer range', pos);
		}

		push();

		var counter:Int = reg(tI32);
		into(low, counter);

		var limit:Int = reg(tI32);
		into(high, limit);

		scopes[scopes.length - 1].set(name, counter);

		var head:Int = mark();
		var out:Array<Int> = [jump(OJSGte, [counter, limit])];

		breaks.push([]);
		continues.push([]);
		statement(body);

		land(continues.pop());
		ops.push({op: OIncr, args: [counter]});
		back(head);
		land(out);
		land(breaks.pop());

		pop();
	}

	/**
	 * Writes an expression so that its value ends up in a register.
	 *
	 * @param e The expression.
	 * @param slot The register to leave it in.
	 * @throws Unsupported If it has no instruction here.
	 */
	function into(e:Expr, slot:Int):Void {
		var want:Int = regs[slot];

		// A value on its way into a dynamic is boxed on the way rather than written raw. Writing an
		// int into a pointer slot is not a wrong number, it is a pointer, and what reads it next is
		// what falls over.
		if (want == tDyn) {
			var natural:Int = infer(e);
			if (natural != tDyn) {
				var raw:Int = reg(natural);
				into(e, raw);
				ops.push({op: OToDyn, args: [slot, raw]});
				return;
			}
		}

		switch (e.e) {
			case EConst(CInt(v)):
				if (want == tF64)
					ops.push({op: OFloat, args: [slot, module.floatId(v)]});
				else
					ops.push({op: OInt, args: [slot, module.intId(v)]});

			case EConst(CFloat(v)):
				ops.push({op: OFloat, args: [slot, module.floatId(v)]});

			case EConst(CString(s, _)):
				var held:Int = landing(slot);
				ops.push({op: OGetGlobal, args: [held, constSlot('s' + s, s)]});
				if (held != slot)
					move(held, slot);

			case EIdent('true'):
				ops.push({op: OBool, args: [slot, 1]});

			case EIdent('false'):
				ops.push({op: OBool, args: [slot, 0]});

			case EIdent(name):
				var from:Null<Int> = lookup(name);
				if (from != null) {
					move(from, slot);
					return;
				}

				var own:Null<Int> = fieldOf(thisExpr(e.pos), name);
				if (own == null)
					throw new Unsupported(name + ', which is neither a local nor a field here', e.pos);

				getField(thisExpr(e.pos), name, slot, e.pos);

			case EField(_, _, _) if (hostName(e) != null):
				var host:{owner:String, field:String} = hostName(e);
				emitHostRead(host.owner, host.field, slot);

			case EField(obj, name, _):
				getField(obj, name, slot, e.pos);

			case ENew(cls, params):
				emitNew(cls, params, slot, e.pos);

			case EParent(inner):
				into(inner, slot);

			case EMeta(_, _, inner):
				into(inner, slot);

			case ECheckType(inner, _) | ECast(inner, _):
				into(inner, slot);

			case EUnop('-', _, inner) if (infer(inner) == tDyn):
				callSupport('neg', [dynOf(inner)], slot);

			case EUnop('-', _, inner):
				var v:Int = reg(infer(inner));
				into(inner, v);
				ops.push({op: ONeg, args: [slot, v]});

			case EUnop('!', _, inner):
				var v:Int = reg(tBool);
				truth(inner, v);
				ops.push({op: ONot, args: [slot, v]});

			// HashLink has no complement instruction. Haxe defines it as flipping every bit, which is
			// what exclusive-or against all of them does.
			case EUnop('~', _, inner):
				var v:Int = reg(tI32);
				into(inner, v);

				var mask:Int = reg(tI32);
				ops.push({op: OInt, args: [mask, module.intId(-1)]});
				ops.push({op: OXor, args: [slot, v, mask]});

			case ETernary(cond, yes, no):
				var toNo:Array<Int> = [];
				condition(cond, false, toNo);
				into(yes, slot);

				var over:Int = jump(OJAlways);
				land(toNo);
				into(no, slot);
				land([over]);

			case EBinop(op, a, b) if (COMPARE.exists(op) || op == '&&' || op == '||'):
				materialise(e, slot);

			case EBinop(op, a, b) if (SUPPORT.exists(op) && (infer(a) == tDyn || infer(b) == tDyn)):
				callSupport(SUPPORT.get(op), [dynOf(a), dynOf(b)], slot);

			case EBinop(op, a, b):
				var code:Null<Opcode> = arithmetic(op);
				if (code == null)
					throw new Unsupported('the operator ' + op, e.pos);

				var shared:Int = INTEGRAL.indexOf(op) >= 0 ? tI32 : want;

				var left:Int = reg(shared);
				into(a, left);

				var right:Int = reg(op == '<<' || op == '>>' || op == '>>>' ? tI32 : shared);
				into(b, right);

				ops.push({op: code, args: [slot, left, right]});

			case ECall(callee, params):
				emitCall(callee, params, slot, e.pos);

			case _:
				throw new Unsupported('this expression as a value', e.pos);
		}
	}

	/** Writes a call to a batch function. */
	function emitCall(callee:Expr, params:Array<Expr>, slot:Int, pos:Position):Void {
		var method:Null<{on:Expr, sig:Signature}> = methodCall(callee);
		if (method != null) {
			if (params.length != method.sig.args.length - 1)
				throw new Unsupported('a call given ' + params.length + ' of its ' + (method.sig.args.length - 1) + ' arguments', pos);

			var self:Int = reg(method.sig.args[0]);
			into(method.on, self);

			var args:Array<Int> = [slot, method.sig.findex, self];
			for (i in 0...params.length) {
				var holder:Int = reg(method.sig.args[i + 1]);
				into(params[i], holder);
				args.push(holder);
			}

			ops.push({op: callFor(params.length + 1), args: args});
			return;
		}

		var sig:Null<Signature> = calledSignature(callee);
		if (sig == null) {
			var host:Null<{owner:String, field:String}> = hostName(callee);
			if (host != null) {
				emitHostCall(host.owner, host.field, params, slot, pos);
				return;
			}

			emitDynCall(callee, params, slot, pos);
			return;
		}

		if (params.length != sig.args.length)
			throw new Unsupported('a call given ' + params.length + ' of its ' + sig.args.length + ' arguments', pos);

		var args:Array<Int> = [slot, sig.findex];
		for (i in 0...params.length) {
			var holder:Int = reg(sig.args[i]);
			into(params[i], holder);
			args.push(holder);
		}

		ops.push({op: callFor(params.length), args: args});
	}

	/**
	 * The global holding a host value, making one the first time it is asked for.
	 *
	 * @param owner The host class's path.
	 * @param field The static's name.
	 * @return The global's index.
	 */
	function hostSlot(owner:String, field:String):Int {
		return bind('h' + owner + '.' + field, {index: 0, kind: BHost, owner: owner, field: field});
	}

	/**
	 * The global holding one of `Runtime`'s statics.
	 *
	 * @param field Which one.
	 * @return The global's index.
	 */
	function supportSlot(field:String):Int {
		return bind('s' + field, {index: 0, kind: BSupport, field: field});
	}

	/**
	 * The global holding a value the emitter already has.
	 *
	 * A string is the reason this exists. Building one in bytecode would make it this module's own
	 * `String` rather than the host's, and it would have to be built at every use; being handed one
	 * costs a global read instead. Strings do not change, so one global serves every use of a
	 * literal.
	 *
	 * @param key What distinguishes this value from another of the same shape.
	 * @param value The value.
	 * @return The global's index.
	 */
	function constSlot(key:String, value:Dynamic):Int {
		return bind('c' + key, {index: 0, kind: BConst, value: value});
	}

	/**
	 * Finds or makes the global for a binding.
	 *
	 * @param key What identifies it, so asking twice gives one global.
	 * @param binding What to record when it is new. Its index is filled in here.
	 * @return The global's index.
	 */
	function bind(key:String, binding:Binding):Int {
		var known:Null<Int> = hostSlots.get(key);
		if (known != null)
			return known;

		binding.index = module.global(tDyn);
		hostSlots.set(key, binding.index);
		bindings.push(binding);
		return binding.index;
	}

	/** @return A value for one of this module's support bindings. */
	public static function support(field:String):Dynamic {
		return Reflect.field(Runtime, field);
	}

	/**
	 * Writes a read of something the host owns.
	 *
	 * @param owner The host class's path.
	 * @param field The static's name.
	 * @param slot Where to leave the value.
	 */
	function emitHostRead(owner:String, field:String, slot:Int):Void {
		if (regs[slot] == tDyn) {
			ops.push({op: OGetGlobal, args: [slot, hostSlot(owner, field)]});
			return;
		}

		var held:Int = reg(tDyn);
		ops.push({op: OGetGlobal, args: [held, hostSlot(owner, field)]});
		ops.push({op: OSafeCast, args: [slot, held]});
	}

	/**
	 * Writes a call to something the host owns.
	 *
	 * The closure is read from a global rather than linked, and every argument is boxed first: the
	 * JIT turns a call through a `Dynamic` closure into `hl_dyn_call`, which insists on that and in
	 * exchange marshals the arguments and the result to whatever the host actually declared. The
	 * destination register's type is what the result is cast to, so a host result lands as the type
	 * the script asked for.
	 *
	 * @param owner The host class's path.
	 * @param field The static's name.
	 * @param params The arguments.
	 * @param slot Where to leave the result.
	 * @param pos Where it appears.
	 */
	function emitHostCall(owner:String, field:String, params:Array<Expr>, slot:Int, pos:Position):Void {
		var fn:Int = reg(tDyn);
		ops.push({op: OGetGlobal, args: [fn, hostSlot(owner, field)]});
		through(fn, params, slot);
	}

	/**
	 * Writes a call to something whose identity is only known while running.
	 *
	 * A method on a host object, or a local holding a function. The receiver is asked for the field
	 * by name and what comes back is called, which is what the interpreter does too, one instruction
	 * at a time instead of one tree walk at a time.
	 *
	 * @param callee What is being called.
	 * @param params The arguments.
	 * @param slot Where to leave the result.
	 * @param pos Where it appears.
	 */
	function emitDynCall(callee:Expr, params:Array<Expr>, slot:Int, pos:Position):Void {
		var fn:Int;

		switch (callee.e) {
			case EField(obj, name, _):
				var host:Int = dynOf(obj);
				fn = reg(tDyn);
				ops.push({op: ODynGet, args: [fn, host, module.stringId(name)]});

			case EParent(inner):
				emitDynCall(inner, params, slot, pos);
				return;

			case _:
				fn = dynOf(callee);
		}

		through(fn, params, slot);
	}

	/**
	 * Writes the call itself, once whatever is being called is in a register.
	 *
	 * Every argument is boxed first and the result lands in a dynamic. That is not a choice: the JIT
	 * turns a call through a dynamic closure into `hl_dyn_call`, which insists on it and in exchange
	 * marshals the arguments and the result to whatever was really declared. Handing the call a
	 * typed destination looks like it should work and does not, because the JIT then casts that
	 * register from its own type to its own type, which is nothing, and the raw pointer stays there
	 * as a plausible number.
	 *
	 * @param fn A dynamic register holding what to call.
	 * @param params The arguments.
	 * @param slot Where to leave the result.
	 */
	function through(fn:Int, params:Array<Expr>, slot:Int):Void {
		// Nothing here can know whether what was named really exists, and a global or a field left
		// null is what says it does not. Calling it would be an access violation with no message;
		// this raises the null the way reaching for a missing name anywhere else does.
		ops.push({op: ONullCheck, args: [fn]});

		var returned:Int = reg(tDyn);
		var args:Array<Int> = [returned, fn];

		for (p in params)
			args.push(dynOf(p));

		ops.push({op: OCallClosure, args: args});
		move(returned, slot);
	}

	/**
	 * Writes an instantiation: allocate, then run the constructor over what was allocated.
	 *
	 * @param cls The class being built.
	 * @param params Its constructor's arguments.
	 * @param slot Where to leave the instance.
	 * @param pos Where it appears.
	 */
	function emitNew(cls:String, params:Array<Expr>, slot:Int, pos:Position):Void {
		var self:Null<Int> = classes.get(cls);
		if (self == null)
			throw new Unsupported('new ' + cls + ', which is not a class of this batch', pos);

		ops.push({op: ONew, args: [slot]});

		var sig:Null<Signature> = signatures.get(cls + '#new');
		if (sig == null) {
			if (params.length > 0)
				throw new Unsupported('new ' + cls + ' with arguments, when it declares no constructor', pos);
			return;
		}

		if (params.length != sig.args.length - 1)
			throw new Unsupported('new ' + cls + ' given ' + params.length + ' of its ' + (sig.args.length - 1) + ' arguments', pos);

		var discard:Int = reg(sig.ret);
		var args:Array<Int> = [discard, sig.findex, slot];

		for (i in 0...params.length) {
			var holder:Int = reg(sig.args[i + 1]);
			into(params[i], holder);
			args.push(holder);
		}

		ops.push({op: callFor(params.length + 1), args: args});
	}

	/**
	 * @return The slot an instance field sits in, or null when the expression is not an instance of a
	 *         class of this batch or has no such field.
	 */
	function fieldOf(obj:Expr, name:String):Null<Int> {
		var cls:Null<String> = classNamed(typeOfExpr(obj));
		if (cls == null)
			return null;

		var slots:Null<StringMap<Int>> = members.get(cls);
		return slots == null ? null : slots.get(name);
	}

	/**
	 * Writes a field read, by offset when the batch declared the field and by name otherwise.
	 *
	 * Reading by name is what makes a host object usable: `ODynGet` asks the value itself, so a
	 * string's length or an object's member is one instruction whether or not anything here knew
	 * the field existed.
	 */
	function getField(obj:Expr, name:String, slot:Int, pos:Position):Void {
		var index:Null<Int> = fieldOf(obj, name);
		if (index != null) {
			var holder:Int = reg(typeOfExpr(obj));
			into(obj, holder);
			ops.push({op: OField, args: [slot, holder, index]});
			return;
		}

		var host:Int = dynOf(obj);
		var held:Int = landing(slot);
		ops.push({op: ODynGet, args: [held, host, module.stringId(name)]});

		if (held != slot)
			move(held, slot);
	}

	/** Writes a field write, by offset when the batch declared the field and by name otherwise. */
	function setField(obj:Expr, name:String, value:Expr, pos:Position):Void {
		var index:Null<Int> = fieldOf(obj, name);
		if (index != null) {
			var cls:String = classNamed(typeOfExpr(obj));
			var holder:Int = reg(typeOfExpr(obj));
			into(obj, holder);

			var v:Int = reg(memberTypes.get(cls)[index]);
			into(value, v);

			ops.push({op: OSetField, args: [holder, index, v]});
			return;
		}

		var host:Int = dynOf(obj);
		var v:Int = dynOf(value);
		ops.push({op: ODynSet, args: [host, module.stringId(name), v]});
	}

	/** @return An expression naming the instance the body being written belongs to. */
	function thisExpr(pos:Position):Expr {
		return {e: EIdent('this'), pos: pos};
	}

	/** @return The class a type index names, or null when it names something else. */
	function classNamed(type:Int):Null<String> {
		for (name => id in classes) {
			if (id == type)
				return name;
		}
		return null;
	}

	/** @return The type an expression produces, without refusing when it is an instance. */
	function typeOfExpr(e:Expr):Int {
		return infer(e);
	}

	/**
	 * Writes a comparison read as a value.
	 *
	 * HashLink has no instruction that leaves a comparison's answer in a register, so the answer is
	 * built from the jump the comparison already is. This is the only place that costs anything: a
	 * comparison used as a condition never comes through here.
	 *
	 * @param e The comparison.
	 * @param slot Where to leave the answer.
	 */
	function materialise(e:Expr, slot:Int):Void {
		var no:Array<Int> = [];
		condition(e, false, no);

		ops.push({op: OBool, args: [slot, 1]});
		var over:Int = jump(OJAlways);

		land(no);
		ops.push({op: OBool, args: [slot, 0]});
		land([over]);
	}

	/**
	 * Writes a condition as control flow.
	 *
	 * @param e The condition.
	 * @param wanted Which way the collected jumps should leave.
	 * @param exits Filled with the instructions whose jump has to be pointed somewhere.
	 */
	function condition(e:Expr, wanted:Bool, exits:Array<Int>):Void {
		switch (e.e) {
			case EParent(inner):
				condition(inner, wanted, exits);

			case EUnop('!', _, inner):
				condition(inner, !wanted, exits);

			case EBinop('&&', a, b):
				if (!wanted) {
					condition(a, false, exits);
					condition(b, false, exits);
				} else {
					var fall:Array<Int> = [];
					condition(a, false, fall);
					condition(b, true, exits);
					land(fall);
				}

			case EBinop('||', a, b):
				if (wanted) {
					condition(a, true, exits);
					condition(b, true, exits);
				} else {
					var fall:Array<Int> = [];
					condition(a, true, fall);
					condition(b, false, exits);
					land(fall);
				}

			// A comparison with a dynamic on either side is one the instructions cannot make, because
			// what it means depends on what is in there: two strings compare by their contents, two
			// abstracts through whichever `@:op` method they declare.
			case EBinop(op, a, b) if (COMPARE.exists(op) && (infer(a) == tDyn || infer(b) == tDyn)):
				var answer:Int = reg(tBool);
				var equality:Bool = op == '==' || op == '!=';
				callSupport(equality ? 'eq' : ORDERING.get(op), [dynOf(a), dynOf(b)], answer);

				var same:Bool = op == '!=' ? !wanted : wanted;
				exits.push(jump(same ? OJTrue : OJFalse, [answer]));

			case EBinop(op, a, b) if (COMPARE.exists(op)):
				var shared:Int = widest(infer(a), infer(b));

				var left:Int = reg(shared);
				into(a, left);

				var right:Int = reg(shared);
				into(b, right);

				var code:Opcode = wanted ? COMPARE.get(op) : COMPARE.get(INVERSE.get(op));
				exits.push(jump(code, [left, right]));

			case _:
				var v:Int = reg(tBool);
				truth(e, v);
				exits.push(jump(wanted ? OJTrue : OJFalse, [v]));
		}
	}

	/**
	 * Copies one register to another, converting where the two ends disagree about the type.
	 *
	 * This is the seam between the typed tier and the dynamic one, and the place a wrong answer
	 * hides rather than raises: writing an `Int` straight into a pointer slot is not a wrong number,
	 * it is a pointer, and what reads it next is what falls over.
	 */
	function move(from:Int, to:Int):Void {
		if (from == to)
			return;

		var a:Int = regs[from];
		var b:Int = regs[to];

		if (a == b) {
			ops.push({op: OMov, args: [to, from]});
			return;
		}

		if (a == tI32 && b == tF64) {
			ops.push({op: OToSFloat, args: [to, from]});
			return;
		}

		if (a == tF64 && b == tI32) {
			ops.push({op: OToInt, args: [to, from]});
			return;
		}

		if (b == tDyn) {
			ops.push({op: OToDyn, args: [to, from]});
			return;
		}

		if (a == tDyn) {
			ops.push({op: OSafeCast, args: [to, from]});
			return;
		}

		throw new Unsupported('a value of one type where another was declared', null);
	}

	/** @return A fresh dynamic register holding an expression's value. */
	function dynOf(e:Expr):Int {
		var slot:Int = reg(tDyn);
		into(e, slot);
		return slot;
	}

	/**
	 * @return Where a dynamic result should land: the destination itself when it can hold one, and
	 *         a register of its own when it cannot.
	 */
	inline function landing(slot:Int):Int {
		return regs[slot] == tDyn ? slot : reg(tDyn);
	}

	/**
	 * Writes a call to one of `Runtime`'s statics.
	 *
	 * @param field Which one.
	 * @param args Registers holding its arguments, each already dynamic.
	 * @param slot Where to leave the result.
	 */
	function callSupport(field:String, args:Array<Int>, slot:Int):Void {
		var fn:Int = reg(tDyn);
		ops.push({op: OGetGlobal, args: [fn, supportSlot(field)]});

		var returned:Int = reg(tDyn);
		var pass:Array<Int> = [returned, fn];
		for (a in args)
			pass.push(a);

		ops.push({op: OCallClosure, args: pass});
		move(returned, slot);
	}

	/** @return A fresh register of the given type. */
	function reg(type:Int):Int {
		regs.push(type);
		return regs.length - 1;
	}

	/** @return Where the next instruction will go, which is what a backward jump targets. */
	function mark():Int {
		ops.push({op: OLabel, args: []});
		return ops.length - 1;
	}

	/**
	 * Writes a jump whose target is not known yet.
	 *
	 * @param op The jump.
	 * @param before Whatever operands come before the offset.
	 * @return Where it was written, so `land` can fill the offset in.
	 */
	function jump(op:Opcode, ?before:Array<Int>):Int {
		var args:Array<Int> = before == null ? [] : before.copy();
		args.push(0);
		ops.push({op: op, args: args});
		return ops.length - 1;
	}

	/** Points every listed jump at wherever the next instruction goes. */
	function land(sites:Array<Int>):Void {
		for (site in sites) {
			var instr:Instruction = ops[site];
			instr.args[instr.args.length - 1] = ops.length - site - 1;
		}
	}

	/** Writes a jump back to a marked position. */
	function back(target:Int):Void {
		ops.push({op: OJAlways, args: [target - ops.length - 1]});
	}

	/** Opens a scope. */
	inline function push():Void {
		scopes.push(new StringMap());
	}

	/** Closes one. */
	inline function pop():Void {
		scopes.pop();
	}

	/** @return The register a name is bound to, innermost scope first, or null when it is unbound. */
	function lookup(name:String):Null<Int> {
		var i:Int = scopes.length - 1;
		while (i >= 0) {
			var found:Null<Int> = scopes[i].get(name);
			if (found != null)
				return found;
			i--;
		}
		return null;
	}

	/**
	 * Works out which register type an expression's value needs.
	 *
	 * Answers dynamic for anything it does not recognise rather than refusing. Being wrong about a
	 * type here costs the speed of a typed register; refusing costs the whole module its bytecode.
	 *
	 * @param e The expression.
	 * @return Its type.
	 */
	function infer(e:Expr):Int {
		return switch (e.e) {
			case EConst(CInt(_)): tI32;
			case EConst(CFloat(_)): tF64;
			case EIdent('true') | EIdent('false'): tBool;
			case EParent(inner): infer(inner);
			case EMeta(_, _, inner): infer(inner);
			case ECheckType(inner, t): typeOf(t);
			case EUnop('!', _, _): tBool;
			case EUnop(_, _, inner): infer(inner);

			case EIdent(name):
				var slot:Null<Int> = lookup(name);
				if (slot != null) {
					regs[slot];
				} else {
					var own:Null<Int> = inside == null ? null : members.get(inside).get(name);
					own == null ? tDyn : memberTypes.get(inside)[own];
				}

			case EBinop(op, a, b) if (COMPARE.exists(op) || op == '&&' || op == '||'): tBool;

			// Haxe fixes what these produce whatever they are given: the bitwise operators are always
			// integers, and a division is always a float even between two integers.
			case EBinop(op, _, _) if (INTEGRAL.indexOf(op) >= 0): tI32;
			case EBinop('/', _, _): tF64;

			case EBinop(_, a, b):
				var l:Int = infer(a);
				var r:Int = infer(b);
				(l == tDyn || r == tDyn) ? tDyn : widest(l, r);

			case ETernary(_, yes, no):
				var l:Int = infer(yes);
				var r:Int = infer(no);
				l == r ? l : ((l == tI32 && r == tF64) || (l == tF64 && r == tI32) ? tF64 : tDyn);

			case ENew(cls, _):
				var self:Null<Int> = classes.get(cls);
				self == null ? tDyn : self;

			case EField(obj, name, _):
				var cls:Null<String> = classNamed(infer(obj));
				var slot:Null<Int> = cls == null ? null : members.get(cls).get(name);
				slot == null ? tDyn : memberTypes.get(cls)[slot];

			case ECall(callee, _):
				var method:Null<{on:Expr, sig:Signature}> = methodCall(callee);
				if (method != null) {
					method.sig.ret;
				} else {
					var sig:Null<Signature> = calledSignature(callee);
					sig == null ? tDyn : sig.ret;
				}

			case _: tDyn;
		}
	}

	/** @return Whichever of two types the other converts to, which is Float when either is. */
	function widest(a:Int, b:Int):Int {
		return (a == tF64 || b == tF64) ? tF64 : a;
	}

	/**
	 * @return The type an annotation names.
	 *
	 * Anything with no register type of its own answers dynamic rather than refusing. That is what
	 * makes a script compile at all: a value whose type this cannot express is still a value the
	 * host owns and can be held, read and called, so the only thing lost by not knowing its type is
	 * the speed of a typed register.
	 */
	function typeOf(t:Null<CType>):Int {
		if (t == null)
			return tDyn;

		return switch (t) {
			case CTPath(['Int'], _): tI32;
			case CTPath(['Float'], _): tF64;
			case CTPath(['Bool'], _): tBool;
			case CTPath(['Void'], _): tVoid;
			case CTPath([name], _) if (classes.exists(name)): classes.get(name);
			case CTParent(inner): typeOf(inner);
			case _: tDyn;
		}
	}

	/**
	 * Works out whether an expression names something the host owns.
	 *
	 * Anything written `Owner.field` where `Owner` is capitalised and is not a class of this batch
	 * is taken to be the host's. Whether it really is cannot be settled here: the answer comes when
	 * the module is loaded and the binding is resolved, and a name nothing answers to leaves a null
	 * in the global rather than failing to compile.
	 *
	 * @param e The expression.
	 * @return The owner and field, or null when it is not that shape.
	 */
	function hostName(e:Expr):Null<{owner:String, field:String}> {
		return switch (e.e) {
			case EField({e: EIdent(owner)}, field, _) if (isTypeName(owner) && !classes.exists(owner) && !signatures.exists(owner + '.' + field)):
				{owner: owner, field: field};

			case ECall(callee, _):
				hostName(callee);

			case EParent(inner):
				hostName(inner);

			case _:
				null;
		}
	}

	/** @return Whether a name is written the way a type is, which is how a host owner is spotted. */
	inline function isTypeName(name:String):Bool {
		var head:String = name.charAt(0);
		return head == head.toUpperCase() && head != head.toLowerCase();
	}

	/**
	 * Works out whether a call is a method on an instance of a class in this batch.
	 *
	 * @param callee What is being called.
	 * @return What to call it on and its shape, or null when it is not one.
	 */
	function methodCall(callee:Expr):Null<{on:Expr, sig:Signature}> {
		switch (callee.e) {
			case EField(obj, name, _):
				var cls:Null<String> = try classNamed(infer(obj)) catch (e:Unsupported) null;
				if (cls == null)
					return null;

				var sig:Null<Signature> = signatures.get(cls + '#' + name);
				return sig == null ? null : {on: obj, sig: sig};

			case EIdent(name) if (inside != null && lookup(name) == null):
				var sig:Null<Signature> = signatures.get(inside + '#' + name);
				return sig == null ? null : {on: {e: EIdent('this'), pos: callee.pos}, sig: sig};

			case EParent(inner):
				return methodCall(inner);

			case _:
				return null;
		}
	}

	/**
	 * Works out which batch function a call reaches.
	 *
	 * A bare name is looked for on the class being written before anywhere else, which is what a
	 * script means when one static calls another beside it, itself included.
	 *
	 * @param callee What is being called.
	 * @return The signature, or null when it is not a function of this batch.
	 */
	function calledSignature(callee:Expr):Null<Signature> {
		var name:Null<String> = calledName(callee);
		if (name == null)
			return null;

		var here:Null<Signature> = signatures.get(owning + '.' + name);
		return here != null ? here : signatures.get(name);
	}

	/** @return The name a call names, or null when it is not a plain one. */
	function calledName(callee:Expr):Null<String> {
		return switch (callee.e) {
			case EIdent(name): name;
			case EField({e: EIdent(owner)}, name, _): owner + '.' + name;
			case EParent(inner): calledName(inner);
			case _: null;
		}
	}

	/** @return Whether a field is declared `static`. */
	function isStatic(f:FieldDecl):Bool {
		for (a in f.access) {
			if (a == AStatic)
				return true;
		}
		return false;
	}

	/** @return The call instruction that takes a given number of arguments. */
	function callFor(count:Int):Opcode {
		return switch (count) {
			case 0: OCall0;
			case 1: OCall1;
			case 2: OCall2;
			case 3: OCall3;
			case 4: OCall4;
			case _: OCallN;
		}
	}

	/**
	 * @return The instruction for an arithmetic operator, or null when there is none.
	 *
	 * The instruction is the same whether the operands are integers or floats: what it does is
	 * decided by the registers it is given, which is why the operand type is worked out before this
	 * is asked.
	 */
	function arithmetic(op:String):Null<Opcode> {
		return switch (op) {
			case '+': OAdd;
			case '-': OSub;
			case '*': OMul;
			case '/': OSDiv;
			case '%': OSMod;
			case '&': OAnd;
			case '|': OOr;
			case '^': OXor;
			case '<<': OShl;
			case '>>': OSShr;
			case '>>>': OUShr;
			case _: null;
		}
	}

	/**
	 * Writes an expression as a boolean.
	 *
	 * A dynamic cannot simply be cast: one holding anything but a boolean would throw rather than
	 * answer, and the interpreter answers false.
	 *
	 * @param e The expression.
	 * @param slot A boolean register to leave the answer in.
	 */
	function truth(e:Expr, slot:Int):Void {
		if (infer(e) == tDyn) {
			callSupport('truthy', [dynOf(e)], slot);
			return;
		}

		into(e, slot);
	}

	/** The `Runtime` static each operator becomes when either operand is dynamic. */
	static var SUPPORT:StringMap<String> = ['+' => 'add', '-' => 'sub', '*' => 'mul', '/' => 'div', '%' => 'mod'];

	/** The operators Haxe defines on integers however they are spelled. */
	static var INTEGRAL:Array<String> = ['&', '|', '^', '<<', '>>', '>>>'];

	/** The `Runtime` static each comparison becomes when either operand is dynamic. */
	static var ORDERING:StringMap<String> = ['<' => 'lt', '<=' => 'lte', '>' => 'gt', '>=' => 'gte'];

	/** The jump each comparison becomes when it is taken. */
	static var COMPARE:StringMap<Opcode> = [
		'<' => OJSLt, '<=' => OJSLte, '>' => OJSGt, '>=' => OJSGte, '==' => OJEq, '!=' => OJNotEq
	];

	/** The comparison that is true exactly when another is false. */
	static var INVERSE:StringMap<String> = [
		'<' => '>=', '<=' => '>', '>' => '<=', '>=' => '<', '==' => '!=', '!=' => '=='
	];

	/** The compound assignments that rewrite into an operation and a plain assignment. */
	static var ASSIGNABLE:Array<String> = ['+=', '-=', '*=', '/=', '%=', '&=', '|=', '^=', '<<=', '>>=', '>>>='];
}
#end
