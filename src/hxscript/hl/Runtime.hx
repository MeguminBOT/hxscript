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
import hxscript.proxy.TypeProxy.ICustomEnumValueType;
import hxscript.runtime.Reference;
import hxscript.runtime.Variable;
import hxscript.types.AbstractTools;
import hxscript.types.AbstractValue;
import hxscript.types.IScriptedInstance;
import hxscript.types.ScriptedAbstractValue;
import hxscript.types.ScriptedClass;

/**
 * What compiled code calls for the things it cannot say in instructions.
 *
 * A module HashLink loads gets its own type table, so a `String` or an `Array` built inside one
 * would not be the host's and could not be handed back. Everything that is not a number, a boolean
 * or a class of the batch is therefore a host value held in a `Dynamic`, and most of what a script
 * does to one is an instruction already: `ODynGet` reads a field, `OCallClosure` calls a method.
 *
 * This is the remainder. Each entry is bound into a global the same way a host static is, so
 * reaching one costs a global read and a call rather than anything the emitter has to arrange.
 *
 * The semantics are the interpreter's, deliberately: an operator has to mean the same thing
 * whichever of the two ran it, and the interpreter is where that meaning is already decided. Its
 * own helpers are instance methods on a hot class, so they are mirrored here rather than shared,
 * which keeps a widening of the compiler from moving the interpreter's code around.
 */
@:keep
class Runtime {
	/**
	 * Adds, which is also how strings are joined.
	 *
	 * **This is the dynamic path and only the dynamic path.** An operand with a type of its own is in
	 * a typed register and its arithmetic is an instruction, which wraps, as Haxe's `Int` does.
	 * Reaching here means at least one side was written `Dynamic` or came from somewhere untyped,
	 * and arithmetic on a `Dynamic` promotes in Haxe rather than wrapping. So the two answers are
	 * both right and the emitter picks between them by what the script declared, which is the same
	 * rule the interpreter follows in `widensNumbers`.
	 *
	 * @param a The left operand.
	 * @param b The right operand.
	 * @return `Int` when both are `Int` and the sum fits, `String` when either is a string,
	 *         otherwise `Float`.
	 */
	public static function add(a:Dynamic, b:Dynamic):Dynamic {
		if (a is Int && b is Int) {
			/** `Std.int`, for the reason the interpreter's own `numAdd` gives: `v is Int` is true of a
			 * whole `Float`, and a cast leaves it one, which the bitwise test cannot take. */
			var x:Int = Std.int(a);
			var y:Int = Std.int(b);
			var sum:Int = x + y;
			return overflowed(x, y, sum) ? x * 1.0 + y * 1.0 : sum;
		}
		if (a is String || b is String)
			return Std.string(a) + Std.string(b);
		if (a is AbstractValue || b is AbstractValue)
			return arith('+', a, b);
		return (a : Float) + (b : Float);
	}

	/** @return The difference, promoting past the width for the reason `add` gives. */
	public static function sub(a:Dynamic, b:Dynamic):Dynamic {
		if (a is Int && b is Int) {
			/** `Std.int`, for the reason the interpreter's own `numAdd` gives: `v is Int` is true of a
			 * whole `Float`, and a cast leaves it one, which the bitwise test cannot take. */
			var x:Int = Std.int(a);
			var y:Int = Std.int(b);
			var diff:Int = x - y;
			return overflowed(x, -y, diff) ? x * 1.0 - y * 1.0 : diff;
		}
		if (a is AbstractValue || b is AbstractValue)
			return arith('-', a, b);
		return (a : Float) - (b : Float);
	}

	/**
	 * Whether adding or subtracting two `Int`s carried past the width.
	 *
	 * The sign test rather than a comparison against the same result as a `Float`, which is the
	 * interpreter's reason too: the float form reads differently per target, and this does not.
	 *
	 * @param x The left operand.
	 * @param y The right operand, negated already when this was a subtraction.
	 * @param sum What the wrapped operation produced.
	 * @return Whether the true result is outside `Int`.
	 */
	static inline function overflowed(x:Int, y:Int, sum:Int):Bool {
		return ((x ^ sum) & (y ^ sum)) < 0;
	}

	/** @return The product, keeping `Int` when both operands are `Int`. */
	public static function mul(a:Dynamic, b:Dynamic):Dynamic {
		if (a is Int && b is Int)
			return (a : Int) * (b : Int);
		if (a is AbstractValue || b is AbstractValue)
			return arith('*', a, b);
		return (a : Float) * (b : Float);
	}

	/** @return The quotient, which Haxe makes a `Float` even for two `Int`s. */
	public static function div(a:Dynamic, b:Dynamic):Dynamic {
		if (a is AbstractValue || b is AbstractValue)
			return arith('/', a, b);
		return (a : Float) / (b : Float);
	}

	/** @return The remainder, keeping `Int` when both operands are `Int`. */
	public static function mod(a:Dynamic, b:Dynamic):Dynamic {
		if (a is Int && b is Int)
			return (a : Int) % (b : Int);
		if (a is AbstractValue || b is AbstractValue)
			return arith('%', a, b);
		return (a : Float) % (b : Float);
	}

