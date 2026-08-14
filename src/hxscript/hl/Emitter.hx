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
import hxscript.compile.Accessors;
import hxscript.compile.Capture;
import hxscript.compile.Unsupported;
import hxscript.hl.Emitted;
import hxscript.hl.Emitted.Link;
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

	/**
	 * Whether the last argument collects everything the call had left over.
	 *
	 * The function itself takes one array there and needs no telling. It is the call sites that do:
	 * a call passing three arguments to a function that declares one is not a mistake to refuse, it
	 * is three values to gather into the array first.
	 */
	public var rest:Bool = false;

	/**
	 * Whether the shape is the world's rather than the script's, because it overrides a method the
	 * world declared. An argument the world always supplies has no default to fill in, and a typed
	 * register has nowhere to put the null that would say it was left out.
	 */
	public var hosted:Bool = false;
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

	/**
	 * The classes of the batch, as a set.
	 *
	 * A name and nothing else, because a class of the batch is no longer a type this module holds.
	 * The interpreter's own object is what a script gets from `new`, and this module contributes the
	 * bodies of its methods; so what there is to know here is only whether a name is one of them.
	 */
	var classes:StringMap<Bool>;

	/**
	 * The names each class declares as instance members, by class.
	 *
	 * Names and nothing else. Where a field sits and what type it holds are the world's business now,
	 * but whether a bare name inside a method means `this.name` is still this module's, because that
	 * is decided when the body is written rather than when it runs.
	 */
	var members:StringMap<StringMap<Bool>>;

	/** The base each class of the batch extends, when that base is also of the batch. */
	var bases:StringMap<String>;

	/**
	 * Classes whose chain ends at a base this batch did not declare.
	 *
	 * Their members cannot be listed here, because the base is the host's and what it offers is only
	 * known once the world has it. A bare name in one of those is therefore taken to be a field of
	 * the instance rather than refused, which is what the interpreter does with the same name.
	 */
	var opened:StringMap<Bool>;

	/** The accessors of each property, by class then name. A property is not a field. */
	var props:StringMap<StringMap<{get:String, set:String}>>;

	/** Members written `var x(null, ...)`, which nothing may read, by class then name. */
	var unreadable:StringMap<StringMap<Bool>>;

	/**
	 * What may be reached as storage rather than through the world, by class then name.
	 *
	 * `READS` and `WRITES` say which side of an access is plain. A declaration with an accessor on a
	 * side keeps going through the world's own reader there, whatever storage stands behind it, so
	 * that a `dynamic` getter or a setter with a `default` getter means what it means interpreted.
	 */
	var reach:StringMap<StringMap<Int>>;

	/** The read side of a declaration is plain storage. */
	static inline var READS:Int = 1;

	/** The write side of a declaration is plain storage. */
	static inline var WRITES:Int = 2;

	/** It keeps storage at all, which is what a field is laid out for. */
	static inline var KEEPS:Int = 4;

	/** The names each class declares as statics, by class. */
	var owned:StringMap<StringMap<Bool>>;

	/**
	 * The register type each declared field's annotation names, by class then name.
	 *
	 * Where a field is stored is the world's business and this does not change that: a field is read
	 * and written through `Runtime`, as a dynamic, whatever is recorded here. What this is for is
	 * arithmetic. A field written `:Int` is an `Int`, and `Int` arithmetic wraps, but a dynamic
	 * operand sends the operation to `Runtime.add`, which promotes because reaching it means nothing
	 * said the operand was an `Int`. Recording the annotation is what lets the emitter say so, and
	 * the value is then converted into a typed register and added with an instruction.
	 *
	 * Only fields with an annotation are here, and only classes of this batch. A field of a host base
	 * is absent, which reads as dynamic, which is the truth about it.
	 */
	var memberTypes:StringMap<StringMap<Int>>;

	/**
	 * Types the batch declares that are not classes, and the enum each constructor belongs to.
	 *
	 * An enum, an abstract or a typedef is built by the interpreter when the module starts, so
	 * nothing is written here for one. What compiled code needs is a way to reach the one the world
	 * holds, which is the same way it reaches a class of the batch.
	 */
	var declared:StringMap<Bool>;

	/** Which enum each constructor name belongs to, so a bare one can be resolved. */
	var constructors:StringMap<String>;

	/**
	 * Bare names the host answers with a static of its own, as owner and field.
	 *
	 * A host may put a name in scope that is neither a local, a field, nor a type: a helper it gives
	 * every script, such as `log` or `trace`. The interpreter has one injected into it, and compiled
	 * code has no interpreter to inject into, so the name has to be reached where it actually lives.
	 */
	var ambientMembers:StringMap<{owner:String, field:String}>;

	/** Whether the module declares fields of its own, outside any class. */
	var loose:Bool;

	/** Types the module brought into scope with `using`, whose statics stand in as methods. */
	var usings:Array<String>;

	/** The package the batch sits in, which is what a class has to be resolved by. */
	public var pack:String = '';

	/** The class the body being written belongs to, or null when it is a static. */
	var inside:Null<String>;

	/** The global each bound value sits in, by what identifies it. */
	var hostSlots:StringMap<Int>;

	/** Where a comprehension is gathering, or null when a loop is just a loop. */
	var collector:Null<{slot:Int, pairs:Bool}>;

	/**
	 * How many traps are open around what is being written.
	 *
	 * A trap the VM is holding has to be given back before the function it belongs to goes away, and
	 * returning out of the middle of a `try` skips the instruction that would have done it. Leaving
	 * one behind does not fail here: it fails in whatever runs next and reaches for a handler that
	 * belongs to a function that has already returned.
	 */
	var traps:Int;

	/**
	 * Every value this module needs handed to it, in the order the globals were made.
	 *
	 * A compiled function cannot link to anything outside its own module, so what it names is
	 * fetched once after loading and left in a global. The alternative is a lookup per use, which is
	 * most of what makes the interpreter slow in the first place.
	 */
	public var bindings(default, null):Array<Binding>;

	/**
	 * The type each class of the batch is, by name.
	 *
	 * A class of the batch is a type this module holds: its own entry in the table, its fields laid
	 * out after whatever it extends, and its methods in the table a virtual call dispatches through.
	 * That is what makes a field an offset rather than a question, which is the whole of why this
	 * exists.
	 */
	var shapes:StringMap<Int>;

	/** Which class each of those types is, so a register's type says what it holds. */
	var owners:Map<Int, String>;

	/**
	 * Whether what is being written is a field's starting value rather than an assignment.
	 *
	 * A declaration's starting value goes into storage even when a setter stands in front of it,
	 * which is what Haxe does with the same line.
	 */
	var initialising:Bool = false;

	/**
	 * The method whose body is being written, or null outside one.
	 *
	 * Read only to keep a property's own accessor from calling itself: inside `get_x`, `x` is the
	 * storage behind the property rather than another read of the property.
	 */
	var writing:Null<String> = null;

	/** The global each class's own value goes in, by name. */
	var values:StringMap<Int>;

	/** Where each field sits, counting the ones the class inherits, by class then name. */
	var slots:StringMap<StringMap<Int>>;

	/** The register type of each field this batch lays out, by class then name. */
	var slotTypes:StringMap<StringMap<Int>>;

	/** How many fields each class has, counting the ones it inherits. */
	var widths:StringMap<Int>;

	/** Where each method sits in the table a virtual call goes through, by class then name. */
	var entries:StringMap<StringMap<Int>>;

	/** How many entries each class's method table has, counting the ones it inherits. */
	var tables:StringMap<Int>;

	/** The base the world already has, for each class whose chain leaves the batch. */
	var hosts:StringMap<hl.Type>;

	/**
	 * The world's class each local was written with, innermost scope last.
	 *
	 * Not a register type: a class of the world is not a type this module holds, and a value of one
	 * stays in a dynamic register. What this is for is knowing what a member of it answers, so that
	 * a call into the world lands in a register of the right kind rather than in a boxed one.
	 */
	var annotated:Array<StringMap<String>>;

	/**
	 * What each local written `Array<T>` holds, as a register type, innermost scope last.
	 *
	 * An element read out of one is a dynamic however the array was written, so everything done with
	 * it afterwards was dynamic too. Saying what it is turns a sweep over a typed array into a cast
	 * and an offset.
	 */
	var elements:Array<StringMap<Int>>;

	/** What the world answered for each type name a script wrote, asked once. */
	var known:StringMap<Null<hl.Type>>;

	/** What kind each member of one of those is, by class name then member. */
	var answers:StringMap<Int>;

	/** The type each class's own value is, which is where its statics sit. */
	var holders:StringMap<Int>;

	/** Where each static sits in that type, by class then name. */
	var staticSlots:StringMap<StringMap<Int>>;

	/** The register type of each static, by class then name. */
	var staticTypes:StringMap<StringMap<Int>>;

	/** Each class of the batch, in the order they were laid out. */
	public var emitted(default, null):Array<Emitted>;

	/** Every type that stands for a class the world already has, for the loader to point at the real one. */
	public var links(default, null):Array<Link>;

	/**
	 * What a name the script wrote refers to in the world.
	 *
	 * A class extending one the world has needs that class before anything can be laid out, because
	 * where its own first field sits is decided by how many the base already has. Only a host can
	 * answer that, so the answer is handed in rather than worked out here.
	 */
	public dynamic function world(name:String):Dynamic {
		return null;
	}

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
		annotated = [];
		elements = [];
		breaks = [];
		continues = [];
		returns = 0;
		owning = '';
		classes = new StringMap();
		members = new StringMap();
		bases = new StringMap();
		opened = new StringMap();
		props = new StringMap();
		unreadable = new StringMap();
		reach = new StringMap();
		owned = new StringMap();
		memberTypes = new StringMap();
		declared = new StringMap();
		constructors = new StringMap();
		ambientMembers = new StringMap();
		loose = false;
		usings = [];
		inside = null;
		hostSlots = new StringMap();
		collector = null;
		traps = 0;
		bindings = [];
		shapes = new StringMap();
		owners = new Map();
		values = new StringMap();
		slots = new StringMap();
		slotTypes = new StringMap();
		widths = new StringMap();
		entries = new StringMap();
		tables = new StringMap();
		hosts = new StringMap();
		known = new StringMap();
		answers = new StringMap();
		holders = new StringMap();
		staticSlots = new StringMap();
		staticTypes = new StringMap();
		emitted = [];
		links = [];

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
					classes.set(c.name, true);
					declared.set(c.name, true);

				case DEnum(e):
					declared.set(e.name, true);
					for (name in e.names)
						constructors.set(name, e.name);

				case DAbstract(a):
					declared.set(a.name, true);

				case DInterface(i):
					declared.set(i.name, true);

				case DTypedef(t):
					declared.set(t.name, true);

				case DField(_):
					loose = true;

				case DUsing(path):
					usings.push(path.join('.'));

				case _:
			}
		}

		/**
		 * Every class takes its place in the type table before any of them is shaped, because a
		 * method takes its own class as its first argument and there is no shaping one of those
		 * without an index to give it.
		 */
		for (decl in decls) {
			switch (decl.d) {
				case DClass(c):
					if (!shapes.exists(c.name)) {
						var held:Int = module.reserveType();
						shapes.set(c.name, held);
						owners.set(held, c.name);
					}
				case _:
			}
		}

		/**
		 * Which class extends which, before anything else, because everything after this walks that
		 * chain and a subclass may be written above its base.
		 */
		for (decl in decls) {
			switch (decl.d) {
				case DClass(c):
					var base:Null<String> = baseName(c.extend);

					if (base == null)
						continue;

					if (classes.exists(base))
						bases.set(c.name, base);
					else
						opened.set(c.name, true);
				case _:
			}
		}

		/**
		 * Then the bases the world already has, base first, because a method overriding one of the
		 * world's has to be shaped the way the world shaped it and the answer is up the chain.
		 */
		for (c in ordered(decls)) {
			if (bases.exists(c.name) || c.extend == null)
				continue;

			hosts.set(c.name, hostShape(baseName(c.extend), decl(decls, c)));
		}

		for (decl in decls) {
			switch (decl.d) {
				case DClass(c):
					shape(c);
				case _:
			}
		}

		/**
		 * Laid out base first, whatever order they were written in. Where a class's own first field
		 * sits is decided by how many its base has, so a base laid out afterwards is a base that was
		 * counted as empty.
		 */
		for (c in ordered(decls))
			layout(c, decl(decls, c));
	}

	/**
	 * @param decls The batch's declarations.
	 * @return Its classes, each after whatever of the batch it extends.
	 */
	function ordered(decls:Array<ModuleDecl>):Array<ClassDecl> {
		var pending:Array<ClassDecl> = [];

		for (decl in decls) {
			switch (decl.d) {
				case DClass(c):
					pending.push(c);
				case _:
			}
		}

		var done:StringMap<Bool> = new StringMap();
		var out:Array<ClassDecl> = [];

		while (pending.length > 0) {
			var moved:Bool = false;
			var left:Array<ClassDecl> = [];

			for (c in pending) {
				var base:Null<String> = bases.get(c.name);

				if (base == null || done.exists(base)) {
					done.set(c.name, true);
					out.push(c);
					moved = true;
				} else {
					left.push(c);
				}
			}

			pending = left;

			/** A cycle is not layable out; the world refuses it too, and this stops rather than spins. */
			if (!moved) {
				for (c in pending)
					out.push(c);
				break;
			}
		}

		return out;
	}

	/** @return Where a class was written, for a refusal that has to say so. */
	function decl(decls:Array<ModuleDecl>, c:ClassDecl):Position {
		for (entry in decls) {
			switch (entry.d) {
				case DClass(other) if (other == c):
					return entry.pos;
				case _:
			}
		}

		return null;
	}

	/**
	 * Declares everything a class offers: what its names mean, and the shape of every body in it.
	 *
	 * **A class of the batch is a type this module holds**, and `layout` is what lays it out. What is
	 * settled here is the part a body has to know before it can be written: which names are its
	 * fields, which are its statics, which are properties, and what each of its methods looks like.
	 *
	 * A method takes its own class as its first argument rather than a dynamic, which is what lets a
	 * field of it be an offset and a call to it go through the method table.
	 *
	 * A function that declares no return type still returns something, unless it is a constructor.
	 * Reading it as `Void` would compile away the value it hands back.
	 *
	 * @param c The class.
	 */
	function shape(c:ClassDecl):Void {
		var accessors:StringMap<{get:String, set:String}> = new StringMap();
		var statics:StringMap<Bool> = new StringMap();
		var own:StringMap<Bool> = new StringMap();
		var types:StringMap<Int> = new StringMap();
		var closed:StringMap<Bool> = new StringMap();
		var reached:StringMap<Int> = new StringMap();

		for (f in c.fields) {
			switch (f.kind) {
				case KVar(v):
					reached.set(f.name, reaching(f, v));

					if (!isStatic(f) && v.get == 'null')
						closed.set(f.name, true);

					if (isStatic(f))
						statics.set(f.name, true);
					else if (!property(v))
						own.set(f.name, true);

					if (property(v))
						accessors.set(f.name, {get: v.get, set: v.set});

					if (v.type != null)
						types.set(f.name, typeOf(v.type));

				case KFunction(_):
					if (isStatic(f))
						statics.set(f.name, true);
			}
		}

		members.set(c.name, own);
		props.set(c.name, accessors);
		unreadable.set(c.name, closed);
		reach.set(c.name, reached);
		owned.set(c.name, statics);
		memberTypes.set(c.name, types);

		for (f in c.fields) {
			var fn:Null<FunctionDecl> = switch (f.kind) {
				case KFunction(d): d;
				case _: null;
			}
			if (fn == null)
				continue;

			/**
			 * A method the world already declares is shaped the way the world shaped it, whatever
			 * the script wrote, because taking that class's place in the method table means the
			 * world's own callers reach it directly and they pass what they always passed.
			 */
			if (!isStatic(f) && f.name != 'new') {
				var above:Null<Signature> = overriding(c, f, fn);

				if (above != null) {
					signatures.set(c.name + '#' + f.name, above);
					continue;
				}
			}

			var args:Array<Int> = [];

			if (!isStatic(f))
				args.push(shapes.get(c.name));

			/**
			 * An argument that may be left out is typed dynamic whatever it was declared as, because
			 * what a caller leaving it out passes is null and a typed register has nowhere to put
			 * one. The body reads it as the interpreter does, which is null until its default runs.
			 */
			var gathers:Bool = false;

			for (a in fn.args) {
				/**
				 * A rest argument is one dynamic register holding an array, whatever the elements
				 * were declared as. The body already treats it that way, since a script iterates it;
				 * what needed saying is that its callers pass more values than there are registers.
				 */
				if (a.rest == true) {
					gathers = true;
					args.push(tDyn);
					continue;
				}

				args.push(optional(a) ? tDyn : typeOf(a.t));
			}

			var ret:Int = fn.ret != null ? typeOf(fn.ret) : (f.name == 'new' ? tVoid : tDyn);

			var sig:Signature = {
				findex: module.reserve(),
				args: args,
				ret: ret,
				type: module.typeId(TFun(args, ret)),
				rest: gathers
			};

			signatures.set(c.name + (isStatic(f) ? '.' : '#') + f.name, sig);
		}

	}

	/**
	 * Lays a class out: what it extends, where each of its fields sits, and where each of its methods
	 * sits in the table a virtual call goes through.
	 *
	 * A base of the batch is another entry here and needs nothing but its own numbers. A base the
	 * world already has is a bare entry the loader points at the real class, and how many fields and
	 * methods that class has is asked of the world, because nothing in a script says.
	 *
	 * @param c The class.
	 * @param pos Where it was written.
	 * @throws Unsupported If it extends something the world cannot be asked about.
	 */
	function layout(c:ClassDecl, pos:Position):Void {
		var base:Null<String> = baseName(c.extend);
		var inBatch:Null<String> = bases.get(c.name);
		var host:Null<hl.Type> = null;

		var inherited:Int = 0;
		var table:Int = 0;
		var baseType:Int = -1;

		if (inBatch != null) {
			inherited = widths.get(inBatch);
			table = tables.get(inBatch);
			baseType = shapes.get(inBatch);
		} else if (base != null) {
			host = hostShape(base, pos);
			hosts.set(c.name, host);

			baseType = module.reserveType();
			module.defineType(baseType, TObj(module.stringId(base), [], [], -1, 0));
			links.push({at: baseType, host: base});

			inherited = Loader.fieldCount(host);
			table = Loader.protoCount(host);

			if (inherited < 0 || table < 0)
				throw new Unsupported('extends ' + base + ', which the world could not be asked about', pos);
		}

		var fields:Array<Field> = [];
		var index:StringMap<Int> = new StringMap();
		var kinds:StringMap<Int> = new StringMap();
		var at:Int = inherited;

		for (f in c.fields) {
			if (isStatic(f) || f.name == 'new')
				continue;

			switch (f.kind) {
				case KVar(v):
					/**
					 * A name the base already has is the same field, not a second one. The
					 * interpreter writes the base's when it sees this, and two fields of one name
					 * would be two answers to every read of it.
					 */
					if (host != null && Loader.declares(host, f.name))
						continue;

					/**
					 * A declaration whose every side is an accessor has no storage of its own, so
					 * nothing here holds one either. Laying a field out for it would make reflection
					 * answer with the storage that is not supposed to exist, where the interpreter
					 * answers with nothing.
					 */
					if (reaching(f, v) & KEEPS == 0)
						continue;

					fields.push({name: module.stringId(f.name), type: typeOf(v.type)});
					index.set(f.name, at);
					kinds.set(f.name, typeOf(v.type));
					at++;

				case KFunction(_):
			}
		}

		var protos:Array<Proto> = [];
		var entry:StringMap<Int> = new StringMap();
		var methods:Map<String, Int> = new Map();

		for (f in c.fields) {
			if (isStatic(f) || f.name == 'new')
				continue;

			switch (f.kind) {
				case KFunction(_):
					var sig:Null<Signature> = signatures.get(c.name + '#' + f.name);
					if (sig == null)
						continue;

					var seat:Int = inheritedEntry(inBatch, host, f.name);
					if (seat < 0)
						seat = table++;

					protos.push({name: module.stringId(f.name), findex: sig.findex, pindex: seat});
					entry.set(f.name, seat);
					methods.set(f.name, sig.findex);

				case KVar(_):
			}
		}

		/**
		 * A class that says how it renders carries the method HashLink asks for beside it. `Std.string`
		 * looks for `__string` and falls back to the class's name when there is none, so a scripted
		 * `toString` was written and never reached.
		 */
		if (signatures.exists(c.name + '#toString')) {
			var args:Array<Int> = [shapes.get(c.name)];
			var sig:Signature = {
				findex: module.reserve(),
				args: args,
				ret: module.prim(HBytes),
				type: module.typeId(TFun(args, module.prim(HBytes))),
				rest: false
			};

			signatures.set(c.name + '#__string', sig);

			var seat:Int = inheritedEntry(inBatch, host, '__string');
			if (seat < 0)
				seat = table++;

			protos.push({name: module.stringId('__string'), findex: sig.findex, pindex: seat});
			entry.set('__string', seat);
		}

		widths.set(c.name, at);
		tables.set(c.name, table);
		slots.set(c.name, index);
		slotTypes.set(c.name, kinds);
		entries.set(c.name, entry);

		inherit(c, inBatch, host);

		var kept:Array<String> = holder(c);
		var global:Int = module.global(holders.get(c.name));
		values.set(c.name, global);

		module.defineType(shapes.get(c.name), TObj(module.stringId(pathOf(c.name)), fields, protos, baseType, global + 1));

		emitted.push({
			name: c.name,
			path: pathOf(c.name),
			type: shapes.get(c.name),
			holder: holders.get(c.name),
			global: global,
			construct: builderOf(c),
			host: inBatch == null ? base : null,
			base: inBatch,
			methods: methods,
			stored: kept
		});
	}

	/**
	 * Lays out the type a class's own value is.
	 *
	 * The world lays a class value out this way: a type per class extending `hl.BaseType.Class`,
	 * carrying that class's statics as ordinary fields. Following it means a static is an offset off
	 * a global rather than a name looked up in the class the interpreter holds, and it means the
	 * value is one `Type.initClass` can make, so everything the world does with a class still works.
	 *
	 * A static with no starting value is held as a dynamic whatever it was declared, because what the
	 * world puts there before anything runs is null and a typed field has nowhere to put one.
	 *
	 * @param c The class.
	 * @return The names it lays out, in the order they were written.
	 */
	function holder(c:ClassDecl):Array<String> {
		var base:hl.Type = hl.Type.get((null : hl.BaseType.Class));
		var above:Int = module.reserveType();

		module.defineType(above, TObj(module.stringId('hl.Class'), [], [], -1, 0));
		links.push({at: above, type: base});

		var fields:Array<Field> = [];
		var index:StringMap<Int> = new StringMap();
		var kinds:StringMap<Int> = new StringMap();
		var kept:Array<String> = [];
		var at:Int = Loader.fieldCount(base);

		for (f in c.fields) {
			if (!isStatic(f))
				continue;

			/** A name the class value already carries is the world's, and a script may not take it. */
			if (Loader.declares(base, f.name))
				continue;

			var held:Int = switch (f.kind) {
				case KVar(v) if (reaching(f, v) & KEEPS == 0): continue;
				case KVar(v): v.expr == null ? tDyn : typeOf(v.type);
				case KFunction(_): tDyn;
			};

			fields.push({name: module.stringId(f.name), type: held});
			index.set(f.name, at);
			kinds.set(f.name, held);
			kept.push(f.name);
			at++;
		}

		var made:Int = module.reserveType();
		module.defineType(made, TObj(module.stringId('$' + pathOf(c.name)), fields, [], above, 0));

		holders.set(c.name, made);
		staticSlots.set(c.name, index);
		staticTypes.set(c.name, kinds);

		return kept;
	}

	/**
	 * The shape a method has to be written in because the world already declared it.
	 *
	 * **This is not an optimisation, it is what stops a crash.** An override takes the position the
	 * base keeps that method in, so the world's own callers reach it through their own signature: a
	 * script writing `function step(dt)` against a base declaring `step(Float):Float` produced a
	 * function taking a pointer, and the first caller passed a double into it.
	 *
	 * @param c The class.
	 * @param f The field.
	 * @param fn Its declaration.
	 * @return The shape to write it in, or null when nothing above declares it.
	 * @throws Unsupported If the world's shape cannot be expressed here, or the script wrote more
	 *         arguments than it has room for.
	 */
	function overriding(c:ClassDecl, f:FieldDecl, fn:FunctionDecl):Null<Signature> {
		var above:Null<hl.Type> = rootHost(c.name);
		if (above == null)
			return null;

		var shape:Null<Array<Int>> = Loader.protoShape(above, f.name);
		if (shape == null)
			return null;

		var args:Array<Int> = [shapes.get(c.name)];

		for (i in 1...shape[0]) {
			var held:Int = fromKind(shape[i + 2]);

			if (held < 0)
				throw new Unsupported('overrides ' + f.name + ', whose arguments this cannot express', null);

			args.push(held);
		}

		if (fn.args.length > args.length - 1)
			throw new Unsupported('overrides ' + f.name + ' with more arguments than it takes', null);

		var ret:Int = fromKind(shape[1]);
		if (ret < 0)
			throw new Unsupported('overrides ' + f.name + ', whose result this cannot express', null);

		return {
			findex: module.reserve(),
			args: args,
			ret: ret,
			type: module.typeId(TFun(args, ret)),
			rest: false,
			hosted: true
		};
	}

	/**
	 * @param kind One of HashLink's type kinds.
	 * @return The register type that is laid out and passed the same way, or -1 when none is.
	 *
	 * Every pointer kind is a pointer, so a dynamic register holds one and is passed in the same
	 * place. A narrower integer or a single-precision float is neither, and there is nothing here
	 * that would arrive where the world put it.
	 */
	function fromKind(kind:Int):Int {
		return switch (kind) {
			case 0: tVoid;
			case 3: tI32;
			case 6: tF64;
			case 7: tBool;
			case 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19: tDyn;
			case _: -1;
		}
	}

	/**
	 * Gives a class that wrote no constructor one of its own.
	 *
	 * Its fields have starting values and something has to put them there, and a class with a base
	 * inherits that base's constructor, so it takes what the base's takes and hands it straight on.
	 * Taking the arguments one by one rather than collecting them is what lets it be called the same
	 * way any other constructor is, by a script or by the world's own `Type.createInstance`.
	 *
	 * @param c The class.
	 * @param inBatch The base of the batch it extends, or null.
	 * @param host The base the world already has, or null.
	 */
	function inherit(c:ClassDecl, inBatch:Null<String>, host:Null<hl.Type>):Void {
		if (signatures.exists(c.name + '#new'))
			return;

		var takes:Int = 0;

		if (inBatch != null) {
			var above:Null<Signature> = signatures.get(inBatch + '#new');
			takes = above == null ? 0 : above.args.length - 1;
		} else if (host != null) {
			takes = hostArity(c.extend);
		}

		var args:Array<Int> = [shapes.get(c.name)];
		for (i in 0...takes)
			args.push(tDyn);

		signatures.set(c.name + '#new', {
			findex: module.reserve(),
			args: args,
			ret: tVoid,
			type: module.typeId(TFun(args, tVoid)),
			rest: false
		});
	}

	/**
	 * @param base A class the world already has, as the script wrote it.
	 * @return How many arguments its constructor takes, not counting the instance, or 0 when it has
	 *         no constructor at all.
	 */
	function hostArity(base:Null<CType>):Int {
		var named:Null<String> = baseName(base);
		var found:Dynamic = named == null ? null : world(named);

		if (found == null)
			return 0;

		var builds:Dynamic = (cast found : hl.BaseType.Class).__constructor__;
		if (builds == null)
			return 0;

		var taken:Int = hl.Type.getDynamic(builds).getArgsCount() - 1;
		return taken < 0 ? 0 : taken;
	}

	/**
	 * @param name A class the script extends that this batch did not declare.
	 * @param pos Where the extending class was written.
	 * @return The world's type for it.
	 * @throws Unsupported If the world has no such class, or answers with a scripted one this batch
	 *         cannot see, since either way there is nothing to lay the subclass out against.
	 */
	function hostShape(name:String, pos:Position):hl.Type {
		var found:Dynamic = world(name);

		if (found == null)
			throw new Unsupported('extends ' + name + ', which nothing at runtime answers to', pos);

		if (!(found is Class))
			throw new Unsupported('extends ' + name + ', which is not a class this can extend', pos);

		var known:Null<hl.Type> = (cast found : hl.BaseType).__type__;

		if (known == null)
			throw new Unsupported('extends ' + name + ', which is not laid out as a class', pos);

		return known;
	}

	/**
	 * @param inBatch The base of the batch, or null.
	 * @param host The base the world already has, or null.
	 * @param name A method name.
	 * @return Where the base already keeps that method, or -1 when nothing up the chain has it.
	 */
	function inheritedEntry(inBatch:Null<String>, host:Null<hl.Type>, name:String):Int {
		var at:Null<String> = inBatch;

		while (at != null) {
			var known:Null<StringMap<Int>> = entries.get(at);
			if (known != null && known.exists(name))
				return known.get(name);

			at = bases.get(at);
		}

		var above:Null<hl.Type> = host != null ? host : rootHost(inBatch);
		return above == null ? -1 : Loader.protoAt(above, name);
	}

	/** @return The base the world has at the end of a class's chain, or null when the chain ends here. */
	function rootHost(cls:Null<String>):Null<hl.Type> {
		var at:Null<String> = cls;

		while (at != null) {
			if (hosts.exists(at))
				return hosts.get(at);

			at = bases.get(at);
		}

		return null;
	}

	/** @return The index of the function that fills a new instance of a class. */
	function builderOf(c:ClassDecl):Int {
		var sig:Null<Signature> = signatures.get(c.name + '#new');
		return sig == null ? -1 : sig.findex;
	}

	/** @return A class of the batch written the way the world resolves it. */
	function pathOf(cls:String):String {
		return pack.length > 0 ? pack + '.' + cls : cls;
	}

	/**
	 * @param e An expression.
	 * @return The class of the batch it is held as, or null when its register is not one.
	 */
	function heldAs(e:Expr):Null<String> {
		return owners.get(infer(e));
	}

	/**
	 * Refuses a null receiver before an instruction reaches through it.
	 *
	 * Reading a field by offset is a load from the pointer, so a null one is not an error but a page
	 * fault, and `var w:Thing = null` is ordinary code. One instruction turns it back into something
	 * a script can catch.
	 *
	 * @param obj What is being reached through.
	 * @param held The register holding it.
	 */
	function guard(obj:Expr, held:Int):Void {
		if (!obj.e.match(EIdent('this')))
			ops.push({op: ONullCheck, args: [held]});
	}

	/**
	 * Where a field of a class this batch laid out sits, and what it holds.
	 *
	 * Only a field the batch itself declared, and only when the receiver is held as the class that
	 * declares it. Anything else keeps going through the world's own reader, because a field of a
	 * base the world owns is at an offset only the world knows and a receiver held as a dynamic is
	 * one whose class is not settled until it runs.
	 *
	 * @param obj What is being read from.
	 * @param name The field.
	 * @return Its position and register type, or null when this is not that.
	 */
	function laidOut(obj:Expr, name:String, side:Int):Null<{at:Int, of:Int}> {
		var cls:Null<String> = heldAs(obj);
		if (cls == null)
			return null;

		/**
		 * A side with an accessor in front of it keeps going through the world, whatever storage
		 * stands behind it. A starting value is written straight in, which is what a declaration's
		 * `= value` is rather than an assignment.
		 */
		if (!initialising && reachOf(cls, name) & side == 0)
			return null;

		var at:Null<String> = cls;

		while (at != null) {
			var here:Null<StringMap<Int>> = slots.get(at);
			if (here != null && here.exists(name))
				return {at: here.get(name), of: slotTypes.get(at).get(name)};

			at = bases.get(at);
		}

		return null;
	}

	/**
	 * @param obj What is being read from.
	 * @param name The field.
	 * @return What that field holds, or null when this batch did not lay it out.
	 */
	function fieldType(obj:Expr, name:String):Null<Int> {
		var here:Null<{at:Int, of:Int}> = laidOut(obj, name, READS);
		return here == null ? null : here.of;
	}

	/**
	 * What a field of an element of a typed array holds.
	 *
	 * The element itself stays dynamic, so nothing is cast and an array that does not hold what it
	 * said still answers rather than refusing. What this buys is the read: knowing the field is an
	 * `Int` means it comes back as one, and the arithmetic around it is arithmetic rather than a
	 * pair of allocations.
	 *
	 * @param obj What is being read from.
	 * @param name The field.
	 * @return Its register type, or null when nothing here can say.
	 */
	function elementField(obj:Expr, name:String):Null<Int> {
		var held:Null<String> = switch (obj.e) {
			case EArray(arr, _): owners.get(element(arr));
			case _: null;
		};

		if (held == null)
			return null;

		var at:Null<String> = held;

		while (at != null) {
			if (reachOf(at, name) & READS == 0)
				return null;

			var kinds:Null<StringMap<Int>> = slotTypes.get(at);
			if (kinds != null && kinds.exists(name))
				return kinds.get(name);

			at = bases.get(at);
		}

		return null;
	}

	/**
	 * Where a method of a class this batch laid out sits in the table a virtual call goes through.
	 *
	 * @param cls The class it is called on.
	 * @param name The method.
	 * @return Its position, or null when nothing of the batch declares it.
	 */
	function seatOf(cls:String, name:String):Null<Int> {
		var at:Null<String> = cls;

		while (at != null) {
			var here:Null<StringMap<Int>> = entries.get(at);
			if (here != null && here.exists(name))
				return here.get(name);

			at = bases.get(at);
		}

		return null;
	}

	/**
	 * @param cls A class of the batch.
	 * @param name A method.
	 * @return Its shape, taken from whichever class up the chain declares it.
	 */
	function methodOf(cls:String, name:String):Null<Signature> {
		var at:Null<String> = cls;

		while (at != null) {
			var sig:Null<Signature> = signatures.get(at + '#' + name);
			if (sig != null)
				return sig;

			at = bases.get(at);
		}

		return null;
	}

	/**
	 * Writes the bodies of everything `declare` accepted.
	 *
	 * A static has nothing written for it: its storage and its starting value belong to the class
	 * the world already holds.
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
					var wrote:Bool = false;

					for (f in c.fields) {
						switch (f.kind) {
							case KFunction(fn):
								var key:String = c.name + (isStatic(f) ? '.' : '#') + f.name;
								var sig:Null<Signature> = signatures.get(key);
								if (sig == null)
									throw new Unsupported(key + ', whose signature this cannot express', decl.pos);

								writing = f.name;

								if (f.name == 'new') {
									wrote = true;
									emitFunction(sig, fn, decl.pos, c.name, starting(c));
								} else {
									emitFunction(sig, fn, decl.pos, isStatic(f) ? null : c.name);
								}

								writing = null;

							case KVar(_):
						}
					}

					if (!wrote)
						emitInherited(c, decl.pos);

					emitRendering(c, decl.pos);

				case DPackage(_) | DImport(_, _) | DUsing(_) | DEnum(_) | DAbstract(_) | DInterface(_) | DTypedef(_) | DField(_):

				case _:
					throw new Unsupported('a declaration this cannot express', decl.pos);
			}
		}
	}

	/** @return The module, once every body has been written. */
	public function finish():Bytecode {
		return module;
	}

	/**
	 * @param c A class.
	 * @return Its own fields that were written with a starting value, in the order they were written.
	 */
	function starting(c:ClassDecl):Array<{name:String, value:Expr}> {
		var found:Array<{name:String, value:Expr}> = [];

		for (f in c.fields) {
			if (isStatic(f) || f.name == 'new')
				continue;

			switch (f.kind) {
				case KVar(v) if (v.expr != null):
					found.push({name: f.name, value: v.expr});
				case _:
			}
		}

		return found;
	}

	/**
	 * Writes the constructor of a class that did not declare one.
	 *
	 * It puts the class's own fields where their declarations said, then hands everything it was
	 * called with to the base, which is what the interpreter does when it finds no `new`: a class
	 * with a base inherits the base's constructor, and one without has nothing left to do.
	 *
	 * @param c The class.
	 * @param pos Where it was written.
	 */
	function emitInherited(c:ClassDecl, pos:Position):Void {
		var sig:Null<Signature> = signatures.get(c.name + '#new');
		if (sig == null)
			return;

		ops = [];
		regs = [];
		scopes = [];
		annotated = [];
		elements = [];
		breaks = [];
		continues = [];
		returns = sig.ret;
		inside = c.name;
		traps = 0;

		push();

		regs.push(sig.args[0]);
		scopes[scopes.length - 1].set('this', 0);

		for (i in 1...sig.args.length)
			regs.push(sig.args[i]);

		fillFields(starting(c), pos);

		if (c.extend != null) {
			var given:Int = reg(tDyn);
			callSupport('array', [], given);

			for (i in 1...sig.args.length)
				callSupport('push', [given, i], reg(tDyn));

			callSupport('superNew', [dynOf(thisExpr(pos)), named(owningPath()), given], reg(tVoid));
		}

		var empty:Int = reg(tVoid);
		ops.push({op: ORet, args: [empty]});

		pop();

		module.add({type: sig.type, findex: sig.findex, regs: regs, ops: ops});
	}

	/**
	 * Writes the method HashLink asks a class for when something renders one of its instances.
	 *
	 * It calls the class's own `toString` by index rather than through the method table, because a
	 * subclass that overrides `toString` carries its own `__string` at the same position and a
	 * subclass that does not inherits both.
	 *
	 * @param c The class.
	 * @param pos Where it was written.
	 */
	function emitRendering(c:ClassDecl, pos:Position):Void {
		var sig:Null<Signature> = signatures.get(c.name + '#__string');
		var renders:Null<Signature> = signatures.get(c.name + '#toString');

		if (sig == null || renders == null)
			return;

		ops = [];
		regs = [];
		scopes = [];
		annotated = [];
		elements = [];
		breaks = [];
		continues = [];
		returns = sig.ret;
		inside = c.name;
		traps = 0;

		push();

		regs.push(sig.args[0]);
		scopes[scopes.length - 1].set('this', 0);

		var said:Int = reg(renders.ret);
		ops.push({op: OCall1, args: [said, renders.findex, 0]});

		var held:Int = reg(tDyn);
		move(said, held);

		var out:Int = reg(sig.ret);
		callSupport('text', [held], out);
		ops.push({op: ORet, args: [out]});

		pop();

		module.add({type: sig.type, findex: sig.findex, regs: regs, ops: ops});
	}

	/**
	 * Writes a class's own field initialisers.
	 *
	 * Straight into the field even when a setter stands in front of it, because a declaration's
	 * starting value is storage rather than an assignment, which is what Haxe does with the same
	 * line and what the interpreter does when it binds the slot.
	 *
	 * @param inits The fields and what they start as.
	 * @param pos Where the class was written.
	 */
	function fillFields(inits:Array<{name:String, value:Expr}>, pos:Position):Void {
		if (inits.length == 0)
			return;

		initialising = true;

		for (init in inits)
			setField(thisExpr(pos), init.name, Accessors.apply(init.value), pos);

		initialising = false;
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
	 * Only a value with a type of its own is boxed. Boxing one that is already dynamic wraps the
	 * pointer rather than the value, and what comes back then reads as its own address.
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

		if (sig.ret == tVoid) {
			var empty:Int = slots.length;
			slots.push(tDyn);
			body.push({op: ONull, args: [empty]});
			body.push({op: ORet, args: [empty]});
		} else if (primitive(sig.ret)) {
			var boxed:Int = slots.length;
			slots.push(tDyn);
			body.push({op: OToDyn, args: [boxed, result]});
			body.push({op: ORet, args: [boxed]});
		} else {
			body.push({op: ORet, args: [result]});
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
	 * Wraps an instance method in a function that binds it to one instance.
	 *
	 * **What lets an object the interpreter built run a compiled method.** A compiled instance method
	 * takes its receiver as an ordinary first argument, and the interpreter holds each method as a
	 * closure that already knows its instance, so the two do not fit together until something binds
	 * one to the other. That is exactly `OInstanceClosure`, which is what a lambda capturing its
	 * environment already uses.
	 *
	 * Called once per method per instance, which is the same order of work the interpreter does when
	 * it builds that method's closure, so nothing is paid that was not being paid before.
	 *
	 * @param name The method, written `Class#field`.
	 * @param exposed The index of its boxing wrapper, since what the interpreter calls has to answer
	 *        with a value the host can read.
	 * @return The binder's index, or null when there is no such instance method.
	 */
	public function binder(name:String, exposed:Int):Null<Int> {
		var sig:Null<Signature> = signatures.get(name);
		if (sig == null || sig.args.length == 0)
			return null;

		var findex:Int = module.reserve();
		var shape:Int = module.typeId(TFun(sig.args.slice(1), tDyn));

		module.add({
			type: module.typeId(TFun([tDyn], tDyn)),
			findex: findex,
			regs: [tDyn, shape, tDyn],
			ops: [
				{op: OInstanceClosure, args: [1, exposed, 0]},
				{op: OMov, args: [2, 1]},
				{op: ORet, args: [2]}
			]
		});

		return findex;
	}

	/**
	 * Writes one function's registers and body.
	 *
	 * Whether every path returns is not worked out here, so a body that can fall off its end is
	 * given the value Haxe would have given it. Refusing instead would turn a `while (true)` whose
	 * only exit is a `return` into a module nobody compiles.
	 *
	 * @param sig Its shape.
	 * @param fn Its declaration.
	 * @param pos Where it appears.
	 * @param host The class it belongs to, or null when it is a static.
	 * @param inits Fields to put their starting values in first, for a constructor.
	 */
	function emitFunction(sig:Signature, fn:FunctionDecl, pos:Position, ?host:String, ?inits:Array<{name:String, value:Expr}>):Void {
		ops = [];
		regs = [];
		scopes = [];
		annotated = [];
		elements = [];
		breaks = [];
		continues = [];
		returns = sig.ret;
		inside = host;
		traps = 0;

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
			annotate(fn.args[i].name, fn.args[i].t);
		}

		/**
		 * An argument the caller left off arrives as null, and a declared default is what should have
		 * been there instead. Written as the first thing the body does, so everything after it reads
		 * the value the declaration promised, which is where the interpreter puts it too.
		 */
		for (i in 0...fn.args.length) {
			var arg:Argument = fn.args[i];
			if (arg.value == null)
				continue;

			var here:Int = i + first;

			/** Only a register that can hold the null which says an argument was left out. */
			if (regs[here] != tDyn)
				continue;
			var over:Int = jump(OJNotNull, [here]);
			into(arg.value, here);
			land([over]);
		}

		/**
		 * The accessor rewrite runs before the capture pass and not inside the emitter, because an
		 * accessor that names its own property captures it, which leaves no identifier to rewrite.
		 */
		if (inits != null)
			fillFields(inits, pos);

		var boxing = Capture.transform(fn.args, Accessors.apply(fn.expr));
		for (name in boxing.boxedArgs) {
			var cell:Int = lookup(name);
			var raw:Int = reg(regs[cell]);
			move(cell, raw);

			var held:Int = reg(tDyn);
			move(raw, held);

			var box:Int = reg(tDyn);
			callSupport('array', [], box);
			callSupport('push', [box, held], reg(tDyn));

			var slot:Int = reg(tDyn);
			ops.push({op: OMov, args: [slot, box]});
			scopes[scopes.length - 1].set(name, slot);
		}

		statement(boxing.body);

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
	 * Anything that is a value is a statement too: it is run and its answer dropped. Saying that
	 * once rather than listing the forms keeps one refusal message instead of two that mean the same
	 * thing, and means a construct only has to be taught here once.
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
				if (init == null) {
					var empty:Int = reg(tDyn);
					ops.push({op: ONull, args: [empty]});
					scopes[scopes.length - 1].set(n, empty);
					return;
				}

				var announced:Null<Int> = t == null ? null : typeOf(t);
				var slot:Int = reg(announced == null ? infer(init) : announced);
				into(init, slot);
				scopes[scopes.length - 1].set(n, slot);
				annotate(n, t);

			case EBinop('=', target, value):
				switch (target.e) {
					case EIdent(name) if (lookup(name) != null):
						into(value, lookup(name));

					case EIdent(name) if (isStaticOf(owning, name)):
						staticWrite(owning, name, value, e.pos);

					case EIdent(name) if (propertyOf(inside, name) != null):
						setField(thisExpr(e.pos), name, value, e.pos);

					case EIdent(name) if (isMemberOf(name) || reachesHost()):
						setField(thisExpr(e.pos), name, value, e.pos);

					case EField({e: EIdent(cls)}, name, _) if (isStaticOf(cls, name)):
						staticWrite(cls, name, value, e.pos);

					case EField(obj, name, _):
						setField(obj, name, value, e.pos);

					case EArray(obj, at):
						callSupport('setIndex', [dynOf(obj), dynOf(at), dynOf(value)], reg(tDyn));

					case EIdent(name) if (loose):
						callSupport('set', [looseOwner(), named(name), dynOf(value)], reg(tDyn));

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
				loopBody(body);

				land(continues.pop());
				back(head);
				land(out);
				land(breaks.pop());

			case EDoWhile(cond, body):
				var head:Int = mark();

				breaks.push([]);
				continues.push([]);
				loopBody(body);

				land(continues.pop());

				var again:Array<Int> = [];
				condition(cond, true, again);
				landAt(again, head);
				land(breaks.pop());

			case EFor(name, it, body):
				if (rangeOf(it) != null)
					forRange(name, it, body, e.pos);
				else
					forEach(name, it, body, e.pos);

			case ESwitch(subject, cases, fallback):
				emitSwitch(subject, cases, fallback, null, e.pos);

			case EThrow(thrown):
				ops.push({op: OThrow, args: [dynOf(thrown)]});

			case EFunction(args, body, name, _, _) if (name != null):
				var slot:Int = reg(tDyn);
				scopes[scopes.length - 1].set(name, slot);
				emitLambda(args, body, name, slot, e.pos);

			case ETry(body, name, t, handler, extra):
				emitTry(body, name, t, handler, extra, null, e.pos);

			case EForGen(spec, body):
				switch (spec.e) {
					case EBinop('in', {e: EBinop('=>', {e: EIdent(k)}, {e: EIdent(v)})}, source):
						forPairs(k, v, source, body, e.pos);
					case _:
						throw new Unsupported('a for over something that is not a key and a value', e.pos);
				}

			case EReturn(value):
				if (value == null) {
					var slot:Int = reg(tVoid);
					closeTraps();
					ops.push({op: ORet, args: [slot]});
					return;
				}

				var slot:Int = reg(returns);
				into(value, slot);
				closeTraps();
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
				var slot:Null<Int> = stepping(target);

				if (slot != null)
					ops.push({op: op == '++' ? OIncr : ODecr, args: [slot]});
				else
					statement(stepped(op, target, e.pos));

			case EParent(inner):
				statement(inner);

			case _:
				var discard:Int = reg(infer(e));
				into(e, discard);
		}
	}

	/** @return The two ends of a range, or null when an expression is not one. */
	function rangeOf(it:Expr):Null<{low:Expr, high:Expr}> {
		return switch (it.e) {
			case EBinop('...', a, b): {low: a, high: b};
			case EParent(inner): rangeOf(inner);
			case _: null;
		}
	}

	/**
	 * Writes a `for` over an integer range, which is the one that needs no help.
	 *
	 * A counter in a typed register and a comparison that is already a jump, so this is the loop the
	 * measured numbers come from and the reason it is spotted before anything else is tried.
	 */
	function forRange(name:String, it:Expr, body:Expr, pos:Position):Void {
		var ends:{low:Expr, high:Expr} = rangeOf(it);

		push();

		var counter:Int = reg(tI32);
		into(ends.low, counter);

		var limit:Int = reg(tI32);
		into(ends.high, limit);

		scopes[scopes.length - 1].set(name, counter);

		var head:Int = mark();
		var out:Array<Int> = [jump(OJSGte, [counter, limit])];

		breaks.push([]);
		continues.push([]);
		loopBody(body);

		land(continues.pop());
		ops.push({op: OIncr, args: [counter]});
		back(head);
		land(out);
		land(breaks.pop());

		pop();
	}

	/**
	 * Writes a `for` over anything else, through the iterator protocol.
	 *
	 * What counts as iterable is the interpreter's rule rather than one of this emitter's, so a
	 * value a script can loop over interpreted is one it can loop over compiled.
	 */
	function forEach(name:String, it:Expr, body:Expr, pos:Position):Void {
		push();

		var cursor:Int = reg(tDyn);
		callSupport('iterator', [dynOf(it)], cursor);

		var item:Int = reg(tDyn);
		scopes[scopes.length - 1].set(name, item);

		var head:Int = mark();
		var more:Int = reg(tBool);
		callSupport('step', [cursor], more);

		var out:Array<Int> = [jump(OJFalse, [more])];
		callSupport('take', [cursor], item);

		breaks.push([]);
		continues.push([]);
		loopBody(body);

		land(continues.pop());
		back(head);
		land(out);
		land(breaks.pop());

		pop();
	}

	/**
	 * Writes a `for (key => value in ...)`.
	 *
	 * The pair a key-value iterator hands back is an anonymous structure, so its two halves come out
	 * of it by name the way any other field does.
	 */
	function forPairs(key:String, value:String, source:Expr, body:Expr, pos:Position):Void {
		push();

		var cursor:Int = reg(tDyn);
		callSupport('pairs', [dynOf(source)], cursor);

		var k:Int = reg(tDyn);
		var v:Int = reg(tDyn);
		scopes[scopes.length - 1].set(key, k);
		scopes[scopes.length - 1].set(value, v);

		var head:Int = mark();
		var more:Int = reg(tBool);
		callSupport('step', [cursor], more);

		var out:Array<Int> = [jump(OJFalse, [more])];

		var pair:Int = reg(tDyn);
		callSupport('take', [cursor], pair);
		ops.push({op: ODynGet, args: [k, pair, module.stringId('key')]});
		ops.push({op: ODynGet, args: [v, pair, module.stringId('value')]});

		breaks.push([]);
		continues.push([]);
		loopBody(body);

		land(continues.pop());
		back(head);
		land(out);
		land(breaks.pop());

		pop();
	}

	/**
	 * Writes a loop's body, which is where a comprehension differs from a loop.
	 *
	 * Everything else about the two is the same, so this is the only place that has to know which
	 * one is being written.
	 */
	inline function loopBody(e:Expr):Void {
		if (collector == null)
			statement(e);
		else
			collect(e);
	}

	/**
	 * Writes the body of a comprehension, gathering what it produces.
	 *
	 * A comprehension yields the value of whatever its body ends with, so the tail is walked to and
	 * everything before it is an ordinary statement. Loops inside go back through the loop writers,
	 * which come back here for their own bodies, so a nested comprehension needs nothing of its own.
	 *
	 * @param e The body.
	 */
	function collect(e:Expr):Void {
		switch (e.e) {
			case EBlock(items):
				push();
				for (i in 0...items.length) {
					if (i == items.length - 1)
						collect(items[i]);
					else
						statement(items[i]);
				}
				pop();

			case EParent(inner) | EMeta(_, _, inner):
				collect(inner);

			case EIf(cond, yes, no):
				var toElse:Array<Int> = [];
				condition(cond, false, toElse);
				collect(yes);

				if (no == null) {
					land(toElse);
				} else {
					var over:Int = jump(OJAlways);
					land(toElse);
					collect(no);
					land([over]);
				}

			case EFor(_, _, _) | EForGen(_, _) | EWhile(_, _) | EDoWhile(_, _):
				statement(e);

			case EBinop('=>', k, v):
				callSupport('put', [collector.slot, dynOf(k), dynOf(v)], collector.slot);

			case _:
				callSupport('push', [collector.slot, dynOf(e)], reg(tDyn));
		}
	}

	/**
	 * Writes an expression so that its value ends up in a register.
	 *
	 * A value on its way into a dynamic is boxed on the way rather than written raw. Writing an int
	 * into a pointer slot is not a wrong number, it is a pointer, and what reads it next is what
	 * falls over.
	 *
	 * @param e The expression.
	 * @param slot The register to leave it in.
	 * @throws Unsupported If it has no instruction here.
	 */
	function into(e:Expr, slot:Int):Void {
		var want:Int = regs[slot];

		if (want == tDyn) {
			var natural:Int = infer(e);
			if (natural != tDyn) {
				var raw:Int = reg(natural);
				into(e, raw);
				move(raw, slot);
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

			case EIdent('null'):
				var held:Int = landing(slot);
				ops.push({op: ONull, args: [held]});
				if (held != slot)
					move(held, slot);

			case EIdent(name):
				var from:Null<Int> = lookup(name);
				if (from != null) {
					move(from, slot);
					return;
				}

				if (isStaticOf(owning, name)) {
					staticRead(owning, name, slot, e.pos);
					return;
				}

				if (propertyOf(inside, name) != null) {
					getField(thisExpr(e.pos), name, slot, e.pos);
					return;
				}

				if (isMemberOf(name) || reachesHost()) {
					getField(thisExpr(e.pos), name, slot, e.pos);
					return;
				}

				if (constructors.exists(name)) {
					callSupport('get', [ownerOf(constructors.get(name)), named(name)], slot);
					return;
				}

				if (ambientMembers.exists(name)) {
					var host:{owner:String, field:String} = ambientMembers.get(name);
					emitHostRead(host.owner, host.field, slot);
					return;
				}

				if (!loose)
					throw new Unsupported(name + ', which is neither a local nor a field here', e.pos);

				callSupport('get', [looseOwner(), named(name)], slot);

			case EField({e: EIdent('super')}, name, _):
				callSupport('superGet', [dynOf(thisExpr(e.pos)), named(owningPath()), named(name)], slot);

			case EField({e: EIdent(cls)}, name, _) if (isStaticOf(cls, name)):
				staticRead(cls, name, slot, e.pos);

			case EField({e: EIdent(t)}, name, _) if (declared.exists(t)):
				callSupport('get', [ownerOf(t), named(name)], slot);

			case EField(_, _, _) if (hostName(e) != null):
				var host:{owner:String, field:String} = hostName(e);
				emitHostRead(host.owner, host.field, slot);

			case EField(obj, name, true):
				var target:Int = dynOf(obj);
				var held:Int = landing(slot);
				ops.push({op: ONull, args: [held]});

				var over:Int = jump(OJNull, [target]);
				ops.push({op: ODynGet, args: [held, target, module.stringId(name)]});
				land([over]);

				if (held != slot)
					move(held, slot);

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

			case ESwitch(subject, cases, fallback):
				emitSwitch(subject, cases, fallback, slot, e.pos);

			case ETry(body, name, t, handler, extra):
				emitTry(body, name, t, handler, extra, slot, e.pos);

			case EFunction(args, body, name, _, _):
				emitLambda(args, body, name, slot, e.pos);

			case EBinop('is', v, t):
				callSupport('isOfType', [dynOf(v), typeValue(t, e.pos)], slot);

			case EArrayDecl(items):
				emitArrayDecl(items, slot, e.pos);

			case EObject(fields):
				emitObject(fields, slot);

			case EArray(obj, at):
				/**
				 * An index that is already a number goes in as one. Boxing a loop counter to pass it
				 * is an allocation per element, which is what a sweep over an array pays otherwise.
				 */
				if (infer(at) == tI32) {
					var counter:Int = reg(tI32);
					into(at, counter);
					callSupport('indexInt', [dynOf(obj), counter], slot);
					return;
				}

				callSupport('index', [dynOf(obj), dynOf(at)], slot);

			case EBinop('...', low, high):
				callSupport('range', [dynOf(low), dynOf(high)], slot);

			case EConst(CReg(pattern, flags)):
				var p:Int = reg(tDyn);
				ops.push({op: OGetGlobal, args: [p, constSlot('s' + pattern, pattern)]});

				var f:Int = reg(tDyn);
				ops.push({op: OGetGlobal, args: [f, constSlot('s' + flags, flags)]});

				callSupport('regex', [p, f], slot);

			case EBlock(items):
				if (items.length == 0) {
					ops.push({op: ONull, args: [slot]});
				} else {
					push();
					for (i in 0...items.length) {
						if (i == items.length - 1)
							into(items[i], slot);
						else
							statement(items[i]);
					}
					pop();
				}

			case EUnop(op, prefix, target) if (op == '++' || op == '--'):
				var local:Null<Int> = stepping(target);

				if (local == null) {
					if (prefix) {
						statement(stepped(op, target, e.pos));
						into(target, slot);
					} else {
						into(target, slot);
						statement(stepped(op, target, e.pos));
					}
					return;
				}

				var step:Opcode = op == '++' ? OIncr : ODecr;

				if (prefix) {
					ops.push({op: step, args: [local]});
					move(local, slot);
				} else {
					move(local, slot);
					ops.push({op: step, args: [local]});
				}

			/**
			 * An assignment used as a value yields what was assigned, not what reading the target
			 * back would give, since reading a property would run its getter a second time.
			 */
			case EBinop('=', target, value):
				switch (target.e) {
					case EIdent(name) if (lookup(name) != null):
						var local:Int = lookup(name);
						into(value, local);
						move(local, slot);

					case _:
						var held:Int = reg(tDyn);
						into(value, held);

						var temp:String = '`v' + (temps++);
						scopes[scopes.length - 1].set(temp, held);
						statement({e: EBinop('=', target, {e: EIdent(temp), pos: e.pos}), pos: e.pos});
						scopes[scopes.length - 1].remove(temp);

						move(held, slot);
				}

			case EBinop('??', a, b):
				into(a, slot);

				if (regs[slot] != tDyn) {
				} else {
					var over:Int = jump(OJNotNull, [slot]);
					into(b, slot);
					land([over]);
				}

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

			/**
			 * An import or a `using` written inside a body has already done its work by the time
			 * anything runs: the parser recorded it and the module resolved names against it. There
			 * is nothing left to emit, and it still has to leave a value behind because it sits in a
			 * block like anything else.
			 */
			/**
			 * A throw in value position, which is what the accessor rewrite leaves where a property
			 * that can never be read was read. Nothing follows it, and the slot still has to hold
			 * something for whatever was going to consume it.
			 */
			case EThrow(thrown):
				ops.push({op: OThrow, args: [dynOf(thrown)]});
				var empty:Int = landing(slot);
				ops.push({op: ONull, args: [empty]});
				if (empty != slot)
					move(empty, slot);

			case EImport(_, _) | EUsing(_):
				var empty:Int = landing(slot);
				ops.push({op: ONull, args: [empty]});
				if (empty != slot)
					move(empty, slot);

			case _:
				throw new Unsupported('this expression as a value', e.pos);
		}
	}

	/**
	 * Writes an array literal, a map literal, or the comprehension either can be spelled as.
	 *
	 * Which of the three it is comes from the shape: a `=>` among the items makes it a map, and a
	 * single loop makes it a comprehension. A map starts as null rather than as a map, because which
	 * kind of map it wants is decided by its first key and a comprehension has no first key until it
	 * has run once.
	 *
	 * @param items The literal's contents.
	 * @param slot Where to leave it.
	 * @param pos Where it appears.
	 */
	function emitArrayDecl(items:Array<Expr>, slot:Int, pos:Position):Void {
		var held:Int = landing(slot);

		if (items.length == 1 && looping(items[0])) {
			var pairs:Bool = yieldsPairs(items[0]);

			if (pairs)
				ops.push({op: ONull, args: [held]});
			else
				callSupport('array', [], held);

			var outer:Null<{slot:Int, pairs:Bool}> = collector;
			collector = {slot: held, pairs: pairs};
			statement(items[0]);
			collector = outer;

			if (held != slot)
				move(held, slot);
			return;
		}

		var pairs:Bool = items.length > 0 && paired(items[0]);

		if (pairs) {
			ops.push({op: ONull, args: [held]});

			for (item in items) {
				switch (item.e) {
					case EBinop('=>', k, v):
						callSupport('put', [held, dynOf(k), dynOf(v)], held);
					/**
					 * The interpreter raises this when it runs rather than refusing the module, so
					 * compiled code raises it too. Refusing here would cost a whole module its
					 * bytecode over a line that was never going to run.
					 */
					case _:
						callSupport('raise', [named('Invalid map key=>value expression')], reg(tDyn));
				}
			}
		} else {
			callSupport('array', [], held);

			for (item in items)
				callSupport('push', [held, dynOf(item)], reg(tDyn));
		}

		if (held != slot)
			move(held, slot);
	}

	/** Writes an anonymous structure. */
	function emitObject(fields:Array<{name:String, e:Expr}>, slot:Int):Void {
		var held:Int = landing(slot);
		callSupport('object', [], held);

		for (f in fields) {
			var name:Int = reg(tDyn);
			ops.push({op: OGetGlobal, args: [name, constSlot('s' + f.name, f.name)]});
			callSupport('setField', [held, name, dynOf(f.e)], reg(tDyn));
		}

		if (held != slot)
			move(held, slot);
	}

	/** @return Whether an expression is a loop, which is what makes a literal a comprehension. */
	function looping(e:Expr):Bool {
		return switch (e.e) {
			case EFor(_, _, _) | EForGen(_, _) | EWhile(_, _) | EDoWhile(_, _): true;
			case EParent(inner) | EMeta(_, _, inner): looping(inner);
			case _: false;
		}
	}

	/** @return Whether an expression is a `key => value` pair. */
	function paired(e:Expr):Bool {
		return switch (e.e) {
			case EBinop('=>', _, _): true;
			case EParent(inner) | EMeta(_, _, inner): paired(inner);
			case _: false;
		}
	}

	/** @return Whether a comprehension's body ends in a pair, which makes it build a map. */
	function yieldsPairs(e:Expr):Bool {
		return switch (e.e) {
			case EFor(_, _, body) | EForGen(_, body) | EWhile(_, body) | EDoWhile(_, body): yieldsPairs(body);
			case EParent(inner) | EMeta(_, _, inner): yieldsPairs(inner);
			case EBlock(items): items.length > 0 && yieldsPairs(items[items.length - 1]);
			case EIf(_, yes, no): yieldsPairs(yes) || (no != null && yieldsPairs(no));
			case EBinop('=>', _, _): true;
			case _: false;
		}
	}

	/**
	 * Writes a call to a batch function.
	 *
	 * The call is given a register of what it declared and the result converted afterwards. Writing
	 * straight into the destination puts an integer in a pointer slot whenever the two disagree
	 * about the type, and the answer then reads back as an address rather than as a number.
	 */
	function emitCall(callee:Expr, params:Array<Expr>, slot:Int, pos:Position):Void {
		switch (callee.e) {
			case EField({e: EIdent('super')}, name, _):
				callSupport('superCall', [dynOf(thisExpr(pos)), named(owningPath()), named(name), gathered(params)], slot);
				return;

			case EIdent('super'):
				callSupport('superNew', [dynOf(thisExpr(pos)), named(owningPath()), gathered(params)], slot);
				return;

			/**
			 * A method of a class this batch laid out goes through the method table, which is one
			 * indirect call rather than a lookup by name and an argument array to unpack.
			 */
			case EField(obj, name, _):
				var cls:Null<String> = heldAs(obj);
				var seat:Null<Int> = cls == null ? null : seatOf(cls, name);
				var sig:Null<Signature> = cls == null ? null : methodOf(cls, name);

				if (seat != null && sig != null && fits(sig, params, true)) {
					var held:Int = reg(infer(obj));
					into(obj, held);
					guard(obj, held);
					emitDeclared(sig, held, params, slot, pos, seat);
					return;
				}

			case _:
		}

		var own:Null<String> = selfCall(callee);
		if (own != null) {
			var here:Null<Int> = inside == null ? null : seatOf(inside, own);
			var mine:Null<Signature> = inside == null ? null : methodOf(inside, own);

			if (here != null && mine != null && fits(mine, params, true)) {
				emitDeclared(mine, -1, params, slot, pos, here);
				return;
			}

			callSupport('dispatch', [dynOf(thisExpr(pos)), named(own), gathered(params), siteSlot()], slot);
			return;
		}

		var maker:Null<{owner:String, name:String}> = constructorOf(callee);
		if (maker != null) {
			var given:Int = reg(tDyn);
			callSupport('array', [], given);

			for (p in params)
				callSupport('push', [given, dynOf(p)], reg(tDyn));

			callSupport('enumOf', [ownerOf(maker.owner), named(maker.name), given], slot);
			return;
		}

		var sig:Null<Signature> = calledSignature(callee);
		if (sig == null) {
			var host:Null<{owner:String, field:String}> = hostName(callee);
			if (host != null) {
				emitHostCall(host.owner, host.field, params, slot, pos);
				return;
			}

			var bare:Null<{owner:String, field:String}> = ambientCallee(callee);
			if (bare != null) {
				emitHostCall(bare.owner, bare.field, params, slot, pos);
				return;
			}

			emitDynCall(callee, params, slot, pos);
			return;
		}

		emitDeclared(sig, -1, params, slot, pos);
	}

	/**
	 * Writes a call to a function this batch declared, by index.
	 *
	 * @param sig What it looks like.
	 * @param receiver A register holding the instance, or -1 when it takes none.
	 * @param params The arguments as written, not counting the receiver.
	 * @param slot Where to leave the result.
	 * @param pos Where the call was written.
	 * @throws Unsupported If it was given more arguments than it declares.
	 */
	function emitDeclared(sig:Signature, receiver:Int, params:Array<Expr>, slot:Int, pos:Position, seat:Int = -1):Void {
		var first:Int = receiver >= 0 ? 1 : 0;
		var taken:Int = sig.args.length - first;

		/**
		 * Everything past the last declared argument is gathered into it, when that argument is the
		 * one that collects. `total(1, 2, 3)` against `total(...rest:Int)` is one call with one
		 * argument holding three values, and without this it read as three arguments to a function
		 * that takes one and refused the module.
		 */
		var gathered:Int = sig.rest ? gatherArgs(params, taken - 1) : -1;

		if (gathered < 0 && params.length > taken)
			throw new Unsupported('a call given ' + params.length + ' of its ' + taken + ' arguments', pos);

		var landed:Int = regs[slot] == sig.ret ? slot : reg(sig.ret);
		var given:Array<Int> = [];

		var fixed:Int = gathered >= 0 ? taken - 1 : params.length;

		for (i in 0...fixed) {
			var holder:Int = reg(sig.args[i + first]);
			into(params[i], holder);
			given.push(holder);
		}

		if (gathered >= 0) {
			given.push(gathered);
		} else {
			/**
			 * A null for each argument the call left off, which is what an omitted optional is. Its
			 * register is dynamic because `shape` made it one for exactly this, so there is somewhere
			 * for the null to go, and the body turns it into the declared default if it has one.
			 */
			for (i in params.length...taken) {
				var empty:Int = reg(sig.args[i + first]);
				ops.push({op: ONull, args: [empty]});
				given.push(empty);
			}
		}

		/**
		 * Through the method table when the class has one for it, which is what makes an override
		 * reached through a base-typed reference run the override. By index otherwise, which is
		 * every static and every constructor, none of which is virtual.
		 */
		var args:Array<Int> = [landed, seat >= 0 ? seat : sig.findex];

		if (receiver >= 0)
			args.push(receiver);

		for (g in given)
			args.push(g);

		ops.push({op: seat < 0 ? callFor(sig.args.length) : (receiver >= 0 ? OCallMethod : OCallThis), args: args});

		if (landed != slot)
			move(landed, slot);
	}

	/**
	 * Whether a bare upper-case name in a pattern can only be a constructor of the subject.
	 *
	 * Everything the emitter could resolve it as is asked first, so a name that is a batch enum's
	 * constructor, a class, a declared type or a host static keeps meaning what it meant. What is
	 * left is a name nothing here answers to, which in a pattern is exactly Haxe's case: the subject's
	 * own type is what a pattern is read against.
	 *
	 * @param name The name as written.
	 * @return Whether to read it off the subject.
	 */
	function subjectCtor(name:String):Bool {
		return isTypeName(name)
			&& lookup(name) == null
			&& !constructors.exists(name)
			&& !classes.exists(name)
			&& !declared.exists(name)
			&& !ambientMembers.exists(name);
	}

	/**
	 * Builds the array a rest argument receives.
	 *
	 * @param params Every argument the call was written with.
	 * @param from The index the collecting argument starts at.
	 * @return A dynamic register holding the array, or -1 when there is no room for one.
	 */
	function gatherArgs(params:Array<Expr>, from:Int):Int {
		if (from < 0)
			return -1;

		var made:Int = reg(tDyn);
		callSupport('array', [], made);

		for (i in from...params.length)
			callSupport('push', [made, dynOf(params[i])], reg(tDyn));

		return made;
	}

	/** How many field-access sites have been given a memory, so each one's key is its own. */
	var sites:Int = 0;

	/** Names an evaluated register can be given, so a written form can refer to one. */
	var temps:Int = 0;

	/** This module's index for the runtime's reader, declared the first time a field is read. */
	var fetchNative:Int = -1;

	/** This module's index for the runtime's writer. */
	var storeNative:Int = -1;

	/** This module's indices for the writers that take a number rather than a box around one. */
	var storeIntNative:Int = -1;

	var storeFloatNative:Int = -1;

	/** This module's indices for the callers, by how many arguments they take then by what they answer. */
	var invokeNatives:Array<Map<Int, Int>> = [new Map(), new Map(), new Map(), new Map()];

	/** This module's indices for the readers that answer a primitive rather than a boxed value. */
	var fetchIntNative:Int = -1;

	var fetchFloatNative:Int = -1;

	/**
	 * A register holding this access site's own cache cell.
	 *
	 * One per site rather than one per field name: two sites reading the same name usually see
	 * different receivers, and sharing a cell between them would make each one evict the other's
	 * answer on every pass.
	 *
	 * @return A dynamic register holding the cell.
	 */
	function siteSlot():Int {
		var index:Int = bind('c' + (sites++), {index: 0, kind: BSite});
		var held:Int = reg(tDyn);
		ops.push({op: OGetGlobal, args: [held, index]});
		return held;
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
	function supportSlot(field:String, type:Int):Int {
		return bind('s' + field, {index: 0, kind: BSupport, field: field}, type);
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
	function bind(key:String, binding:Binding, ?type:Int):Int {
		var known:Null<Int> = hostSlots.get(key);
		if (known != null)
			return known;

		binding.index = module.global(type == null ? tDyn : type);
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
		switch (callee.e) {
			case EParent(inner):
				emitDynCall(inner, params, slot, pos);

			case EField(obj, name, maybe):
				var target:Int = dynOf(obj);

				if (maybe == true) {
					var held:Int = landing(slot);
					ops.push({op: ONull, args: [held]});

					var over:Int = jump(OJNull, [target]);
					sendTo(target, name, params, held);
					land([over]);

					if (held != slot)
						move(held, slot);
					return;
				}

				sendTo(target, name, params, slot);

			case _:
				through(dynOf(callee), params, slot);
		}
	}

	/**
	 * Writes a call of a named method on a value.
	 *
	 * Asked of the value itself rather than of the instruction that reads a field, because a class a
	 * script declared keeps its members somewhere the VM cannot see, and a static extension is not
	 * on the value at all.
	 *
	 * @param target A register holding the receiver.
	 * @param name The method's name.
	 * @param params Its arguments.
	 * @param slot Where to leave the result.
	 */
	function sendTo(target:Int, name:String, params:Array<Expr>, slot:Int):Void {
		/**
		 * With nothing brought in by `using`, the only question is what the receiver's own member is,
		 * and that is the question a site can remember the answer to. `send` is what handles the
		 * other case, where a name may belong to the value or to a static that takes it first, and
		 * which of those it is cannot be settled before the value exists.
		 *
		 * Few enough arguments and the runtime takes them where they are, so nothing is gathered into
		 * an array that it would immediately take apart again.
		 */
		if (usings.length == 0 && params.length < invokeNatives.length) {
			var held:Array<Int> = [for (p in params) dynOf(p)];

			/**
			 * A caller that already wants a number is answered with one. The general reader answers
			 * a dynamic, so a method returning an `Int` had its answer allocated and opened again by
			 * the instruction after it, which is the same allocation a field read was paying.
			 */
			var wanted:Int = (regs[slot] == tI32 || regs[slot] == tF64) ? regs[slot] : tDyn;
			var landed:Int = wanted == tDyn ? reg(tDyn) : slot;

			var call:Array<Int> = [
				landed,
				invokeIndex(params.length, wanted),
				target,
				named(name),
				siteSlot(),
				siteIndex(name)
			];

			for (h in held)
				call.push(h);

			ops.push({op: OCallN, args: call});

			if (landed != slot)
				unbox(landed, slot);

			return;
		}

		var given:Int = gathered(params);

		if (usings.length == 0) {
			callSupport('dispatch', [target, named(name), given, siteSlot()], slot);
			return;
		}

		var extensions:Int = reg(tDyn);
		{
			callSupport('array', [], extensions);
			for (u in usings) {
				var holder:Int = reg(tDyn);
				ops.push({op: OGetGlobal, args: [holder, hostSlot(u, '')]});
				callSupport('push', [extensions, holder], reg(tDyn));
			}
		}

		callSupport('send', [target, named(name), given, extensions], slot);
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
	 * Nothing here can know whether what was named really exists, and a global or a field left null
	 * is what says it does not. Calling that would be an access violation with no message, so it is
	 * checked first and raises the null the way reaching for a missing name anywhere else does.
	 *
	 * @param fn A dynamic register holding what to call.
	 * @param params The arguments.
	 * @param slot Where to leave the result.
	 */
	function through(fn:Int, params:Array<Expr>, slot:Int):Void {
		ops.push({op: ONullCheck, args: [fn]});

		/**
		 * Through `Runtime.call` rather than straight at the closure. A dynamic call is checked
		 * against what the callee really declares, and a host function with an optional argument left
		 * off is refused rather than defaulted, which is ordinary Haxe that a script may write about
		 * any function the host offers.
		 */
		callSupport('call', [fn, gathered(params)], slot);
	}

	/**
	 * Writes an instantiation, which is the world's to perform.
	 *
	 * **Every `new` goes through the world**, whether the class is one of the batch or one the host
	 * offers, because the object a script gets has to be the same object the interpreter would have
	 * given it. That is what carries the scripted class, the field slots, the accessors and the
	 * `super` mirror, none of which this module could have built. Field initialisers and the
	 * constructor run inside that, where the interpreter already runs them.
	 *
	 * @param cls The class being built.
	 * @param params Its constructor's arguments.
	 * @param slot Where to leave the instance.
	 * @param pos Where it appears.
	 */
	function emitNew(cls:String, params:Array<Expr>, slot:Int, pos:Position):Void {
		/**
		 * `Map` before anything else, because it is not a class to resolve. It is Haxe's one
		 * `@:multiType` and the name answers to nothing at runtime, so binding it as a host type left
		 * a null to construct from. The interpreter has the same special case for the same reason.
		 */
		if ((cls == 'Map' || cls == 'haxe.ds.Map') && !classes.exists(cls)) {
			callSupport('anyMap', [], slot);
			return;
		}

		/**
		 * A class of the batch is allocated here rather than asked of the world, because this module
		 * holds its layout. Every one of them has a constructor, synthesised when the script wrote
		 * none, so the field initialisers run either way.
		 */
		if (shapes.exists(cls)) {
			var sig:Null<Signature> = signatures.get(cls + '#new');

			if (sig != null && fits(sig, params, true)) {
				var made:Int = reg(shapes.get(cls));
				ops.push({op: ONew, args: [made]});
				emitDeclared(sig, made, params, reg(tVoid), pos);
				move(made, slot);
				return;
			}
		}

		var given:Int = reg(tDyn);
		callSupport('array', [], given);
		for (p in params)
			callSupport('push', [given, dynOf(p)], reg(tDyn));

		/**
		 * `typeNamed` rather than a refusal for anything not of the batch. A class of the batch is
		 * resolved as the world's, and everything else is looked up by name the same way a type used
		 * as a value is, so a script may build what the host offers as well as what it declared. A
		 * name nothing answers to leaves a null to fail on rather than failing to compile, which is
		 * what the interpreter does with the same line.
		 */
		callSupport('make', [typeNamed(cls), given], slot);
	}

	/**
	 * Writes a field read.
	 *
	 * **By name, through the world's own reader, never by offset and never by `ODynGet`.** A scripted
	 * instance keeps its fields where the interpreter put them and answers for them through custom
	 * reflection, so the opcode would look straight past a field that is plainly there. `Runtime.get`
	 * is the reader the interpreter itself uses, so the two agree about properties and accessors
	 * without either having to know about the other.
	 */
	function fetchIndex():Int {
		if (fetchNative < 0)
			fetchNative = module.native('hxs', 'fetch', module.typeId(TFun([tDyn, tDyn, tDyn, tI32], tDyn)));

		return fetchNative;
	}

	function fetchIntIndex():Int {
		if (fetchIntNative < 0)
			fetchIntNative = module.native('hxs', 'fetchi', module.typeId(TFun([tDyn, tDyn, tDyn, tI32], tI32)));

		return fetchIntNative;
	}

	function fetchFloatIndex():Int {
		if (fetchFloatNative < 0)
			fetchFloatNative = module.native('hxs', 'fetchd', module.typeId(TFun([tDyn, tDyn, tDyn, tI32], tF64)));

		return fetchFloatNative;
	}

	/**
	 * @param count How many arguments the call passes.
	 * @return This module's index for the caller that takes that many.
	 */
	function invokeIndex(count:Int, wanted:Int):Int {
		var named:String = wanted == tI32 ? 'invokei' : (wanted == tF64 ? 'invoked' : 'invoke');
		var held:Map<Int, Int> = invokeNatives[count];

		if (!held.exists(wanted)) {
			var args:Array<Int> = [tDyn, tDyn, tDyn, tI32];
			for (i in 0...count)
				args.push(tDyn);

			held.set(wanted, module.native('hxs', named + count, module.typeId(TFun(args, wanted))));
		}

		return held.get(wanted);
	}

	function storeIntIndex():Int {
		if (storeIntNative < 0)
			storeIntNative = module.native('hxs', 'storei', module.typeId(TFun([tDyn, tDyn, tI32, tDyn, tI32], tVoid)));

		return storeIntNative;
	}

	function storeFloatIndex():Int {
		if (storeFloatNative < 0)
			storeFloatNative = module.native('hxs', 'stored', module.typeId(TFun([tDyn, tDyn, tF64, tDyn, tI32], tVoid)));

		return storeFloatNative;
	}

	function storeIndex():Int {
		if (storeNative < 0)
			storeNative = module.native('hxs', 'store', module.typeId(TFun([tDyn, tDyn, tDyn, tDyn, tI32], tVoid)));

		return storeNative;
	}

	/** @return A register holding this access's cache index, which the runtime resolves against. */
	function siteIndex(name:String):Int {
		var held:Int = reg(tI32);
		ops.push({op: OInt, args: [held, module.intId(Loader.site(Loader.hash(name)))]});
		return held;
	}

	function getField(obj:Expr, name:String, slot:Int, pos:Position):Void {
		var cls:Null<String> = ownerNamed(obj) ?? heldAs(obj);

		/**
		 * A member written `var x(null, ...)` is unreadable, and the interpreter says so by looking
		 * for an accessor named `null` and not finding one. Compiled code raises the same thing
		 * rather than reading the storage, which is what cppia does with the same declaration.
		 */
		if (restricted(cls, name)) {
			callSupport('raise', [named('This expression cannot be accessed for reading')], landing(slot));
			return;
		}

		var reader:Null<{get:String, set:String}> = writing == 'get_' + name ? null : propertyOf(cls, name);

		if (reader != null) {
			if (reader.get != 'get')
				throw new Unsupported('reading ' + name + ', which is declared ' + reader.get, pos);

			emitCall({e: EField(obj, 'get_' + name, false), pos: pos}, [], slot, pos);
			return;
		}

		/**
		 * A field of a class this batch laid out is one instruction, because where it sits was
		 * decided when the class was written rather than being asked for at every read.
		 */
		var here:Null<{at:Int, of:Int}> = laidOut(obj, name, READS);

		if (here != null) {
			var held:Int = reg(infer(obj));
			into(obj, held);
			guard(obj, held);

			var got:Int = regs[slot] == here.of ? slot : reg(here.of);
			ops.push({op: OField, args: [got, held, here.at]});

			if (got != slot)
				move(got, slot);

			return;
		}

		var target:Int = dynOf(obj);
		var named:Int = named(name);
		var cell:Int = siteSlot();
		var site:Int = siteIndex(name);

		/**
		 * A reader that answers what the destination already is, when it is a number. `fetch` answers
		 * Dynamic, so an Int field would be boxed here and opened again by the next instruction, which
		 * measured as most of what the call cost.
		 */
		if (regs[slot] == tI32) {
			ops.push({op: OCall4, args: [slot, fetchIntIndex(), target, named, cell, site]});
			return;
		}

		if (regs[slot] == tF64) {
			ops.push({op: OCall4, args: [slot, fetchFloatIndex(), target, named, cell, site]});
			return;
		}

		var returned:Int = reg(tDyn);
		ops.push({op: OCall4, args: [returned, fetchIndex(), target, named, cell, site]});
		unbox(returned, slot);
	}

	/** Writes a field write, by name and through the world, for the reasons `getField` gives. */
	function setField(obj:Expr, name:String, value:Expr, pos:Position):Void {
		var cls:Null<String> = ownerNamed(obj) ?? heldAs(obj);
		var writer:Null<{get:String, set:String}> = (initialising || writing == 'set_' + name) ? null : propertyOf(cls, name);

		if (writer != null) {
			if (writer.set != 'set')
				throw new Unsupported('writing ' + name + ', which is declared ' + writer.set, pos);

			var discard:Int = reg(tDyn);
			emitCall({e: EField(obj, 'set_' + name, false), pos: pos}, [value], discard, pos);
			return;
		}

		/** The same instruction the read is, for the same reason. */
		var here:Null<{at:Int, of:Int}> = laidOut(obj, name, WRITES);

		if (here != null) {
			var into:Int = reg(infer(obj));
			this.into(obj, into);
			guard(obj, into);

			var written:Int = reg(here.of);
			this.into(value, written);

			ops.push({op: OSetField, args: [into, here.at, written]});
			return;
		}

		var target:Int = dynOf(obj);
		var held:Int = named(name);

		/**
		 * A number goes in as a number. Boxing one to write it allocates, and the measurement put
		 * that allocation at three times what reaching the field costs.
		 */
		var wanted:Int = infer(value);

		if (wanted == tI32 || wanted == tF64) {
			var raw:Int = reg(wanted);
			into(value, raw);

			var cell:Int = siteSlot();
			var site:Int = siteIndex(name);
			var writer:Int = wanted == tI32 ? storeIntIndex() : storeFloatIndex();

			ops.push({op: OCallN, args: [reg(tVoid), writer, target, held, raw, cell, site]});
			return;
		}

		var written:Int = dynOf(value);
		var cell:Int = siteSlot();
		var site:Int = siteIndex(name);

		ops.push({op: OCallN, args: [reg(tVoid), storeIndex(), target, held, written, cell, site]});
	}

	/**
	 * @param obj An expression.
	 * @return The batch class it is statically known to be an instance of, or null.
	 *
	 * Only properties need this now, and only because a property is not a field: reading one has to
	 * become a call to its accessor, and nothing at runtime would tell us that. `this` is the case
	 * that matters, since a class reads its own properties by bare name.
	 */
	/**
	 * Builds an array holding a call's arguments, for the support calls that take one.
	 *
	 * @param params The arguments.
	 * @return A register holding the array.
	 */
	function gathered(params:Array<Expr>):Int {
		var given:Int = reg(tDyn);

		/**
		 * The short shapes in one call. Building an argument list by making it empty and pushing into
		 * it is a call per argument on top of the call being made, and nearly every call a script
		 * writes has three arguments or fewer.
		 */
		if (params.length <= 3) {
			var boxed:Array<Int> = [for (p in params) dynOf(p)];
			callSupport('args' + params.length, boxed, given);
			return given;
		}

		callSupport('array', [], given);

		for (p in params)
			callSupport('push', [given, dynOf(p)], reg(tDyn));

		return given;
	}

	/**
	 * @return The full path of the class whose body is being written.
	 *
	 * What `super` is resolved against. The interpreter binds `super` lexically, so two classes deep
	 * each body means its own base, and naming the class the body belongs to is the only way to say
	 * which of them is meant.
	 */
	function owningPath():String {
		var here:String = inside ?? owning;
		return pack.length > 0 ? pack + '.' + here : here;
	}

	/**
	 * @param name A bare name inside a method body.
	 * @return Whether the enclosing class declares it as an instance member, so it means `this.name`.
	 */
	/**
	 * @return Whether the enclosing class's chain reaches a base this batch did not declare.
	 *
	 * When it does, a name nothing here recognises is still likely to be a field, since the base
	 * brought members along that only the world can list.
	 */
	function reachesHost():Bool {
		var at:Null<String> = inside;

		while (at != null) {
			if (opened.exists(at))
				return true;

			at = bases.get(at);
		}

		return false;
	}

	function isMemberOf(name:String):Bool {
		var at:Null<String> = inside;

		/**
		 * Up the chain, because a field a base declared is as much this class's as its own. Only
		 * bases of the batch are walked: one the host owns has members nothing here can enumerate,
		 * and a bare name that reaches nothing known stays a refusal rather than a quiet null.
		 */
		while (at != null) {
			var own:Null<StringMap<Bool>> = members.get(at);
			if (own != null && own.exists(name))
				return true;

			at = bases.get(at);
		}

		return false;
	}

	/**
	 * @param t A class's `extends` clause.
	 * @return The name it gives, or null when there is none.
	 */
	function baseName(t:Null<CType>):Null<String> {
		return switch (t) {
			case null: null;
			case CTPath(parts, _): parts[parts.length - 1];
			case CTParent(inner): baseName(inner);
			case _: null;
		}
	}

	function ownerNamed(obj:Expr):Null<String> {
		return switch (obj.e) {
			case EIdent('this'): inside;
			case EParent(inner): ownerNamed(inner);
			case ENew(cls, _) if (classes.exists(cls)): cls;
			case _: null;
		}
	}

	/** @return An expression naming the instance the body being written belongs to. */
	function thisExpr(pos:Position):Expr {
		return {e: EIdent('this'), pos: pos};
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
	 * A comparison with a dynamic on either side is one the instructions cannot make, because what
	 * it means depends on what is in there: two strings compare by their contents, and two abstracts
	 * through whichever `@:op` method they declare.
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
	 *
	 * Only a number or a boolean is boxed on the way into a dynamic. A class, a function value and
	 * an object are already pointers the VM can carry as one, and boxing such a value a second time
	 * wraps the pointer rather than the value: what comes out is not the closure, and calling it
	 * says so.
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
			ops.push({op: primitive(a) ? OToDyn : OMov, args: [to, from]});
			return;
		}

		/**
		 * A class of the batch held as one of its bases is the same pointer, so it moves. The other
		 * way is a real question and is asked, which is what `cast` means.
		 */
		if (instance(a) && instance(b)) {
			ops.push({op: derives(owners.get(a), owners.get(b)) ? OMov : OSafeCast, args: [to, from]});
			return;
		}

		if (a == tDyn) {
			if (b == tI32)
				callSupport('toInt', [from], to);
			else if (b == tF64)
				callSupport('toFloat', [from], to);
			else if (b == tBool)
				callSupport('toBool', [from], to);
			else
				ops.push({op: OSafeCast, args: [to, from]});
			return;
		}

		throw new Unsupported('a value of one type where another was declared', null);
	}

	/** @return Whether a type is one the VM cannot carry in a dynamic without boxing it first. */
	inline function primitive(t:Int):Bool {
		return t == tI32 || t == tF64 || t == tBool || t == tVoid;
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
		var shape:Null<String> = SHAPES.get(field);

		/**
		 * A closure held in a dynamic register is called through `hl_dyn_call`, which boxes every
		 * argument and the result and reads the callee's real signature to marshal against. That is
		 * most of what a support call costs, and it is paid on every field read, every dynamic
		 * operator and every iteration step.
		 *
		 * Naming the signature turns it into a direct call. What the signature may say is limited by
		 * a module holding no host types: `String`, `Array` and any class of the host cannot be named
		 * here at all, so a support function that takes one takes `Dynamic` instead, and only the
		 * primitives keep their own type. That is the whole reason `SHAPES` is written out rather
		 * than derived: it has to agree with `Runtime` exactly, and it is checked by every case in
		 * the corpus that reaches one.
		 */
		if (shape != null && shape.length == args.length + 1) {
			var kinds:Array<Int> = [for (i in 0...args.length) typeFor(shape.charAt(i))];
			var ret:Int = typeFor(shape.charAt(args.length));
			var signed:Int = module.typeId(TFun(kinds, ret));

			var fn:Int = reg(signed);
			ops.push({op: OGetGlobal, args: [fn, supportSlot(field, signed)]});

			var returned:Int = reg(ret);
			var pass:Array<Int> = [returned, fn];
			for (a in args)
				pass.push(a);

			ops.push({op: OCallClosure, args: pass});

			if (ret == tVoid)
				return;

			/**
			 * `move`, which opens a dynamic through `Runtime.toInt` or `toFloat` rather than through
			 * `OSafeCast`.
			 *
			 * The instruction is faster and was used here for exactly that reason, and it is wrong:
			 * it can only open a dynamic that really holds the number, and a script's value may be a
			 * boxed abstract instead. `var rate:Float = speed` where `speed` is a scripted abstract
			 * over `Float` is ordinary code, and it ended every frame of a real project with
			 * `Can't cast hxscript.types.ScriptedAbstractValue to f64`. The conversions know how to
			 * open one; the instruction does not, and cannot be taught.
			 */
			move(returned, slot);
			return;
		}

		var fn:Int = reg(tDyn);
		ops.push({op: OGetGlobal, args: [fn, supportSlot(field, tDyn)]});

		var returned:Int = reg(tDyn);
		var pass:Array<Int> = [returned, fn];
		for (a in args)
			pass.push(a);

		ops.push({op: OCallClosure, args: pass});
		unbox(returned, slot);
	}

	/**
	 * The signature of each `Runtime` static, as one letter per argument and then the result.
	 *
	 * `d` is dynamic, `i` an `Int`, `f` a `Float`, `b` a `Bool`, `v` nothing. A name absent from here
	 * is called the old way, through a dynamic closure, which is always correct and merely slower, so
	 * adding one is an optimisation and forgetting one is not a bug.
	 *
	 * **It has to match `hxscript.hl.Runtime`.** A letter that disagrees with the real signature is a
	 * call made with the wrong convention, which is not an error anyone reports.
	 */
	static var SHAPES:StringMap<String> = [
		'add' => 'ddd', 'sub' => 'ddd', 'mul' => 'ddd', 'div' => 'ddd', 'mod' => 'ddd',
		'eq' => 'ddb', 'lt' => 'ddb', 'lte' => 'ddb', 'gt' => 'ddb', 'gte' => 'ddb',
		'neg' => 'dd', 'truthy' => 'db', 'toInt' => 'di', 'toFloat' => 'df', 'toBool' => 'db',
		'fetch' => 'dddd', 'store' => 'ddddv', 'get' => 'ddd', 'set' => 'dddv', 'raise' => 'dd',
		'invoke' => 'dddd', 'send' => 'ddddd', 'make' => 'ddd', 'anyMap' => 'd',
		'index' => 'ddd', 'indexInt' => 'did', 'setIndex' => 'dddd', 'array' => 'd', 'push' => 'ddv',
		'object' => 'd', 'setField' => 'dddv', 'put' => 'dddd', 'range' => 'ddd',
		'iterator' => 'dd', 'pairs' => 'dd', 'step' => 'db', 'take' => 'dd',
		'args0' => 'd', 'args1' => 'dd', 'args2' => 'ddd', 'args3' => 'dddd', 'dispatch' => 'ddddd',
		'call' => 'ddd', 'text' => 'dy',
		'has' => 'ddb', 'sized' => 'ddb', 'ctor' => 'dd', 'params' => 'dd',
		'isOfType' => 'ddb', 'catches' => 'ddb', 'enumOf' => 'dddd', 'regex' => 'ddd',
		'superCall' => 'dddd', 'superGet' => 'dddd', 'superNew' => 'dddv'
	];

	/**
	 * @param letter One of `SHAPES`'s letters.
	 * @return The register type it names.
	 */
	function typeFor(letter:String):Int {
		return switch (letter) {
			case 'i': tI32;
			case 'f': tF64;
			case 'b': tBool;
			case 'v': tVoid;
			case 'y': module.prim(HBytes);
			default: tDyn;
		}
	}

	/**
	 * Takes a dynamic result out into whatever register was asked for.
	 *
	 * Kept apart from `move` because `move` reaches for one of these calls when it has to open an
	 * abstract, and a call that used `move` to land its own answer would ask for itself forever.
	 * What comes back from a support call is never an abstract, so the plain cast is enough.
	 */
	function unbox(from:Int, to:Int):Void {
		if (from == to)
			return;

		if (regs[from] == regs[to]) {
			ops.push({op: OMov, args: [to, from]});
			return;
		}

		/** An instance is a pointer the VM already carries as a dynamic, so it moves rather than casts. */
		if (instance(regs[from]) && regs[to] == tDyn) {
			ops.push({op: OMov, args: [to, from]});
			return;
		}

		ops.push({op: OSafeCast, args: [to, from]});
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
	inline function land(sites:Array<Int>):Void {
		landAt(sites, ops.length);
	}

	/**
	 * Points every listed jump at one instruction.
	 *
	 * @param sites Where the jumps were written.
	 * @param target Which instruction they should reach. A target already written has to be a label,
	 *        which is what `mark` leaves.
	 */
	function landAt(sites:Array<Int>, target:Int):Void {
		for (site in sites) {
			var instr:Instruction = ops[site];
			instr.args[instr.args.length - 1] = target - site - 1;
		}
	}

	/** Writes a jump back to a marked position. */
	function back(target:Int):Void {
		ops.push({op: OJAlways, args: [target - ops.length - 1]});
	}

	/** Opens a scope. */
	inline function push():Void {
		scopes.push(new StringMap());
		annotated.push(new StringMap());
		elements.push(new StringMap());
	}

	/** Closes one. */
	inline function pop():Void {
		scopes.pop();
		annotated.pop();
		elements.pop();
	}

	/**
	 * Records that a name was written with a class the world already has.
	 *
	 * @param name The local.
	 * @param t Its annotation, or null when it had none.
	 */
	function annotate(name:String, t:Null<CType>):Void {
		var holds:Int = holding(t);

		if (holds != tDyn)
			elements[elements.length - 1].set(name, holds);

		var written:Null<String> = baseName(t);

		if (written == null || classes.exists(written) || declared.exists(written))
			return;

		if (knownAs(written) != null)
			annotated[annotated.length - 1].set(name, written);
	}

	/**
	 * @param t An annotation.
	 * @return The register type an element of it is, or dynamic when it is not an array of one.
	 */
	function holding(t:Null<CType>):Int {
		return switch (t) {
			case CTParent(inner): holding(inner);
			case CTPath(['Array'], params) if (params != null && params.length == 1): typeOf(params[0]);
			case _: tDyn;
		}
	}

	/**
	 * @param e An expression.
	 * @return The register type an element read out of it is, or dynamic when nothing said.
	 */
	function element(e:Expr):Int {
		return switch (e.e) {
			case EParent(inner): element(inner);

			case EIdent(name):
				var i:Int = elements.length - 1;
				while (i >= 0) {
					var here:Null<Int> = elements[i].get(name);
					if (here != null)
						return here;
					i--;
				}
				tDyn;

			case _: tDyn;
		}
	}

	/**
	 * @param name A type as a script wrote it.
	 * @return The world's type for it, or null when nothing there is a class of that name.
	 *
	 * Asked once per name. The answer decides what a member of it is, which is asked for every
	 * access the emitter writes, and going out to the world for each of those would cost more than
	 * the knowledge is worth.
	 */
	function knownAs(name:String):Null<hl.Type> {
		if (known.exists(name))
			return known.get(name);

		var found:Dynamic = world(name);
		var t:Null<hl.Type> = (found != null && found is Class) ? (cast found : hl.BaseType).__type__ : null;

		if (t != null && Loader.fieldCount(t) < 0)
			t = null;

		known.set(name, t);
		return t;
	}

	/**
	 * What a member of a class the world already has answers with.
	 *
	 * **This is what makes reaching the host fast.** A call into the world had no type until it came
	 * back, so its answer was boxed and everything the script did with it afterwards was dynamic
	 * too. A local written with a class the world has says which class, and the world says what its
	 * members answer, and the difference measured is thirty-fold on the same line.
	 *
	 * @param obj What is being read from or called on.
	 * @param name The member.
	 * @param called Whether it is being called rather than read.
	 * @return Its register type, or dynamic when nothing here can say.
	 */
	function worldlyKind(obj:Expr, name:String, called:Bool):Int {
		var written:Null<String> = worldly(obj);
		if (written == null)
			return tDyn;

		var key:String = written + (called ? '(' : '.') + name;

		if (!answers.exists(key)) {
			var held:Null<hl.Type> = knownAs(written);
			var kind:Int = -1;

			if (held == null) {
				kind = -1;
			} else if (called) {
				var shape:Null<Array<Int>> = Loader.protoShape(held, name);
				if (shape != null)
					kind = shape[1];
			} else {
				kind = Loader.fieldKind(held, name);
			}

			var found:Int = kind < 0 ? tDyn : fromKind(kind);

			/**
			 * Nothing is inferred as void. A call that answers nothing is written as a statement, and
			 * a register of that type is not somewhere a value can be put on the way.
			 */
			answers.set(key, (found < 0 || found == tVoid) ? tDyn : found);
		}

		return answers.get(key);
	}

	/**
	 * @param e An expression.
	 * @return The world's class it is held as, or null when nothing said.
	 */
	function worldly(e:Expr):Null<String> {
		return switch (e.e) {
			case EParent(inner): worldly(inner);

			case EIdent(name):
				var i:Int = annotated.length - 1;
				while (i >= 0) {
					var here:Null<String> = annotated[i].get(name);
					if (here != null)
						return here;
					i--;
				}
				null;

			case _: null;
		}
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
	 * Some operators produce what Haxe says they produce whatever they are given rather than
	 * whatever their operands were: the bitwise ones are always integers, a division is always a
	 * float even between two integers, and a range is an iterator.
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
				slot != null ? regs[slot] : declaredMember(name);

			case EBinop(op, a, b) if (COMPARE.exists(op) || op == '&&' || op == '||'): tBool;

			case EBinop(op, _, _) if (INTEGRAL.indexOf(op) >= 0): tI32;
			case EBinop('/', _, _): tF64;
			case EBinop('...', _, _): tDyn;

			case EBinop(_, a, b):
				var l:Int = infer(a);
				var r:Int = infer(b);
				(l == tDyn || r == tDyn || instance(l) || instance(r)) ? tDyn : widest(l, r);

			case ETernary(_, yes, no):
				var l:Int = infer(yes);
				var r:Int = infer(no);
				l == r ? l : ((l == tI32 && r == tF64) || (l == tF64 && r == tI32) ? tF64 : tDyn);

			case ENew(cls, _) if (shapes.exists(cls)): shapes.get(cls);
			case ENew(_, _): tDyn;

			/**
			 * An element is held as what the array said only when that is a number, because a number
			 * is converted rather than cast: an array whose annotation was not what it held would
			 * otherwise stop answering and start refusing, which is not what the interpreter does
			 * with the same line and not what cppia does either. The class case gets its speed from
			 * the field below instead, which needs no cast at all.
			 */
			case EArray(obj, _):
				var held:Int = element(obj);
				instance(held) ? tDyn : held;

			case EField(obj, name, _):
				var held:Null<Int> = fieldType(obj, name) ?? elementField(obj, name);
				held == null ? worldlyKind(obj, name, false) : held;

			case ECall(callee, _):
				if (selfCall(callee) != null) {
					tDyn;
				} else {
					var sig:Null<Signature> = calledSignature(callee);

					if (sig != null) {
						sig.ret;
					} else {
						switch (callee.e) {
							case EField(obj, name, _): worldlyKind(obj, name, true);
							case _: tDyn;
						}
					}
				}

			case _: tDyn;
		}
	}

	/** @return Whichever of two types the other converts to, which is Float when either is. */
	function widest(a:Int, b:Int):Int {
		return (a == tF64 || b == tF64) ? tF64 : a;
	}

	/**
	 * @param name A bare name that is not a local.
	 * @return What the class being emitted declared it as, or dynamic when nothing did.
	 *
	 * Walks the bases too, because a field a base declares is reached by the same bare name and is
	 * just as much an `Int` when it says so.
	 */
	function declaredMember(name:String):Int {
		/**
		 * `owning` rather than `inside`, because `inside` is null in a static and a static reads its
		 * class's statics by bare name just as a method reads its fields by one.
		 */
		var at:Null<String> = inside != null ? inside : owning;

		while (at != null) {
			/**
			 * What a static is laid out as, before what it was announced as. One with no starting
			 * value is a dynamic whatever its annotation said, because null is what it holds until
			 * something puts a value there.
			 */
			var kept:Null<StringMap<Int>> = staticTypes.get(at);
			if (kept != null && kept.exists(name))
				return kept.get(name);

			var known:Null<StringMap<Int>> = memberTypes.get(at);
			if (known != null && known.exists(name))
				return known.get(name);

			at = bases.get(at);
		}

		return tDyn;
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
			case CTParent(inner): typeOf(inner);

			/**
			 * A class of the batch is a type this module holds, so something annotated with one is
			 * held as that class rather than as a dynamic. That is what turns a field of it into an
			 * offset and a call on it into one through the method table.
			 */
			case CTPath(parts, _) if (shapes.exists(parts[parts.length - 1])): shapes.get(parts[parts.length - 1]);

			case _: tDyn;
		}
	}

	/** @return Whether a register type is one of the batch's own classes. */
	inline function instance(t:Int):Bool {
		return owners.exists(t);
	}

	/**
	 * @param from A class of the batch.
	 * @param to Another.
	 * @return Whether the first is the second, or extends it.
	 */
	function derives(from:String, to:String):Bool {
		var at:Null<String> = from;

		while (at != null) {
			if (at == to)
				return true;

			at = bases.get(at);
		}

		return false;
	}

	/**
	 * Works out whether an expression names something the host owns.
	 *
	 * Anything written `Owner.field`, where the owner's last segment is capitalised and is not a type
	 * of this batch, is taken to be the host's. Whether it really is cannot be settled here: the
	 * answer comes when the module is loaded and the binding is resolved, and a name nothing answers
	 * to leaves a null in the global rather than failing to compile.
	 *
	 * **The owner may be a whole path.** A script writes `hxd.Timer.dt` as readily as `Timer.dt`, and
	 * the only difference is how many segments precede the type; the last capitalised one is the
	 * type and everything before it is its package.
	 *
	 * @param e The expression.
	 * @return The owner and field, or null when it is not that shape.
	 */
	function hostName(e:Expr):Null<{owner:String, field:String}> {
		switch (e.e) {
			case ECall(callee, _):
				return hostName(callee);

			case EParent(inner):
				return hostName(inner);

			case EField(obj, field, _):
				var path:Null<String> = dotted(obj);
				if (path == null)
					return null;

				var parts:Array<String> = path.split('.');
				if (!isTypeName(parts[parts.length - 1]))
					return null;

				if (declared.exists(path) || signatures.exists(path + '.' + field))
					return null;

				return {owner: path, field: field};

			case _:
				return null;
		}
	}

	/**
	 * @param e An expression.
	 * @return It written out as a dotted path, or null when it is not one.
	 *
	 * A local of the head's name means it is a value being read rather than a package being named,
	 * which is what stops `player.stats.hp` being mistaken for a type path.
	 */
	function dotted(e:Expr):Null<String> {
		return switch (e.e) {
			case EIdent(name) if (lookup(name) == null && !isMemberOf(name) && !isStaticOf(owning, name)):
				name;

			case EField(obj, name, false):
				var head:Null<String> = dotted(obj);
				head == null ? null : head + '.' + name;

			case EParent(inner):
				dotted(inner);

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
	 * @param callee What is being called.
	 * @return The host static a bare name stands for, or null when it does not stand for one.
	 *
	 * A local of the same name wins, which is what shadowing means and what the interpreter does.
	 */
	function ambientCallee(callee:Expr):Null<{owner:String, field:String}> {
		return switch (callee.e) {
			case EParent(inner):
				ambientCallee(inner);

			case EIdent(name) if (lookup(name) == null && ambientMembers.exists(name)):
				ambientMembers.get(name);

			case _:
				null;
		}
	}

	/**
	 * Takes the bare names the host answers with a static of its own.
	 *
	 * Written the way `Compiler.statics` writes them, which the cppia backend reads the same way, so
	 * a host configures both targets identically and does not have to know which one it got.
	 *
	 * @param entries Each written `name=owner.path::field`.
	 */
	public function ambientStatics(entries:Array<String>):Void {
		for (entry in entries) {
			var equals:Int = entry.indexOf('=');
			if (equals < 0)
				continue;

			var target:String = entry.substr(equals + 1);
			var split:Int = target.indexOf('::');
			if (split < 0)
				continue;

			ambientMembers.set(entry.substr(0, equals), {
				owner: target.substr(0, split),
				field: target.substr(split + 2)
			});
		}
	}

	/**
	 * @param callee What is being called.
	 * @return The instance and the method name, when the call is a method on `this` written bare.
	 *
	 * **The name, not a function index.** A method call has to find whatever the instance actually
	 * has, because a subclass overriding it must win, and the instance is the world's rather than
	 * this module's. Calling the index a bare name resolved to at emit time would call the class the
	 * body was written in, which is right until somebody extends it and then silently is not.
	 */
	function selfCall(callee:Expr):Null<String> {
		return switch (callee.e) {
			case EParent(inner): selfCall(inner);
			case EIdent(name) if (lookup(name) == null && isMethodOf(name)): name;
			case _: null;
		}
	}

	/**
	 * @param sig A declared shape.
	 * @param params The arguments a call was written with.
	 * @param member Whether the shape takes an instance first.
	 * @return Whether the call can be made against it.
	 */
	function fits(sig:Signature, params:Array<Expr>, member:Bool):Bool {
		return sig.rest || params.length <= sig.args.length - (member ? 1 : 0);
	}

	/** @return Whether the enclosing class or one of its bases declares `name` as an instance method. */
	function isMethodOf(name:String):Bool {
		var at:Null<String> = inside;

		while (at != null) {
			if (signatures.exists(at + '#' + name))
				return true;

			at = bases.get(at);
		}

		return false;
	}

	/**
	 * @param cls A class of the batch, or null.
	 * @param name A field name.
	 * @return Its accessors when it is a property of that class or one of its bases, or null.
	 */
	/**
	 * @param a One of a function's arguments.
	 * @return Whether a caller may leave it out.
	 *
	 * A default value implies it, since a caller supplying nothing is the only way for the default to
	 * be what runs.
	 */
	inline function optional(a:Argument):Bool {
		return a.opt == true || a.value != null;
	}

	function propertyOf(cls:Null<String>, name:String):Null<{get:String, set:String}> {
		var at:Null<String> = cls;

		while (at != null) {
			var here:Null<StringMap<{get:String, set:String}>> = props.get(at);
			if (here != null && here.exists(name))
				return here.get(name);

			at = bases.get(at);
		}

		return null;
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

	/**
	 * @return Whether a declaration is a property rather than a field.
	 *
	 * A property with an accessor on one side and nothing readable on the other stores nothing, so
	 * giving it a slot would put storage behind it that reads and writes silently skip the accessor.
	 * One with `default` or `null` on either side does store, and is a field that happens to be
	 * announced.
	 */
	/**
	 * @param cls A class of the batch, or null.
	 * @param name A field name.
	 * @return Whether that class or one of its bases declared it `var name(null, ...)`.
	 */
	function restricted(cls:Null<String>, name:String):Bool {
		var at:Null<String> = cls;

		while (at != null) {
			var closed:Null<StringMap<Bool>> = unreadable.get(at);
			if (closed != null && closed.exists(name))
				return true;

			at = bases.get(at);
		}

		return false;
	}

	/**
	 * How a declaration may be reached: whether it keeps storage, and which side of an access can
	 * go straight to it.
	 *
	 * A side is plain when nothing was written for it or it was written `default`. `null` keeps
	 * storage but is not readable from outside; `never` keeps none of its own; an accessor name or
	 * `dynamic` means a call, and which call is the world's business rather than this one's.
	 *
	 * @param f The field.
	 * @param v Its declaration.
	 * @return `KEEPS`, `READS` and `WRITES` as bits.
	 */
	function reaching(f:FieldDecl, v:VarDecl):Int {
		var reads:Bool = v.get == null || v.get == 'default';
		var writes:Bool = v.set == null || v.set == 'default';

		var held:Int = 0;
		if (reads)
			held |= READS;
		if (writes)
			held |= WRITES;

		if (reads || writes || v.get == 'null' || v.set == 'null' || stored(f))
			held |= KEEPS;

		return held;
	}

	/**
	 * @param cls A class of the batch, or null.
	 * @param name A field name.
	 * @return How it may be reached, walking the bases, or 0 when nothing of the batch declares it.
	 */
	function reachOf(cls:Null<String>, name:String):Int {
		var at:Null<String> = cls;

		while (at != null) {
			var here:Null<StringMap<Int>> = reach.get(at);
			if (here != null && here.exists(name))
				return here.get(name);

			at = bases.get(at);
		}

		return 0;
	}

	/** @return Whether a property was declared to keep storage behind its accessors anyway. */
	function stored(f:FieldDecl):Bool {
		if (f.meta == null)
			return false;

		for (m in f.meta) {
			if (m.name == ':isVar')
				return true;
		}

		return false;
	}

	function property(v:VarDecl):Bool {
		if (v.get == null && v.set == null)
			return false;

		var reads:String = v.get == null ? 'default' : v.get;
		var writes:String = v.set == null ? 'default' : v.set;

		return (reads == 'get' || reads == 'never') && (writes == 'set' || writes == 'never');
	}

	/**
	 * The global holding one of the batch's own classes.
	 *
	 * A static belongs to the class rather than to any instance, and the class a script declared is
	 * an object the world already holds, so its statics are read and written on that rather than
	 * kept a second time here. That also means a static one of these writes is one the interpreter
	 * sees, which matters while only part of a batch compiles.
	 *
	 * @param cls The class's name in this batch.
	 * @return The global's index.
	 */
	function ownerSlot(cls:String):Int {
		var path:String = pack.length > 0 ? pack + '.' + cls : cls;
		return bind('o' + path, {index: 0, kind: BOwner, owner: path});
	}

	/** @return Whether a name is a static of a class of this batch. */
	function isStaticOf(cls:String, name:String):Bool {
		var here:Null<StringMap<Bool>> = owned.get(cls);
		return here != null && here.exists(name);
	}

	/** Writes a read of a static, through its accessor when it has one. */
	function staticRead(cls:String, name:String, slot:Int, pos:Position):Void {
		var accessor:Null<{get:String, set:String}> = propertyOf(cls, name);

		if (accessor != null) {
			if (accessor.get != 'get')
				throw new Unsupported('reading ' + name + ', which is declared ' + accessor.get, pos);

			emitCall({e: EField({e: EIdent(cls), pos: pos}, 'get_' + name, false), pos: pos}, [], slot, pos);
			return;
		}

		var at:Null<Int> = staticAt(cls, name, READS);

		if (at != null) {
			var held:Int = reg(holders.get(cls));
			ops.push({op: OGetGlobal, args: [held, values.get(cls)]});

			var kind:Int = staticTypes.get(cls).get(name);
			var got:Int = regs[slot] == kind ? slot : reg(kind);
			ops.push({op: OField, args: [got, held, at]});

			if (got != slot)
				move(got, slot);

			return;
		}

		callSupport('get', [ownerOf(cls), named(name)], slot);
	}

	/**
	 * @param cls A class of the batch.
	 * @param name A static's name.
	 * @return Where it sits in that class's own value, or null when this batch did not lay it out.
	 */
	function staticAt(cls:String, name:String, side:Int):Null<Int> {
		if (reachOf(cls, name) & side == 0)
			return null;

		var here:Null<StringMap<Int>> = staticSlots.get(cls);
		return here == null || !here.exists(name) ? null : here.get(name);
	}

	/** Writes a write of a static, through its accessor when it has one. */
	function staticWrite(cls:String, name:String, value:Expr, pos:Position):Void {
		var accessor:Null<{get:String, set:String}> = propertyOf(cls, name);

		if (accessor != null) {
			if (accessor.set != 'set')
				throw new Unsupported('writing ' + name + ', which is declared ' + accessor.set, pos);

			var discard:Int = reg(tDyn);
			emitCall({e: EField({e: EIdent(cls), pos: pos}, 'set_' + name, false), pos: pos}, [value], discard, pos);
			return;
		}

		var at:Null<Int> = staticAt(cls, name, WRITES);

		if (at != null) {
			var held:Int = reg(holders.get(cls));
			ops.push({op: OGetGlobal, args: [held, values.get(cls)]});

			var written:Int = reg(staticTypes.get(cls).get(name));
			into(value, written);

			ops.push({op: OSetField, args: [held, at, written]});
			return;
		}

		callSupport('set', [ownerOf(cls), named(name), dynOf(value)], reg(tDyn));
	}

	/**
	 * @return The register `++` or `--` can step in place, or null when it has to be written out.
	 *
	 * Only an integer local can be stepped by an instruction. A static, a field or an array element
	 * is somewhere the instruction cannot reach, and a float is not what it counts in.
	 */
	function stepping(target:Expr):Null<Int> {
		var slot:Null<Int> = switch (target.e) {
			case EIdent(name): lookup(name);
			case EParent(inner): stepping(inner);
			case _: null;
		}

		return (slot != null && regs[slot] == tI32) ? slot : null;
	}

	/** @return The assignment a step means, for the places no instruction can step. */
	function stepped(op:String, target:Expr, pos:Position):Expr {
		var one:Expr = {e: EConst(CInt(1)), pos: pos};
		var moved:Expr = {e: EBinop(op == '++' ? '+' : '-', target, one), pos: pos};
		return {e: EBinop('=', target, moved), pos: pos};
	}

	/** Gives back every trap open at this point, which a return has to do before it leaves. */
	function closeTraps():Void {
		for (i in 0...traps)
			ops.push({op: OEndTrap, args: [1]});
	}

	/**
	 * @return Which enum constructor a call names, or null when it names something else.
	 *
	 * Both spellings answer here: the qualified one, and the bare one an import brings into scope.
	 */
	function constructorOf(callee:Expr):Null<{owner:String, name:String}> {
		return switch (callee.e) {
			case EParent(inner):
				constructorOf(inner);

			case EField({e: EIdent(t)}, name, _) if (declared.exists(t) && constructors.get(name) == t):
				{owner: t, name: name};

			case EIdent(name) if (lookup(name) == null && constructors.exists(name)):
				{owner: constructors.get(name), name: name};

			case _:
				null;
		}
	}

	/** @return A register holding one of the batch's own types. */
	function ownerOf(cls:String):Int {
		var slot:Int = reg(tDyn);
		ops.push({op: OGetGlobal, args: [slot, ownerSlot(cls)]});
		return slot;
	}

	/**
	 * @return A register holding what carries the module's own fields.
	 *
	 * A function or a variable written outside any class belongs to the module rather than to
	 * anything in it, and the world keeps one holder per module for exactly those.
	 */
	function looseOwner():Int {
		var slot:Int = reg(tDyn);
		ops.push({op: OGetGlobal, args: [slot, bind('module', {index: 0, kind: BModule})]});
		return slot;
	}

	/** @return A register holding a name, for the calls that take one. */
	function named(name:String):Int {
		var slot:Int = reg(tDyn);
		ops.push({op: OGetGlobal, args: [slot, constSlot('s' + name, name)]});
		return slot;
	}

	/** @return A dynamic register holding a number, for the calls that take one. */
	function counted(v:Int):Int {
		var raw:Int = reg(tI32);
		ops.push({op: OInt, args: [raw, module.intId(v)]});

		var slot:Int = reg(tDyn);
		ops.push({op: OToDyn, args: [slot, raw]});
		return slot;
	}

	/**
	 * Writes a `switch`.
	 *
	 * Every case is a run of patterns, an optional guard, and a body. A pattern that fails and a
	 * guard that fails go to the same place, which is what makes a guarded case fall through to a
	 * later case that would also have matched rather than to the default.
	 *
	 * @param subject What is being matched, run once.
	 * @param cases The cases in order.
	 * @param fallback The default, or null when there is none.
	 * @param slot Where to leave the value, or null when the switch is a statement.
	 * @param pos Where it appears.
	 */
	function emitSwitch(subject:Expr, cases:Array<{values:Array<Expr>, expr:Expr, ?guard:Expr}>, fallback:Null<Expr>, slot:Null<Int>, pos:Position):Void {
		var value:Int = dynOf(subject);
		var done:Array<Int> = [];

		for (c in cases) {
			push();
			var toNext:Array<Int> = [];

			if (c.values.length == 1) {
				match(c.values[0], value, toNext);
			} else {
				var hit:Array<Int> = [];

				for (p in c.values) {
					var missed:Array<Int> = [];
					match(p, value, missed);
					hit.push(jump(OJAlways));
					land(missed);
				}

				toNext.push(jump(OJAlways));
				land(hit);
			}

			if (c.guard != null)
				condition(c.guard, false, toNext);

			if (slot == null)
				statement(c.expr);
			else
				into(c.expr, slot);

			done.push(jump(OJAlways));
			land(toNext);
			pop();
		}

		if (fallback != null) {
			if (slot == null)
				statement(fallback);
			else
				into(fallback, slot);
		} else if (slot != null) {
			ops.push({op: ONull, args: [slot]});
		}

		land(done);
	}

	/**
	 * Writes a function value.
	 *
	 * HashLink has no closure that carries an environment, only one that binds a first argument, so
	 * what a lambda sees from outside itself is gathered into an object and that object is what gets
	 * bound. The object is shared rather than copied, which is what a name declared before the
	 * lambda and written after it needs, and what lets a named function reach itself: its own value
	 * is put in the object once the closure exists.
	 *
	 * Anything both captured and written has already been turned into a one-element array by the
	 * shared capture pass, so the object holds the array and both sides write through it.
	 *
	 * Every argument is dynamic whatever it was declared. A call site holding a function value knows
	 * nothing about its shape and can only pass dynamics, and a typed parameter handed one takes the
	 * pointer for the value, which reads back as a number nobody wrote.
	 *
	 * @param args The lambda's arguments.
	 * @param body Its body.
	 * @param name Its name, when it has one.
	 * @param slot Where to leave the function value.
	 * @param pos Where it appears.
	 */
	function emitLambda(args:Array<Argument>, body:Expr, name:Null<String>, slot:Int, pos:Position):Void {
		var seen:Array<String> = free(args, body);
		var fields:Array<Field> = [for (n in seen) {name: module.stringId(n), type: tDyn}];

		var envType:Int = module.reserveType();
		module.defineType(envType, TObj(module.stringId('captured' + envType), fields, [], -1, 0));

		var built:Int = reg(envType);
		ops.push({op: ONew, args: [built]});

		for (i in 0...seen.length) {
			var from:Int = lookup(seen[i]);
			var held:Int = reg(tDyn);
			move(from, held);
			ops.push({op: OSetField, args: [built, i, held]});
		}

		var signature:Array<Int> = [envType];
		for (a in args)
			signature.push(tDyn);

		var findex:Int = module.reserve();
		inner(findex, seen, signature, args, body, pos);

		var made:Int = reg(module.typeId(TFun(signature.slice(1), tDyn)));
		ops.push({op: OInstanceClosure, args: [made, findex, built]});

		var self:Int = name == null ? -1 : seen.indexOf(name);
		if (self >= 0) {
			var boxed:Int = reg(tDyn);
			move(made, boxed);
			ops.push({op: OSetField, args: [built, self, boxed]});
		}

		move(made, slot);
	}

	/**
	 * Writes the function a lambda becomes, with everything it captured unpacked on entry.
	 *
	 * Everything about which function is being written lives on this class, so the state of the one
	 * in progress is put aside and put back. Nesting is what makes that necessary: a lambda inside a
	 * lambda arrives here while this is already part-way through.
	 */
	function inner(findex:Int, seen:Array<String>, signature:Array<Int>, args:Array<Argument>, body:Expr, pos:Position):Void {
		var heldOps:Array<Instruction> = ops;
		var heldRegs:Array<Int> = regs;
		var heldScopes:Array<StringMap<Int>> = scopes;
		var heldBreaks:Array<Array<Int>> = breaks;
		var heldContinues:Array<Array<Int>> = continues;
		var heldReturns:Int = returns;
		var heldInside:Null<String> = inside;
		var heldTraps:Int = traps;
		var heldCollector:Null<{slot:Int, pairs:Bool}> = collector;

		ops = [];
		regs = [];
		scopes = [];
		annotated = [];
		elements = [];
		breaks = [];
		continues = [];
		returns = tDyn;
		inside = null;
		traps = 0;
		collector = null;

		push();

		for (t in signature)
			regs.push(t);

		for (i in 0...args.length)
			scopes[0].set(args[i].name, i + 1);

		for (i in 0...seen.length) {
			var held:Int = reg(tDyn);
			ops.push({op: OField, args: [held, 0, i]});
			scopes[0].set(seen[i], held);
		}

		statement(body);

		if (ops.length == 0 || ops[ops.length - 1].op != ORet) {
			var empty:Int = reg(tDyn);
			ops.push({op: ONull, args: [empty]});
			ops.push({op: ORet, args: [empty]});
		}

		module.add({
			type: module.typeId(TFun(signature, tDyn)),
			findex: findex,
			regs: regs,
			ops: ops
		});

		ops = heldOps;
		regs = heldRegs;
		scopes = heldScopes;
		breaks = heldBreaks;
		continues = heldContinues;
		returns = heldReturns;
		inside = heldInside;
		traps = heldTraps;
		collector = heldCollector;
	}

	/**
	 * Works out what a lambda uses from outside itself.
	 *
	 * Every name it mentions is gathered and then kept only if it is bound where the lambda sits.
	 * Gathering too much is harmless: a name the lambda declares for itself shadows what was
	 * captured under it, so the extra is a field nothing reads.
	 *
	 * @param args The lambda's arguments.
	 * @param body Its body.
	 * @return The names it captures, in a settled order.
	 */
	function free(args:Array<Argument>, body:Expr):Array<String> {
		var mentioned:StringMap<Bool> = new StringMap();
		gather(body, mentioned);

		for (a in args)
			mentioned.remove(a.name);

		var out:Array<String> = [];
		for (n in mentioned.keys()) {
			if (lookup(n) != null)
				out.push(n);
		}

		out.sort(Reflect.compare);
		return out;
	}

	/** Collects every name an expression mentions. */
	function gather(e:Expr, out:StringMap<Bool>):Void {
		if (e == null)
			return;

		switch (e.e) {
			case EIdent(v):
				out.set(v, true);
			case _:
		}

		hxscript.syntax.ExprTools.iter(e, function(child:Expr):Void gather(child, out));
	}

	/**
	 * Writes a `try` and its clauses.
	 *
	 * The trap is what the VM unwinds to, and it pops itself when it fires, so the ordinary path
	 * ends the trap itself and the caught path does not. Clauses are tried in order and the first
	 * whose type takes the value runs; a value none of them takes is thrown onward, which is what
	 * leaves an exception a script did not ask about looking the same as one from a script that had
	 * no `try` at all.
	 *
	 * @param body What is protected.
	 * @param name The first clause's variable.
	 * @param t The first clause's type, or null when it takes everything.
	 * @param handler The first clause's body.
	 * @param extra The clauses after it.
	 * @param slot Where to leave the value, or null when the try is a statement.
	 * @param pos Where it appears.
	 */
	function emitTry(body:Expr, name:String, t:Null<CType>, handler:Expr, extra:Null<Array<{v:String, t:Null<CType>, expr:Expr}>>, slot:Null<Int>,
			pos:Position):Void {
		var thrown:Int = reg(tDyn);
		var trap:Int = ops.length;
		ops.push({op: OTrap, args: [thrown, 0]});

		traps++;
		if (slot == null)
			statement(body);
		else
			into(body, slot);
		traps--;

		ops.push({op: OEndTrap, args: [1]});
		var done:Array<Int> = [jump(OJAlways)];

		land([trap]);

		var clauses:Array<{v:String, t:Null<CType>, expr:Expr}> = [{v: name, t: t, expr: handler}];
		if (extra != null) {
			for (c in extra)
				clauses.push(c);
		}

		for (c in clauses) {
			push();
			var toNext:Array<Int> = [];

			var wanted:Null<Int> = catchType(c.t, pos);
			if (wanted != null) {
				var takes:Int = reg(tBool);
				callSupport('catches', [thrown, wanted], takes);
				toNext.push(jump(OJFalse, [takes]));
			}

			var bound:Int = reg(tDyn);
			ops.push({op: OMov, args: [bound, thrown]});
			scopes[scopes.length - 1].set(c.v, bound);

			if (slot == null)
				statement(c.expr);
			else
				into(c.expr, slot);

			done.push(jump(OJAlways));
			land(toNext);
			pop();
		}

		ops.push({op: ORethrow, args: [thrown]});
		land(done);
	}

	/**
	 * @return A register holding what a clause catches, or null when it catches everything.
	 *
	 * `Dynamic`, `Any` and `Exception` are the spellings that take anything, which is the
	 * interpreter's list rather than one of this emitter's.
	 */
	function catchType(t:Null<CType>, pos:Position):Null<Int> {
		if (t == null)
			return null;

		return switch (t) {
			case CTPath(path, _):
				var name:String = path[path.length - 1];
				if (name == 'Dynamic' || name == 'Any' || name == 'Exception')
					null;
				else
					typeNamed(path.join('.'));

			case CTParent(inner):
				catchType(inner, pos);

			case _:
				null;
		}
	}

	/** @return A register holding the type an expression names. */
	function typeValue(t:Expr, pos:Position):Int {
		var name:Null<String> = calledName(t);
		if (name == null)
			throw new Unsupported('a type that is not written as a name', pos);
		return typeNamed(name);
	}

	/**
	 * @return A register holding a type, by the name a script wrote.
	 *
	 * A class of the batch is the one the world holds rather than the shape this module gave it, so
	 * a value made here and a value made by the interpreter answer the same about what they are.
	 */
	function typeNamed(name:String):Int {
		if (declared.exists(name))
			return ownerOf(name);

		var slot:Int = reg(tDyn);
		ops.push({op: OGetGlobal, args: [slot, hostSlot(name, '')]});
		return slot;
	}

	/**
	 * Writes the test one pattern makes, and binds whatever it names.
	 *
	 * A bare lowercase name binds rather than compares, even when a local of that name is in scope.
	 * That is Haxe's rule and it is worth being sure of: comparing instead reads a value nothing
	 * here put there, and answers plausibly.
	 *
	 * @param p The pattern.
	 * @param value A register holding what it is matched against.
	 * @param onFail Filled with the jumps taken when it does not match.
	 */
	function match(p:Expr, value:Int, onFail:Array<Int>):Void {
		switch (p.e) {
			case EParent(inner) | EMeta(_, _, inner):
				match(inner, value, onFail);

			case EBinop('|', a, b):
				var missed:Array<Int> = [];
				match(a, value, missed);

				var hit:Int = jump(OJAlways);
				land(missed);
				match(b, value, onFail);
				land([hit]);

			case EIdent('_'):

			case EIdent(name) if (!isTypeName(name)):
				var bound:Int = reg(tDyn);
				move(value, bound);
				scopes[scopes.length - 1].set(name, bound);

			case ECall({e: EIdent(ctor)}, binds) if (constructors.exists(ctor) || subjectCtor(ctor)):
				var made:Int = reg(tDyn);
				callSupport('ctor', [value], made);

				var right:Int = reg(tBool);
				callSupport('eq', [made, named(ctor)], right);
				onFail.push(jump(OJFalse, [right]));

				var given:Int = reg(tDyn);
				callSupport('params', [value], given);

				for (i in 0...binds.length) {
					var item:Int = reg(tDyn);
					callSupport('index', [given, counted(i)], item);
					match(binds[i], item, onFail);
				}

			/**
			 * A constructor of whatever is being matched, named on its own.
			 *
			 * `case None:` against a host enum names something that resolves to nothing here, and the
			 * comparison below would have had to evaluate it. Reading the constructor off the subject
			 * asks the question directly, which is what the interpreter does with the same pattern.
			 */
			case EIdent(name) if (subjectCtor(name)):
				var made:Int = reg(tDyn);
				callSupport('ctor', [value], made);

				var right:Int = reg(tBool);
				callSupport('eq', [made, named(name)], right);
				onFail.push(jump(OJFalse, [right]));

			case EArrayDecl(items):
				var right:Int = reg(tBool);
				callSupport('sized', [value, counted(items.length)], right);
				onFail.push(jump(OJFalse, [right]));

				for (i in 0...items.length) {
					var item:Int = reg(tDyn);
					callSupport('index', [value, counted(i)], item);
					match(items[i], item, onFail);
				}

			case EObject(fields):
				for (f in fields) {
					var there:Int = reg(tBool);
					callSupport('has', [value, named(f.name)], there);
					onFail.push(jump(OJFalse, [there]));

					var held:Int = reg(tDyn);
					callSupport('get', [value, named(f.name)], held);
					match(f.e, held, onFail);
				}

			case _:
				var same:Int = reg(tBool);
				callSupport('eq', [value, dynOf(p)], same);
				onFail.push(jump(OJFalse, [same]));
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
