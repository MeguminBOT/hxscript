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
	 * @param a The left operand.
	 * @param b The right operand.
	 * @return `Int` when both are `Int` and the sum fits, `String` when either is a string,
	 *         otherwise `Float`.
	 */
	public static function add(a:Dynamic, b:Dynamic):Dynamic {
		if (a is Int && b is Int) {
			var wide:Float = (a : Float) + (b : Float);
			var narrow:Int = (a : Int) + (b : Int);
			return (narrow == wide) ? narrow : wide;
		}
		if (a is String || b is String)
			return Std.string(a) + Std.string(b);
		if (a is AbstractValue || b is AbstractValue)
			return arith('+', a, b);
		return (a : Float) + (b : Float);
	}

	/** @return The difference, keeping `Int` when both operands are `Int` and it fits. */
	public static function sub(a:Dynamic, b:Dynamic):Dynamic {
		if (a is Int && b is Int) {
			var wide:Float = (a : Float) - (b : Float);
			var narrow:Int = (a : Int) - (b : Int);
			return (narrow == wide) ? narrow : wide;
		}
		if (a is AbstractValue || b is AbstractValue)
			return arith('-', a, b);
		return (a : Float) - (b : Float);
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
	public static function regex(pattern:String, flags:String):Dynamic {
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
	public static function setField(o:Dynamic, name:String, v:Dynamic):Void {
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
	public static function get(o:Dynamic, name:String):Dynamic {
		if (o is ScriptedAbstractValue) {
			var boxed:ScriptedAbstractValue = cast o;
			if (boxed.owner != null)
				return boxed.owner.getField(boxed.boxed, name);
		}

		var through:Dynamic = hxscript.proxy.ReflectProxy.getProperty(o, name);

		/**
		 * A plain field read straight, when asking for the property answered with nothing.
		 *
		 * The two are one question on most values, and not on a generated bridge: its property hook
		 * answers for what the script declared as a property and says nothing about a plain field,
		 * so a field on a class extending a host type reads as null through the first and correctly
		 * through the second. Trying the property first keeps a getter winning where there is one.
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
	public static function invoke(o:Dynamic, name:String, args:Array<Dynamic>):Dynamic {
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
	static function mirror(self:Dynamic, owner:String):Dynamic {
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
	static function superSlot(self:Dynamic, owner:String, name:String):Dynamic {
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
	public static function superCall(self:Dynamic, owner:String, name:String, args:Array<Dynamic>):Dynamic {
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
	public static function superGet(self:Dynamic, owner:String, name:String):Dynamic {
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
	public static function superNew(self:Dynamic, owner:String, args:Array<Dynamic>):Void {
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

	/** Writes a named field of something a script declared, through its setter when it has one. */
	public static function set(o:Dynamic, name:String, v:Dynamic):Void {
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
	public static function send(o:Dynamic, name:String, args:Dynamic, extensions:Dynamic):Dynamic {
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
	public static function enumOf(type:Dynamic, name:String, args:Dynamic):Dynamic {
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
	public static function has(o:Dynamic, name:String):Bool {
		return o != null && hxscript.proxy.ReflectProxy.hasField(o, name);
	}

	/** @return Whether a value is an array of exactly this length, which an array pattern asks first. */
	public static function sized(o:Dynamic, n:Int):Bool {
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

		var own:Dynamic = Reflect.field(v, 'iterator');
		return own != null ? Reflect.callMethod(v, own, []) : v;
	}

	/** @return A key-value iterator over a value, over maps and arrays alike. */
	public static function pairs(v:Dynamic):Dynamic {
		if (v is haxe.Constraints.IMap)
			return (v : haxe.Constraints.IMap<Dynamic, Dynamic>).keyValueIterator();

		if (v is Array)
			return (v : Array<Dynamic>).keyValueIterator();

		var own:Dynamic = Reflect.field(v, 'keyValueIterator');
		return own != null ? Reflect.callMethod(v, own, []) : v;
	}

	/** @return Whether an iterator has anything left. */
	public static function step(it:Dynamic):Bool {
		return Reflect.callMethod(it, Reflect.field(it, 'hasNext'), []) == true;
	}

	/** @return An iterator's next value. */
	public static function take(it:Dynamic):Dynamic {
		return Reflect.callMethod(it, Reflect.field(it, 'next'), []);
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
#end