	/** @return Whether two values are equal, by the rule the interpreter uses. */
	public static function eq(a:Dynamic, b:Dynamic):Bool {
		if (a is ICustomEnumValueType && b is ICustomEnumValueType)
			return (a : ICustomEnumValueType).eq(b);

		if (a is AbstractValue || b is AbstractValue)
			return cmp('==', a, b);

		return a == b;
	}

	/** @return Whether the left orders before the right. */
	public static function lt(a:Dynamic, b:Dynamic):Bool {
		if (a is AbstractValue || b is AbstractValue)
			return cmp('<', a, b);
		return a < b;
	}

	/** @return Whether the left orders before the right or equals it. */
	public static function lte(a:Dynamic, b:Dynamic):Bool {
		if (a is AbstractValue || b is AbstractValue)
			return cmp('<=', a, b);
		return a <= b;
	}

	/** @return Whether the left orders after the right. */
	public static function gt(a:Dynamic, b:Dynamic):Bool {
		if (a is AbstractValue || b is AbstractValue)
			return cmp('>', a, b);
		return a > b;
	}

	/** @return Whether the left orders after the right or equals it. */
	public static function gte(a:Dynamic, b:Dynamic):Bool {
		if (a is AbstractValue || b is AbstractValue)
			return cmp('>=', a, b);
		return a >= b;
	}

	/** @return The value negated, keeping `Int` when it is one. */
	public static function neg(a:Dynamic):Dynamic {
		if (a is Int)
			return -(a : Int);
		if (a is AbstractValue)
			return arith('-', 0, a);
		return -(a : Float);
	}

	/**
	 * @return Whether a value counts as true, which is being `true` and nothing else.
	 *
	 * A condition on a dynamic cannot be cast to a boolean, because a dynamic holding anything but a
	 * boolean would throw rather than answer, and the interpreter answers.
	 */
	public static function truthy(v:Dynamic):Bool {
		return v == true;
	}

	/** @return A value as an `Int`, which is what the bitwise operators take. */
	public static function toInt(v:Dynamic):Int {
		if (v is Int)
			return (v : Int);
		if (v is AbstractValue)
			return toInt(AbstractTools.underlying(v));
		return v == null ? 0 : Std.int((v : Float));
	}

	/**
	 * @return A regular expression.
	 *
	 * Made per evaluation rather than bound once as a constant, because matching leaves its result
	 * on the object and one shared between every use of a literal would answer about the wrong
	 * subject.
	 */
	public static function regex(pattern:Dynamic, flags:Dynamic):Dynamic {
		return new EReg(pattern, flags);
	}

	/** @return A range as a value, which is what `a...b` is outside a `for`. */
	public static function range(low:Dynamic, high:Dynamic):Dynamic {
		return new IntIterator(toInt(low), toInt(high));
	}

	/** @return A new empty array, which is what a literal and a comprehension both start from. */
	public static function array():Dynamic {
		return new Array<Dynamic>();
	}

	/**
	 * Builds an argument list in one call rather than one per argument.
	 *
	 * A call's arguments have to reach the runtime as an array, and building one by making it empty
	 * and pushing into it costs a call per argument on top of the call being made. Almost every call
	 * a script writes has three arguments or fewer, so those three shapes are worth having: one call,
	 * one allocation, no growth.
	 */
	public static function args0():Dynamic {
		return [];
	}

	/** @return A one-argument list. */
	public static function args1(a:Dynamic):Dynamic {
		return [a];
	}

	/** @return A two-argument list. */
	public static function args2(a:Dynamic, b:Dynamic):Dynamic {
		return [a, b];
	}

	/** @return A three-argument list. */
	public static function args3(a:Dynamic, b:Dynamic, c:Dynamic):Dynamic {
		return [a, b, c];
	}

	/**
	 * Calls a function value the host owns.
	 *
	 * Not `OCallClosure` on it directly, which is what this used to be. HashLink checks a dynamic
	 * call against the callee's real signature and refuses one that leaves an optional argument off:
	 * `Lambda.count(list)` is one argument to a function that declares two, and the VM reports
	 * `Missing arguments : 2 expected but 1 passed` rather than applying the default. `Reflect` knows
	 * how to pad it, and is what the interpreter has always called the same function through, so this
	 * is also what makes the two agree.
	 *
	 * @param fn The function.
	 * @param args Its arguments.
	 * @return What it answered.
	 */
	public static function call(fn:Dynamic, args:Dynamic):Dynamic {
		return Reflect.callMethod(null, fn, (args : Array<Dynamic>));
	}

	/**
	 * Calls a named member, remembering where it was found.
	 *
	 * The same memory `fetch` keeps, for the same reason: a method lives in the instance's slots as a
	 * closure already bound to it, so finding one is the same string hash a field read was, and a
	 * call site asks the same question of the same receiver over and over.
	 *
	 * @param o The receiver.
	 * @param name The method's name.
	 * @param args Its arguments.
	 * @param site This call site's own memory.
	 * @return What it answered.
	 */
	public static function dispatch(o:Dynamic, name:Dynamic, args:Dynamic, site:Dynamic):Dynamic {
		if (o is IScriptedInstance) {
			var cell:Slot = cast site;
			var inst:IScriptedInstance = cast o;
			var held:Null<Variable> = (cell.owner == inst) ? cell.held : remember(inst, name, cell);

			if (held != null) {
				var fn:Dynamic = held.a != null ? held.a : held.r;

				if (fn != null)
					return Reflect.callMethod(o, fn, (args : Array<Dynamic>));
			}
		}

		return send(o, name, args, null);
	}

	/** Appends to an array. */
	public static function push(a:Dynamic, v:Dynamic):Void {
		(a : Array<Dynamic>).push(v);
	}

	/**
	 * Puts a pair in a map, making the map when there is not one yet.
	 *
	 * Which kind of map a literal wants is decided by its first key, and in a comprehension there is
	 * no first key until the loop has run once. Passing the container back rather than making it up
	 * front is what lets both spellings share one path.
	 *
	 * @param into The map so far, or null before there is one.
	 * @param key The key.
	 * @param value The value.
	 * @return The map, which is the one passed in unless this call had to make it.
	 */
	public static function put(into:Dynamic, key:Dynamic, value:Dynamic):Dynamic {
		if (into == null) {
			if (key is String)
				into = new haxe.ds.StringMap<Dynamic>();
			else if (key is Int)
				into = new haxe.ds.IntMap<Dynamic>();
			else if (Reflect.isEnumValue(key))
				into = new haxe.ds.EnumValueMap<Dynamic, Dynamic>();
			else
				into = new haxe.ds.ObjectMap<Dynamic, Dynamic>();
		}

		(into : haxe.Constraints.IMap<Dynamic, Dynamic>).set(key, value);
		return into;
	}

	/** @return A new empty anonymous structure. */
	public static function object():Dynamic {
		return {};
	}

	/** Puts a named field on a value, which is how an object literal is filled. */
	public static function setField(o:Dynamic, name:Dynamic, v:Dynamic):Void {
		Reflect.setField(o, name, v);
	}

	/**
	 * @return A named field of something a script declared.
	 *
	 * Through the library's own reflection rather than the standard one: a scripted class keeps its
	 * statics somewhere the runtime cannot see, so asking the value itself is the only way to be
	 * given what the interpreter would have been given.
	 *
	 * **A property is read through its getter**, which is what makes this the same reader the
	 * interpreter is. Nothing here can tell a property from a plain field, and nothing needs to: a
	 * value with no accessor for the name answers with the field, so asking for the property is the
	 * one question with a right answer either way.
	 */
	public static function get(o:Dynamic, name:Dynamic):Dynamic {
		if (o is ScriptedAbstractValue) {
			var boxed:ScriptedAbstractValue = cast o;
			if (boxed.owner != null)
				return boxed.owner.getField(boxed.boxed, name);
		}

		/**
		 * A scripted field read from the instance's own slots, in one lookup.
		 *
		 * The reflection hooks would find it too, and did, but they go looking: a property path, then
		 * a scan of the native field names, then the slots. That is several times the work of the
		 * interpreter's own read for the same field, and a compiler that costs more per field than
		 * interpreting is not worth having. `getLocal` is the read the interpreter performs, so this
		 * is the same answer by the same route, accessors included.
		 *
		 * A name that is not in the slots belongs to the host half of a bridge, and falls through.
		 */
		if (o is IScriptedInstance) {
			var inst:IScriptedInstance = cast o;
			var slots:Map<String, Variable> = @:privateAccess inst.__vars;
			var held:Null<Variable> = slots == null ? null : slots.get(name);

			if (held != null) {
				/**
				 * One lookup, and the accessor path only when there is an accessor. A slot with no
				 * getter is read straight off, which is the first line of the interpreter's own
				 * reader; anything else is handed back to it rather than reimplemented.
				 */
				if (held.get == null)
					return held.a != null ? held.a : held.r;

				return @:privateAccess inst.__interp.getLocal(name, slots);
			}
		}

		var through:Dynamic = hxscript.proxy.ReflectProxy.getProperty(o, name);

		/**
		 * A plain field read straight, when asking for the property answered with nothing. The two
		 * are one question on most values, and not on a generated bridge, whose property hook says
		 * nothing about a plain native field.
		 */
		return through != null ? through : hxscript.proxy.ReflectProxy.field(o, name);
	}

	/**
	 * Calls a named member of a value, whatever kind of value it is.
	 *
	 * An abstract is the reason this is not a field read followed by a call: its members are statics
	 * that take the boxed value first, so there is nothing on the value to read.
	 *
	 * @param o The receiver.
	 * @param name The member's name.
	 * @param args Its arguments.
	 * @return What it answered.
	 */
	public static function invoke(o:Dynamic, name:Dynamic, args:Dynamic):Dynamic {
		if (o is ScriptedAbstractValue) {
			var boxed:ScriptedAbstractValue = cast o;
			if (boxed.owner != null)
				return boxed.owner.callField(boxed.boxed, name, args);
		}

		var own:Dynamic = get(o, name);
		return own == null ? null : Reflect.callMethod(o, own, args);
	}

	/**
	 * The `super` mirror an instance carries, or null when it has none.
	 *
	 * **Read rather than reconstructed, and that is the whole design.** Every scripted instance is
	 * given one when it is built, and it is built differently for the two kinds of base: extending a
	 * host class snapshots `Reflect.field(this, f)` for each of the base's methods, and extending a
	 * scripted class snapshots the base's own closures before the subclass's overwrite them. Either
	 * way what comes out is the function `super.f` should reach, so taking it from here is the answer
	 * the interpreter gets by definition rather than by imitation.
	 *
	 * Working it out here instead would be a second implementation of that rule, and the obvious
	 * guess, `Reflect.field(self, name)`, is exactly the one that recurses forever on a scripted base
	 * because the field it finds is the override doing the asking.
	 *
	 * Taken from `__vars` rather than the interpreter's locals: locals belong to a frame, and by the
	 * time compiled code asks there is no frame of the interpreter's to belong to.
	 *
	 * @param self The instance.
	 * @return Its mirror, or null.
	 */
	static function mirror(self:Dynamic, owner:Dynamic):Dynamic {
		if (!(self is IScriptedInstance))
			return null;

		var slots:Map<String, Variable> = @:privateAccess (cast self : IScriptedInstance).__vars;
		if (slots == null)
			return null;

		var held:Variable = slots.get('super@' + owner);
		if (held == null)
			held = slots.get('super');

		return held == null ? null : held.r;
	}

	/**
	 * @param self The instance.
	 * @param name The field.
	 * @return The base's version of it, or null when there is none.
	 */
	static function superSlot(self:Dynamic, owner:Dynamic, name:Dynamic):Dynamic {
		var found:Dynamic = mirror(self, owner);
		if (found == null || !(found is Reference))
			return null;

		switch (cast(found, Reference)) {
			case RSuper(locals, _):
				if (locals == null || !locals.exists(name))
					return null;

				var slot:Variable = locals.get(name);
				return slot.a ?? slot.r;

			default:
				return null;
		}
	}

	/**
	 * Calls the base class's version of a method.
	 *
	 * @param self The instance.
	 * @param name The method.
	 * @param args Its arguments.
	 * @return What it answered.
	 */
	public static function superCall(self:Dynamic, owner:Dynamic, name:Dynamic, args:Dynamic):Dynamic {
		var found:Dynamic = superSlot(self, owner, name);

		/**
		 * Nothing in the mirror means the base is the host's and the method is one of its own that
		 * the bridge overrode. The bridge's override is what to call: it runs the script's version
		 * only when it is not already running it, so entering it from inside falls through to the
		 * native one, which is what `super` means here.
		 *
		 * Safe from looping only because a scripted base always has the name in its mirror, so this
		 * is reached exactly when there is a guard on the other side of it.
		 */
		if (found == null)
			found = Reflect.field(self, name);

		return found == null ? null : Reflect.callMethod(self, found, args);
	}

	/**
	 * Reads the base class's version of a field.
	 *
	 * A variable is not virtual, so a base that keeps no separate copy of one is not a failure: the
	 * instance's own field is the same field, and reading it is the right answer.
	 *
	 * @param self The instance.
	 * @param name The field.
	 * @return Its value.
	 */
	public static function superGet(self:Dynamic, owner:Dynamic, name:Dynamic):Dynamic {
		var found:Dynamic = superSlot(self, owner, name);
		return found == null ? get(self, name) : found;
	}

	/**
	 * Calls the base class's constructor.
	 *
	 * The mirror carries it beside the fields, which is where the interpreter takes it from, so a
	 * scripted base's own `new` is reached rather than the bridge's.
	 *
	 * @param self The instance.
	 * @param args The arguments.
	 */
	public static function superNew(self:Dynamic, owner:Dynamic, args:Dynamic):Void {
		var found:Dynamic = mirror(self, owner);

		if (found != null && found is Reference) {
			switch (cast(found, Reference)) {
				case RSuper(_, constructor):
					if (constructor != null) {
						Reflect.callMethod(self, constructor, args);
						return;
					}

				default:
			}
		}

		var built:Dynamic = Reflect.field(self, '__constructSuper');
		if (built != null)
			Reflect.callMethod(self, built, args);
	}

	/** @return A value as a `Float`, opening an abstract to what it wraps first. */
	public static function toFloat(v:Dynamic):Float {
		if (v is AbstractValue)
			return toFloat(AbstractTools.underlying(v));
		return v == null ? 0.0 : (v : Float);
	}

	/** @return A value as a `Bool`, which nothing but `true` answers. */
	public static function toBool(v:Dynamic):Bool {
		if (v is AbstractValue)
			return toBool(AbstractTools.underlying(v));
		return v == true;
	}

	/**
	 * Reads a field, remembering where it was so the next read of the same one is two instructions.
	 *
	 * **This is the whole of the field optimisation and it is worth saying why it works.** A scripted
	 * instance keeps its fields in a `Map<String, Variable>`, so every read was a string hash, and
	 * that is most of what made a compiled field access barely faster than an interpreted one. The
	 * hash cannot be removed, but it can be paid once: the `Variable` a name resolves to is created
	 * when the instance is built and mutated in place forever after, so a site that has resolved one
	 * may hold on to it and check only that the receiver is the same object.
	 *
	 * Each field access in the emitted code gets its own `Slot`, filled the first time it runs. A hit
	 * is a pointer compare and a field read. A miss is what the read cost before, plus the compare,
	 * which is why a site that sees a different instance every time is no worse than it was.
	 *
	 * Only plain fields are ever cached. A property has to reach its accessor every time, and one
	 * that is not in the instance's slots at all belongs to the host half of a bridge, which this
	 * knows nothing about; both fall through to the uncached reader, which is the same answer by the
	 * same route as before.
	 *
	 * @param o The receiver.
	 * @param name The field.
	 * @param site This access's own memory.
	 * @return The value.
	 */
	/**
	 * @return Which slot a plain read may take, or -1 when the access has to go the long way.
	 *
	 * A property is refused, since reading one runs its accessor, and so is a name the class has no
	 * slot for. What is allowed is what `fetch` would have answered with the stored value.
	 */
	public static function readSlot(o:Dynamic, name:Dynamic):Int {
		var at:Int = slotOf(o, name);
		if (at < 0)
			return -1;

		var held:Variable = @:privateAccess (cast o : IScriptedInstance).__slots[at];
		return (held == null || held.get != null || held.set != null) ? -1 : at;
	}

	/**
	 * @return Which slot a plain write may take, or -1.
	 *
	 * Everything the interpreter would have checked on the way in has to be absent: an accessor, a
	 * declared type to check the value against, and finality.
	 */
	public static function writeSlot(o:Dynamic, name:Dynamic):Int {
		var at:Int = slotOf(o, name);
		if (at < 0)
			return -1;

		var held:Variable = @:privateAccess (cast o : IScriptedInstance).__slots[at];
		if (held == null || held.get != null || held.set != null || held.isFinal)
			return -1;

		/**
		 * The slot and what a value has to be to go in it, in one answer. A declared type is checked
		 * on the way in, so what the runtime is told is which check to make rather than that it may
		 * skip one.
		 */
		var wants:Int = switch (wanted(held.t)) {
			case WAnything: 0;
			case WInt: 1;
			case WFloat: 2;
			case WBool: 3;
			case _: -1;
		}

		return wants < 0 ? -1 : (at << 2) | wants;
	}

	/** @return Where this instance keeps that name, or -1 when it does not keep it by position. */
	static function slotOf(o:Dynamic, name:Dynamic):Int {
		if (!(o is IScriptedInstance))
			return -1;

		var inst:IScriptedInstance = cast o;
		var base:ScriptedClass = @:privateAccess inst.__base;
		var slots:haxe.ds.Vector<Variable> = @:privateAccess inst.__slots;

		if (base == null || base.slotIndex == null || slots == null)
			return -1;

		var at:Null<Int> = base.slotIndex.get(name);
		return (at == null || at >= slots.length) ? -1 : at;
	}

	/** `dispatch`, for a receiver the native runtime could not resolve a method on. */
	public static function dispatch0(o:Dynamic, name:Dynamic, site:Dynamic):Dynamic {
		return dispatch(o, name, [], site);
	}

	public static function dispatch1(o:Dynamic, name:Dynamic, site:Dynamic, a:Dynamic):Dynamic {
		return dispatch(o, name, [a], site);
	}

	public static function dispatch2(o:Dynamic, name:Dynamic, site:Dynamic, a:Dynamic, b:Dynamic):Dynamic {
		return dispatch(o, name, [a, b], site);
	}

	public static function dispatch3(o:Dynamic, name:Dynamic, site:Dynamic, a:Dynamic, b:Dynamic, c:Dynamic):Dynamic {
		return dispatch(o, name, [a, b, c], site);
	}

	/**
	 * Raises what the interpreter raises, for a construct that fails when it runs rather than when it
	 * is compiled.
	 *
	 * @param message The text the interpreter carries.
	 */
	public static function raise(message:Dynamic):Dynamic {
		return hxscript.runtime.Raise.custom(Std.string(message));
	}

	/** @return `fetch`, opened as an Int the way the interpreter opens one. */
	public static function fetchInt(o:Dynamic, name:Dynamic, site:Dynamic):Int {
		return toInt(fetch(o, name, site));
	}

	/** @return `fetch`, opened as a Float the way the interpreter opens one. */
	public static function fetchFloat(o:Dynamic, name:Dynamic, site:Dynamic):Float {
		return toFloat(fetch(o, name, site));
	}

	public static function fetch(o:Dynamic, name:Dynamic, site:Dynamic):Dynamic {
		if (o is IScriptedInstance) {
			var cell:Slot = cast site;
			var inst:IScriptedInstance = cast o;
			var held:Null<Variable> = (cell.owner == inst) ? cell.held : remember(inst, name, cell);

			if (held != null)
				return held.a != null ? held.a : held.r;
		}

		return get(o, name);
	}

	/**
	 * Writes a field, through the same memory `fetch` keeps.
	 *
	 * The write itself still goes through the interpreter's own `writeLocal`, so finality, method
	 * rebinding and the declared type are all checked exactly as they were. What the cache saves is
	 * finding the slot, which is the part that was costing.
	 *
	 * @param o The receiver.
	 * @param name The field.
	 * @param v The value.
	 * @param site This access's own memory.
	 */
	public static function store(o:Dynamic, name:Dynamic, v:Dynamic, site:Dynamic):Void {
		if (o is IScriptedInstance) {
			var cell:Slot = cast site;
			var inst:IScriptedInstance = cast o;
			var held:Null<Variable> = (cell.owner == inst) ? cell.held : remember(inst, name, cell);

			if (held != null) {
				if (!quick(cell, held, v))
					@:privateAccess cell.interp.writeLocal(held, name, v);

				return;
			}
		}

		set(o, name, v);
	}

	/**
	 * Writes a slot the site has already established is an ordinary one.
	 *
	 * **This is where the remaining cost of a field write was.** The interpreter's own write is
	 * correct and general: it checks finality, then whether a method is being rebound, then casts the
	 * value against the declared type, and that last one alone is a map lookup and a walk through
	 * every kind of type a script can write. Per assignment, in a loop.
	 *
	 * None of it can be dropped, but almost all of it can be decided once. What the declaration wants
	 * is fixed when the site is first resolved; what is left per write is one test that the value is
	 * still that kind, and the three guards below, which are a field read each. Anything that does
	 * not answer plainly falls through to the interpreter's own write, which is what defines the
	 * behaviour this is a shortcut for.
	 *
	 * @param site The resolved site.
	 * @param held The slot.
	 * @param v The value.
	 * @return Whether it was written here.
	 */
	static function quick(site:Slot, held:Variable, v:Dynamic):Bool {
		if (held.a != null || held.isFinal || Reflect.isFunction(held.r))
			return false;

		switch (site.wants) {
			case WAnything:
				held.r = v;
				return true;

			case WInt:
				if (!(v is Int))
					return false;
				held.r = v;
				return true;

			case WFloat:
				if (!(v is Float))
					return false;
				held.r = (v : Float);
				return true;

			case WBool:
				if (!(v is Bool))
					return false;
				held.r = v;
				return true;

			case WString:
				if (!(v is String))
					return false;
				held.r = v;
				return true;

			case _:
				return false;
		}
	}

	/**
	 * Resolves a field once and fills a site with it.
	 *
	 * @param inst The receiver.
	 * @param name The field.
	 * @param site The site to fill.
	 * @return The slot, or null when this one is not the kind that may be remembered.
	 */
	static function remember(inst:IScriptedInstance, name:Dynamic, site:Slot):Null<Variable> {
		var slots:Map<String, Variable> = @:privateAccess inst.__vars;
		var held:Null<Variable> = slots == null ? null : slots.get(name);

		if (held == null || held.get != null || held.set != null)
			return null;

		site.owner = inst;
		site.held = held;
		site.interp = @:privateAccess inst.__interp;
		site.wants = wanted(held.t);

		return held;
	}

	/**
	 * @param t What a slot was declared as.
	 * @return Which of the kinds a write to it can be checked against without casting.
	 */
	static function wanted(t:Null<hxscript.syntax.Expr.CType>):Wants {
		if (t == null)
			return WAnything;

		return switch (t) {
			case CTPath(path, _) if (path.length == 1):
				switch (path[0]) {
					case 'Int': WInt;
					case 'Float': WFloat;
					case 'Bool': WBool;
					case 'String': WString;
					case _: WChecked;
				}
			case _: WChecked;
		}
	}

	/**
	 * Writes a named field of something a script declared, through its setter when it has one.
	 *
	 * The instance's own slots first, for the reason `get` gives: it is one lookup instead of a
	 * search, and it is the write the interpreter performs for the same field.
	 */
	public static function set(o:Dynamic, name:Dynamic, v:Dynamic):Void {
		if (o is IScriptedInstance) {
			var inst:IScriptedInstance = cast o;
			var slots:Map<String, Variable> = @:privateAccess inst.__vars;

			if (slots != null && slots.exists(name)) {
				@:privateAccess inst.__interp.setLocal(name, v, slots);
				return;
			}
		}

		hxscript.proxy.ReflectProxy.setProperty(o, name, v);
	}

	/**
	 * @return Whether a catch clause takes a value.
	 *
	 * A clause naming nothing takes everything, which is also what a type nothing answers to does:
	 * the interpreter treats an unresolvable annotation as catching rather than as never matching,
	 * and a compiled clause has to agree or the two disagree about which one runs.
	 */
	public static function catches(v:Dynamic, type:Dynamic):Bool {
		return type == null || isOfType(v, type);
	}

	/**
	 * @return Whether a value is of a type, which is what `is` asks.
	 *
	 * Through the library's own test rather than the standard one, which knows nothing of a class a
	 * script declared and refuses to be handed one.
	 */
	public static function isOfType(v:Dynamic, type:Dynamic):Bool {
		return type != null && hxscript.proxy.StdProxy.isOfType(v, type);
	}

	/**
	 * @return A new instance of a type a script declared.
	 *
	 * Through the library's own construction, which is what knows how to build a scripted class or
	 * an abstract. A module cannot build one itself: what it allocated would be its own type rather
	 * than the one the world holds.
	 */
	public static function make(type:Dynamic, args:Dynamic):Dynamic {
		if (type is hxscript.types.ScriptedAbstract)
			return (type : hxscript.types.ScriptedAbstract).create((args : Array<Dynamic>));

		return hxscript.proxy.TypeProxy.createInstance(type, (args : Array<Dynamic>));
	}

	/**
	 * @return A map whose implementation is picked once a key arrives.
	 *
	 * `Map` is Haxe's one `@:multiType`: which class `new Map()` becomes is decided by the key type,
	 * and there is no type here to decide it with. The interpreter answers the same way, with the
	 * container that works out its own kind, so the two agree about what a script's map is.
	 */
	public static function anyMap():Dynamic {
		return new hxscript.runtime.AnyMap();
	}

	/**
	 * Calls a method on a value, falling back to whatever the module brought into scope with `using`.
	 *
	 * Whether a name is the value's own method or a static that takes it first cannot be settled
	 * before the value exists, so both are tried in the order Haxe tries them.
	 *
	 * @param o The receiver.
	 * @param name The method's name.
	 * @param args Its arguments.
	 * @param extensions The types `using` brought in, or null when there were none.
	 * @return What the method answered.
	 */
	public static function send(o:Dynamic, name:Dynamic, args:Dynamic, extensions:Dynamic):Dynamic {
		if (o != null && (o is ScriptedAbstractValue || get(o, name) != null))
			return invoke(o, name, (args : Array<Dynamic>));

		if (extensions != null) {
			for (holder in (extensions : Array<Dynamic>)) {
				var shared:Dynamic = holder == null ? null : get(holder, name);
				if (shared == null)
					continue;

				var all:Array<Dynamic> = [o].concat((args : Array<Dynamic>));
				return Reflect.callMethod(holder, shared, all);
			}
		}

		throw 'Cannot call ' + name;
	}

	/**
	 * @return An enum value.
	 *
	 * Built here rather than by calling what the constructor's name resolves to. A constructor that
	 * takes arguments answers as a var-args builder, and going through one loses the arguments by
	 * the time anything asks the value what it was made with.
	 *
	 * @param type The enum.
	 * @param name The constructor's name.
	 * @param args What it was given.
	 */
	public static function enumOf(type:Dynamic, name:Dynamic, args:Dynamic):Dynamic {
		return hxscript.proxy.TypeProxy.createEnum(type, name, (args : Array<Dynamic>));
	}

	/** @return The name of the constructor a value was made with, or null when it is not an enum value. */
	public static function ctor(v:Dynamic):Dynamic {
		return (v is ICustomEnumValueType) ? (v : ICustomEnumValueType).constructor : hxscript.proxy.TypeProxy.enumConstructor(v);
	}

	/** @return What a constructor was given, positionally. */
	public static function params(v:Dynamic):Dynamic {
		return (v is ICustomEnumValueType) ? (v : ICustomEnumValueType).arguments : hxscript.proxy.TypeProxy.enumParameters(v);
	}

	/** @return Whether a value carries a named field, which is what an object pattern asks first. */
	public static function has(o:Dynamic, name:Dynamic):Bool {
		return o != null && hxscript.proxy.ReflectProxy.hasField(o, name);
	}

	/** @return Whether a value is an array of exactly this length, which an array pattern asks first. */
	public static function sized(o:Dynamic, n:Dynamic):Bool {
		return (o is Array) && (o : Array<Dynamic>).length == n;
	}

	/** @return What sits at an index or a key, which is the same spelling over an array and a map. */
	public static function index(o:Dynamic, i:Dynamic):Dynamic {
		if (o is haxe.Constraints.IMap)
			return (o : haxe.Constraints.IMap<Dynamic, Dynamic>).get(i);
		if (o is AbstractValue)
			return index(AbstractTools.underlying(o), i);
		if (o is Array)
			return (o : Array<Dynamic>)[toInt(i)];
		return o[i];
	}

	/**
	 * Stores at an index or a key.
	 *
	 * @return The value stored, because an assignment is an expression.
	 */
	public static function setIndex(o:Dynamic, i:Dynamic, v:Dynamic):Dynamic {
		if (o is haxe.Constraints.IMap) {
			(o : haxe.Constraints.IMap<Dynamic, Dynamic>).set(i, v);
			return v;
		}

		if (o is AbstractValue)
			return setIndex(AbstractTools.underlying(o), i, v);

		if (o is Array) {
			(o : Array<Dynamic>)[toInt(i)] = v;
			return v;
		}

		o[i] = v;
		return v;
	}

	/**
	 * @return An iterator over a value, by the rule the interpreter uses: an array or a range
	 *         directly, and anything else through its own `iterator` when it has one.
	 */
	public static function iterator(v:Dynamic):Dynamic {
		if (v is Array)
			return (v : Array<Dynamic>).iterator();

		if (v is IntIterator)
			return v;

		var own:Dynamic = get(v, 'iterator');
		return own != null ? Reflect.callMethod(v, own, []) : v;
	}

	/** @return A key-value iterator over a value, over maps and arrays alike. */
	public static function pairs(v:Dynamic):Dynamic {
		if (v is haxe.Constraints.IMap)
			return (v : haxe.Constraints.IMap<Dynamic, Dynamic>).keyValueIterator();

		if (v is Array)
			return (v : Array<Dynamic>).keyValueIterator();

		var own:Dynamic = get(v, 'keyValueIterator');
		return own != null ? Reflect.callMethod(v, own, []) : v;
	}

	/**
	 * @return Whether an iterator has anything left.
	 *
	 * Through `get` rather than `Reflect.field`, and that is the difference between working and not
	 * on a class a script declared. Its members live in the instance's own slots, which the standard
	 * reflection does not look in, so `hasNext` came back null and calling it said only that null is
	 * not a function. A `for` over an object with `hasNext` and `next` of its own, no `iterator`
	 * method at all, is ordinary Haxe and this is what makes it reach one.
	 */
	public static function step(it:Dynamic):Bool {
		return invoke(it, 'hasNext', []) == true;
	}

	/** @return An iterator's next value, reached the way `step` reaches its companion. */
	public static function take(it:Dynamic):Dynamic {
		return invoke(it, 'next', []);
	}

	/**
	 * Runs an arithmetic operator with an abstract on one side or both.
	 *
	 * The abstract's own `@:op` method wins when it declares one. A commutative operator asks the
	 * other operand too, because `1 + metres` is the same method as `metres + 1`. Failing both, the
	 * operands are opened to what they wrap and the operator runs on those.
	 *
	 * @param op The operator symbol.
	 * @param a The left operand.
	 * @param b The right operand.
	 * @return The result.
	 */
	static function arith(op:String, a:Dynamic, b:Dynamic):Dynamic {
		var m:String = AbstractTools.opMethod(a, op);
		if (m != null)
			return invoke(a, m, [b]);

		if (op == '+' || op == '*') {
			m = AbstractTools.opMethod(b, op);
			if (m != null)
				return invoke(b, m, [a]);
		}

		var l:Dynamic = AbstractTools.underlying(a);
		var r:Dynamic = AbstractTools.underlying(b);

		return switch (op) {
			case '+': add(l, r);
			case '-': sub(l, r);
			case '*': mul(l, r);
			case '/': div(l, r);
			default: mod(l, r);
		}
	}

	/**
	 * Orders or compares with an abstract on one side or both.
	 *
	 * Comparing the wrappers themselves would order them by identity, so an abstract declaring the
	 * operator runs its own method and one that does not is opened to what it wraps first.
	 *
	 * @param op The operator symbol.
	 * @param a The left operand.
	 * @param b The right operand.
	 * @return The comparison's result.
	 */
	static function cmp(op:String, a:Dynamic, b:Dynamic):Bool {
		var m:String = AbstractTools.opMethod(a, op);
		if (m != null)
			return invoke(a, m, [b]) == true;

		var l:Dynamic = AbstractTools.underlying(a);
		var r:Dynamic = AbstractTools.underlying(b);

		return switch (op) {
			case '<': l < r;
			case '<=': l <= r;
			case '>': l > r;
			case '>=': l >= r;
			case '!=': l != r;
			default: l == r;
		}
	}
}

/**
 * What one field access in the compiled code remembers about the last one it did.
 *
 * One of these per access site, filled into a module global before anything runs, exactly the way a
 * host static is. Holding the `Variable` rather than an index is what makes it correct without any
 * layout being agreed on: the slot an instance's field resolves to is made when the instance is
 * built and mutated in place from then on, so a site holding one is holding the field itself.
 *
 * It keeps the last receiver alive, which is the whole of its cost: one object per site that would
 * otherwise have been collected a little sooner.
 */
class Slot {
	/** The instance this was last resolved against, or null before the first time. */
	public var owner:Null<IScriptedInstance> = null;

	/** That instance's slot for this field. */
	public var held:Null<Variable> = null;

	/** The interpreter that owns the slot, for a write to go through its own checks. */
	public var interp:Null<hxscript.runtime.Interp> = null;

	/** What a write to it has to be, worked out once from the declaration. */
	public var wants:Wants = WChecked;

	/** Starts empty, which is a miss, which fills it. */
	public function new() {}
}

/**
 * What a slot's declaration wants of a value being written to it.
 *
 * Read once when a site resolves, so that a write only has to test the value rather than work out
 * what to test it against. `WChecked` is everything else, and means the interpreter's own cast has
 * to run, which is always correct and is what this exists to skip in the ordinary cases.
 */
enum abstract Wants(Int) {
	/** No annotation, so anything goes, exactly as an unchecked store does. */
	var WAnything;

	var WInt;
	var WFloat;
	var WBool;
	var WString;

	/** Anything with a cast behind it: an abstract, a class, a structure, a container. */
	var WChecked;
}
#end
