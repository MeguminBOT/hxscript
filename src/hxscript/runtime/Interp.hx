/*
 * Copyright (C)2008-2017 Haxe Foundation
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

package hxscript.runtime;

import hxscript.syntax.Expr;
import hxscript.runtime.Reference;
import hxscript.runtime.Stop;
import hxscript.types.Defer;
import hxscript.error.InterpException;
import hxscript.error.ErrorKind;
import hxscript.runtime.ScriptStack;
import hxscript.types.*;
import haxe.PosInfos;
import haxe.Constraints.IMap;
import Type as HaxeType;
import Reflect as HaxeReflect;
import hxscript.proxy.TypeProxy.ICustomEnumValueType;
import hxscript.proxy.ReflectProxy as Reflect;
import hxscript.proxy.TypeProxy as Type;
import hxscript.proxy.StdProxy as Std;

using StringTools;
using hxscript.syntax.ExprTools;
using hxscript.types.TypeTools;
using hxscript.types.TypeCollection;
using hxscript.types.AbstractValue;

/**
 * The tree-walking interpreter: it evaluates parsed expressions against a scope of variables, imports, and
 * `using`s. One interpreter backs each `Script`, `Module`, and scripted type; nested scopes (blocks, function
 * calls) push and pop frames on an internal `ScriptStack`.
 */
class Interp {
	/** Active `using` extension classes, searched for extension methods on field access. */
	public var usings:Array<Dynamic>;

	/**
	 * Imported names to the type, value, or `Reference` they resolve to.
	 *
	 * A `Bindings` for the same reason `variables` is one: an instance stands on its class's table
	 * rather than being handed a copy of it.
	 */
	public var imports:Bindings;

	/**
	 * Top-level (module/script) variables.
	 *
	 * A `Bindings` rather than a bare `Map` so that a write to one is seen: compiled code keeps a
	 * host-bound name in a real typed static, which is only sound while every write reaches the copy,
	 * and writing this table directly is an ordinary thing for a host to do. Reads, writes,
	 * `exists`, `remove`, `clear` and iteration all behave as a map's do.
	 */
	public var variables:Bindings;

	/**
	 * The module path compiled code reaches this interpreter's names under, or null.
	 *
	 * Set when a compiled module binds against it. A write arrives holding the table rather than the
	 * module it belongs to, so the table's owner is where the module has to be recorded.
	 */
	public var globalsKey:Null<String> = null;

	/** The owning object (script, module, or instance) bound as context. */
	public var parent(default, set):Dynamic;

	function set_parent(val:Dynamic):Dynamic {
		parent = val;
		parentFields = new Map();

		if (val != null) {
			var names:Array<String> = null;
			var scripted:Dynamic = Type.getClass(val);

			if (scripted != null) {
				names = Type.getInstanceFields(scripted);
			} else {
				var native:Class<Dynamic> = HaxeType.getClass(val);
				if (native != null)
					names = HaxeType.getInstanceFields(native);
			}

			if (names == null) { // An anonymous structure
				for (field in Reflect.fields(val))
					parentFields.set(field, true);
			} else {
				for (field in names) {
					parentFields.set(field, true);

					if (field.length > 4) {
						var head:String = field.substr(0, 4);
						if (head == 'get_' || head == 'set_')
							parentFields.set(field.substr(4), true);
					}
				}
			}
		}

		return this.parent;
	}

	/** All of the instance fields the parent context has. If no parent is set, then this will be blank. */
	var parentFields:Map<String, Dynamic> = new Map();

	/** The world this interpreter resolves types against. */
	public var environment:Environment;

	/** Whether an assignment to an undeclared name defines a global (script mode) rather than erroring. */
	public var defineGlobals:Bool = false;

	/** Whether a `super(...)` call is currently permitted (only inside a constructor). */
	public var superConstructorAllowed:Bool = false;

	/** Pool of reusable local-variable maps, to avoid per-call allocation. */
	static var localsPool:Array<Map<String, Variable>> = [];

	/**
	 * Wildcard-import results for interpreters with no world, keyed by package path. A world keeps its
	 * own on the `Environment`, since its type index takes part in the resolution.
	 */
	static var globalImportCache:Map<String, Array<ImportEntry>> = new Map();

	/** The current frame's local variables. */
	var locals(get, never):Map<String, Variable>;

	/** Binary-operator implementations, keyed by operator token. */
	/** Maximum interpreter call depth before a stack-overflow guard trips. */
	public var callStackDepth:Int = 200;

	/** The interpreter's own call stack (frames with their locals). */
	var stack:ScriptStack;

	/**
	 * The innermost frame's scope, kept in step with `stack` rather than fetched from it.
	 */
	var frameLocals:Map<String, Variable> = null;

	/** Whether execution is currently inside a `try`. */
	var inTry:Bool;

	/** Metadata gathered for the declaration currently being processed. */
	var metas:Metadata = [];

	/** Pending deferred field resolutions (see `Resolve`). */
	var resolveFields:Array<Resolve> = [];

	/** Captured variables for the closure currently being built. */
	var captures:Map<String, Dynamic>;

	/** Whether `captures` currently holds anything. */
	var hasCaptures:Bool = false;

	/**
	 * Names shadowed in the current scope, held as two parallel arrays rather than one array of
	 * `{n, old}` pairs.
	 */
	var declaredNames:Array<String>;

	/** What each shadowed name held before, restored when the scope closes. */
	var declaredOld:Array<Variable>;

	/** The value returned by the currently-returning function. */
	var returnValue:Dynamic;

	/**
	 * Set by `return` and cleared by `exprReturn` once the value has been collected. `return`
	 * propagates by unwinding statement sequences on this flag rather than by throwing, because a
	 * thrown `Stop` costs microseconds on static targets and dominated every script call.
	 */
	var returning:Bool = false;

	/** Set by `break`; consumed by the innermost loop. Same reasoning as `returning`. */
	var breaking:Bool = false;

	/** Set by `continue`; consumed by the innermost loop. Same reasoning as `returning`. */
	var continuing:Bool = false;

	/** Whether any of `return` / `break` / `continue` is pending, so statement sequences must stop. */
	var unwinding(get, never):Bool;

	/** @return Whether a `return`, `break` or `continue` is pending. */
	inline function get_unwinding():Bool
		return returning || breaking || continuing;

	/** A unique sentinel standing for "no value" / `Void`. */
	static var void(default, never):Dynamic = {};

	/** The interpreter whose `private` access is currently being checked. */
	static var accessingInterp:Interp = null;

	/**
	 * Whether anything in the process declares a property with a `null` accessor.
	 */
	static var trackAccess:Bool = false;

	/** Turns on interpreter tracking if this accessor is one the access checks care about. */
	public static inline function noteAccessor(accessor:String):Void {
		if (accessor == 'null') {
			trackAccess = true;
		}
	}

	/**
	 * Counts how often evaluation crosses from one interpreter to another.
	 */
	#if hxscript_profile
	public static var interpSwitches:Int = 0;
	#end

	/**
	 * The package the running module declares, searched for a name nothing else in scope answers.
	 *
	 * Haxe resolves a type in the same package with no import at all, and this did not: `world/Sim.hx`
	 * naming `Player` from `world/Player.hx` resolved to nothing, and the failure surfaced at the
	 * first use rather than at the name. Every module of a packaged project had to import its own
	 * siblings, which is not a script anybody would write.
	 *
	 * Searched LAST, after imports, so an explicit import of another package's `Player` still wins:
	 * that is the order Haxe reads them in, and the import is the more deliberate of the two.
	 */
	public var packagePath:String = '';

	/** Names this package turned out not to hold, so a miss is not looked up again. */
	var packageMisses:Map<String, Bool> = new Map();

	/** The current source position, updated as expressions are evaluated. */
	var position:Position = {origin: 'hscript', line: 0};

	/** The current source origin. */
	var origin(get, never):String;

	/** The field name currently being accessed, used to disambiguate direct field vs property access. */
	var curAccess:String = '';

	/** Whether static initializers may defer (throw `Defer`) when a dependency isn't ready. */
	public var canDefer:Bool = false;

	/** Whether type initialization may be triggered during resolution. */
	public var canInit:Bool = false;

	/** The scripted class this interpreter runs on behalf of, used for `private` checks. */
	public var ownerClass:ScriptedClass = null;

	/**
	 * Creates an interpreter with its operator table but WITHOUT the `Config` defaults.
	 *
	 * @param environment The world to resolve types against, if any.
	 * @param parent The owning object bound as context, if any.
	 */
	public function new(?environment:Environment, ?parent:Dynamic) {
		this.environment = environment;
		this.parent = parent;

		stack = new ScriptStack();

		imports = new Bindings();
		usings = new Array();
		captures = new Map();
		variables = new Bindings();
		declaredNames = new Array();
		declaredOld = new Array();
	}

	/**
	 * Resets the interpreter's scope: optionally clears imports/usings/variables, seeds the global
	 * variables and imports from `Config`, and (re)installs `trace`.
	 *
	 * @param wipe Whether to clear existing imports, usings, and variables first.
	 * @param includeConfig Whether to seed the `Config` globals and imports.
	 */
	public function setDefaults(wipe:Bool = true, includeConfig:Bool = true) {
		if (wipe) {
			imports.clear();
			usings.resize(0);
			variables.clear();
		}

		if (includeConfig) {
			for (k => v in Config.globalVariables)
				variables.set(k, v);

			for (name => binding in Config.globalStatics) {
				if (Config.globalVariables.exists(name))
					continue;

				var owner:Int = binding.indexOf('::');
				if (owner < 0)
					continue;

				var cls:Dynamic = Type.resolveClass(binding.substr(0, owner));
				if (cls != null)
					variables.set(name, Reflect.field(cls, binding.substr(owner + 2)));
			}

			for (k => v in Config.globalImports)
				importPath(k.split('.'), v);
		}

		variables.set('trace', Reflect.makeVarArgs(function(el) {
			var inf = posInfos();
			var v = el.shift();
			if (el.length > 0)
				inf.customParams = el;
			haxe.Log.trace(Std.string(v), inf);
		}));
	}

	/**
	 * Discards the remembered wildcard-import results for world-less interpreters. Call this after
	 * changing `Config.blacklist` or `Config.typeProxy` once scripts have already run, since those
	 * decide what a package's types resolve to. A world's own cache is dropped when its type index is
	 * rebuilt.
	 */
	public static function clearImportCache():Void {
		globalImportCache.clear();
	}

	/** @return A short debug string with the parent and origin. */
	public function toString():String {
		return '(parent: $parent | origin: $origin)';
	}

	/** @return Haxe `PosInfos` for the current source position, for use with `trace`. */
	public function posInfos():PosInfos {
		return cast {fileName: position.origin, lineNumber: position.line};
	}

	/** @return The current frame's local variables. */
	inline function get_locals():Map<String, Variable> {
		return frameLocals;
	}

	/** @return The current source origin. */
	function get_origin():String {
		return position.origin;
	}

	/**
	 * Evaluates `a op b` where an operand is a wrapped abstract: through the abstract's `@:op` method when it
	 * declares one for this operator, otherwise on the values the operands box, which matches what an
	 * abstract with an implicit cast to its underlying type does in Haxe.
	 *
	 * @param op The operator symbol.
	 * @param a The left operand.
	 * @param b The right operand.
	 * @return The operator's result.
	 */
	function abstractArith(op:String, a:Dynamic, b:Dynamic):Dynamic {
		var m:String = AbstractTools.opMethod(a, op);
		if (m != null)
			return fcall(a, m, [b]);

		if (op == "+" || op == "*") {
			m = AbstractTools.opMethod(b, op);
			if (m != null)
				return fcall(b, m, [a]);
		}

		var l:Dynamic = AbstractTools.underlying(a);
		var r:Dynamic = AbstractTools.underlying(b);
		return switch (op) {
			case "+": numAdd(l, r);
			case "-": numSub(l, r);
			case "*": numMul(l, r);
			case "/": numDiv(l, r);
			default: numMod(l, r);
		}
	}

	/**
	 * Orders a wrapped abstract against another value, through the abstract's `@:op` method when it
	 * declares one for this operator and otherwise on the values the operands box. Comparing the
	 * wrappers themselves would order them by identity.
	 *
	 * @param op The operator symbol.
	 * @param a The left operand.
	 * @param b The right operand.
	 * @return The comparison's result.
	 */
	function abstractCmp(op:String, a:Dynamic, b:Dynamic):Bool {
		var m:String = AbstractTools.opMethod(a, op);
		if (m != null)
			return fcall(a, m, [b]) == true;

		var l:Dynamic = AbstractTools.underlying(a);
		var r:Dynamic = AbstractTools.underlying(b);
		return switch (op) {
			case ">": l > r;
			case "<": l < r;
			case ">=": l >= r;
			default: l <= r;
		}
	}

	/**
	 * Applies a unary operator to a wrapped abstract, through its `@:op` method when it declares one
	 * and otherwise to the value it boxes.
	 *
	 * @param op The operator symbol, prefixed with `u` to keep it apart from the binary operator
	 *           sharing the same symbol.
	 * @param v The operand.
	 * @return The operator's result.
	 */
	function abstractUnop(op:String, v:Dynamic):Dynamic {
		var m:String = AbstractTools.opMethod(v, op);
		if (m != null)
			return fcall(v, m, []);

		var u:Dynamic = AbstractTools.underlying(v);
		return switch (op) {
			case "u!": u != true;
			case "u~": ~(u : Int);
			default: (u is Int) ? -(u : Int) : -(u : Float);
		}
	}

	/**
	 * Reads an element from a wrapped abstract through its `@:arrayAccess` getter.
	 *
	 * @param a The abstract.
	 * @param index The element key.
	 * @return The element, or null when the abstract declares no getter.
	 */
	function abstractGetIndex(a:Dynamic, index:Dynamic):Dynamic {
		var m:String = AbstractTools.opMethod(a, "[]");
		return (m == null) ? null : fcall(a, m, [index]);
	}

	/**
	 * Writes an element into a wrapped abstract through its `@:arrayAccess` setter.
	 *
	 * @param a The abstract.
	 * @param index The element key.
	 * @param v The value to write.
	 * @return The written value.
	 */
	function abstractSetIndex(a:Dynamic, index:Dynamic, v:Dynamic):Dynamic {
		var m:String = AbstractTools.opMethod(a, "[]=");
		if (m != null)
			fcall(a, m, [index, v]);
		return v;
	}

	/**
	 * Compares a wrapped abstract for equality, through its `@:op(A == B)` method when it declares
	 * one and otherwise on the values the operands box. Comparing the wrappers themselves would
	 * compare identity, which reports equal values as different.
	 *
	 * @param a The left operand.
	 * @param b The right operand.
	 * @return Whether the operands are equal.
	 */
	function abstractEq(a:Dynamic, b:Dynamic):Bool {
		var m:String = AbstractTools.opMethod(a, "==");
		if (m != null)
			return fcall(a, m, [b]) == true;
		return AbstractTools.underlying(a) == AbstractTools.underlying(b);
	}

	/**
	 * Adds two values with Haxe semantics: String concatenation when either side is a String,
	 * otherwise numeric addition promoted like `numArith` (`Int + Int` stays `Int`).
	 *
	 * **`Int + Int` wraps, which is what Haxe does.** It used to widen to `Float` when the sum did
	 * not fit, on the reasoning that a script which never wrote `Int` should not have a value quietly
	 * corrupted. Two things were wrong with that. It is not what the same source compiled by Haxe
	 * produces, so a script moved between the two changes answer; and it was not even consistent
	 * here, because the widening turns on a `Float` comparison that eval answers differently from
	 * hxcpp, so the interpreter wrapped on one target and widened on another. A script has to get one
	 * answer, and the only defensible one is Haxe's.
	 *
	 * @param a The left operand.
	 * @param b The right operand.
	 * @return The concatenated string or the promoted numeric sum.
	 */
	inline function numAdd(a:Dynamic, b:Dynamic, widen:Bool = false):Dynamic {
		if (a is Int && b is Int) {
			/**
			 * `Std.int` rather than a cast, because `v is Int` is true of a whole `Float` on every
			 * dynamic target and a cast then leaves it a `Float` in an `Int` local. `+` does not mind;
			 * the bitwise test below does, and eval refuses it outright.
			 */
			var x:Int = Std.int(a);
			var y:Int = Std.int(b);
			var sum:Int = x + y;
			return (widen && overflowed(x, y, sum)) ? x * 1.0 + y * 1.0 : sum;
		}
		if (a is String || b is String)
			return Std.string(a) + Std.string(b);
		if (a is AbstractValue || b is AbstractValue)
			return abstractArith("+", a, b);
		return (a : Float) + (b : Float);
	}

	/**
	 * Whether adding or subtracting two `Int`s carried past the width.
	 *
	 * The sign test rather than a comparison against the same sum computed as a `Float`. The float
	 * form was what the widening used to turn on, and it does not mean the same thing on every
	 * target: eval keeps a `Float` apart from an `Int` and hxcpp reads a whole one back as an `Int`,
	 * so the interpreter wrapped on one and widened on the other for the same expression. This is
	 * three integer operations and reads the same everywhere.
	 *
	 * @param x The left operand.
	 * @param y The right operand, negated already when this was a subtraction.
	 * @param sum What the wrapped operation produced.
	 * @return Whether the true result is outside `Int`.
	 */
	inline function overflowed(x:Int, y:Int, sum:Int):Bool {
		return ((x ^ sum) & (y ^ sum)) < 0;
	}

	/**
	 * Subtracts with Haxe numeric promotion, wrapping on overflow for the reasons `numAdd` gives.
	 *
	 * @param a The left operand.
	 * @param b The right operand.
	 * @return `Int` when both operands are `Int`, otherwise `Float`.
	 */
	inline function numSub(a:Dynamic, b:Dynamic, widen:Bool = false):Dynamic {
		if (a is Int && b is Int) {
			/**
			 * `Std.int` rather than a cast, because `v is Int` is true of a whole `Float` on every
			 * dynamic target and a cast then leaves it a `Float` in an `Int` local. `+` does not mind;
			 * the bitwise test below does, and eval refuses it outright.
			 */
			var x:Int = Std.int(a);
			var y:Int = Std.int(b);
			var diff:Int = x - y;
			return (widen && overflowed(x, -y, diff)) ? x * 1.0 - y * 1.0 : diff;
		}
		if (a is AbstractValue || b is AbstractValue)
			return abstractArith("-", a, b);
		return (a : Float) - (b : Float);
	}

	/**
	 * Adds, asking what the operands were declared as only when the result carried.
	 *
	 * The annotations are what decide whether an overflow wraps or promotes, and reading them costs a
	 * lookup per operand. Doing that on every addition to answer a question that almost never comes
	 * up would be paying for the exception in the common case, so the wrapped result is computed
	 * first and the declarations are consulted only when it is not the whole answer.
	 *
	 * @param e1 The left operand's expression.
	 * @param e2 The right operand's expression.
	 * @return The sum.
	 */
	function addExpr(e1:Expr, e2:Expr):Dynamic {
		return addValues(expr(e1), expr(e2), e1, e2);
	}

	/**
	 * Adds two values already in hand, promoting a carry when either side is not known to be an `Int`.
	 *
	 * @param a The left value.
	 * @param b The right value.
	 * @param e1 The expression `a` came from, asked only on a carry.
	 * @param e2 The expression `b` came from, asked only on a carry.
	 * @return The sum.
	 */
	function addValues(a:Dynamic, b:Dynamic, e1:Expr, e2:Expr):Dynamic {
		if (a is Int && b is Int) {
			/**
			 * `Std.int` rather than a cast, because `v is Int` is true of a whole `Float` on every
			 * dynamic target and a cast then leaves it a `Float` in an `Int` local. `+` does not mind;
			 * the bitwise test below does, and eval refuses it outright.
			 */
			var x:Int = Std.int(a);
			var y:Int = Std.int(b);
			var sum:Int = x + y;

			if (!overflowed(x, y, sum))
				return sum;

			return (widensNumbers(e1) || widensNumbers(e2)) ? x * 1.0 + y * 1.0 : sum;
		}

		return numAdd(a, b);
	}

	/**
	 * Subtracts, on the same terms `addExpr` gives.
	 *
	 * @param e1 The left operand's expression.
	 * @param e2 The right operand's expression.
	 * @return The difference.
	 */
	function subExpr(e1:Expr, e2:Expr):Dynamic {
		return subValues(expr(e1), expr(e2), e1, e2);
	}

	/**
	 * Subtracts two values already in hand, on the same terms `addValues` gives.
	 *
	 * @param a The left value.
	 * @param b The right value.
	 * @param e1 The expression `a` came from, asked only on a carry.
	 * @param e2 The expression `b` came from, asked only on a carry.
	 * @return The difference.
	 */
	function subValues(a:Dynamic, b:Dynamic, e1:Expr, e2:Expr):Dynamic {
		if (a is Int && b is Int) {
			/**
			 * `Std.int` rather than a cast, because `v is Int` is true of a whole `Float` on every
			 * dynamic target and a cast then leaves it a `Float` in an `Int` local. `+` does not mind;
			 * the bitwise test below does, and eval refuses it outright.
			 */
			var x:Int = Std.int(a);
			var y:Int = Std.int(b);
			var diff:Int = x - y;

			if (!overflowed(x, -y, diff))
				return diff;

			return (widensNumbers(e1) || widensNumbers(e2)) ? x * 1.0 - y * 1.0 : diff;
		}

		return numSub(a, b);
	}

	/**
	 * Whether `Int` arithmetic on this expression's value should widen rather than wrap.
	 *
	 * Wrapping is what Haxe does and is therefore the default, but only for values that really are
	 * `Int`. **On hxcpp and HashLink a whole `Float` in a `Dynamic` reads back as an `Int`**, so a
	 * `var t:Float` accumulating past the width is indistinguishable from an `Int` overflowing, and
	 * wrapping it would quietly destroy a total. Nothing about the value can tell the two apart, so
	 * the annotation is asked instead, and only when an operation has actually carried: the common
	 * path never reaches this.
	 *
	 * `Dynamic` widens for a different reason, and it is also Haxe's: arithmetic on a `Dynamic` is
	 * dynamic arithmetic, which promotes. An unannotated local wraps, because Haxe infers `Int` for
	 * one initialised from an `Int`.
	 *
	 * @param e The operand's expression.
	 * @return Whether it was written with a type that promotes.
	 */
	function widensNumbers(e:Expr):Bool {
		return switch (ExprTools.expr(e)) {
			case EParent(inner) | ECheckType(inner, _): widensNumbers(inner);
			case EIdent(id): promoting(locals.get(id));
			case EField(owner, f, _): fieldWidens(owner, f);
			case _: false;
		}
	}

	/**
	 * Whether a field read should promote an addition that carried past `Int`.
	 *
	 * **A whole `Float` is an `Int` as far as hxcpp is concerned.** `2.0` held as `Dynamic` answers
	 * true to `is Int` and `TInt` to `Type.typeof`, and so does the same value read straight out of a
	 * field declared `Float`. So nothing about the value says which it is, and the declared type is
	 * the only thing that can.
	 *
	 * The interpreter has that type for its own slots and does not have it for a field of a class the
	 * host compiled: Haxe keeps no field types at runtime, and the build's type index records what a
	 * type is rather than what its fields hold. So a field of a host object is genuinely unknown, and
	 * the question is what to assume about one.
	 *
	 * **Unknown promotes.** `sink.total = sink.total + i` against a `Float` field is what a script
	 * accumulating a total looks like, and wrapping it produced `-1455759936` where every compiled
	 * mode produced `1999999000000`: a wrong number, silently, in the shape this is most used in.
	 * Assuming the other way costs a host field really declared `Int` its wraparound at 2^31, which is
	 * a shape scripts reach for deliberately and almost always through bitwise operators, and those
	 * never come here.
	 *
	 * @param owner The receiver expression.
	 * @param f The field being read.
	 * @return Whether to compute in `Float`.
	 */
	function fieldWidens(owner:Expr, f:String):Bool {
		var slot:Null<Variable> = null;

		switch (ExprTools.expr(owner)) {
			case EIdent('this'):
				/**
				 * Its own slots are the locals here. A name missing from them is a field of the host
				 * class this one extends, which is as unknown as any other host field.
				 */
				slot = locals.get(f);

			case EIdent(id):
				/**
				 * Read rather than evaluated, so asking cannot run anything twice. A receiver this
				 * cannot read without evaluating falls through to the unknown answer.
				 */
				var l:Variable = locals.get(id);
				if (l == null)
					return true;

				slot = slotOf(l.r, f);

			case _:
				return true;
		}

		/** Nothing declared it, so nothing says it is an `Int`, so it promotes. */
		return slot == null ? true : promoting(slot);
	}

	/**
	 * @param receiver A value a field is being read from.
	 * @param f The field's name.
	 * @return Its slot when the receiver is a scripted instance carrying one, or null when the
	 *         receiver is something the host compiled and nothing at runtime says what its fields hold.
	 */
	function slotOf(receiver:Dynamic, f:String):Null<Variable> {
		if (!(receiver is IScriptedInstance))
			return null;

		var slots:Map<String, Variable> = @:privateAccess (cast receiver : IScriptedInstance).__vars;
		return slots == null ? null : slots.get(f);
	}

	/**
	 * @param l The slot, or null when the name is not one.
	 * @return Whether its declared type is one that promotes `Int` arithmetic.
	 */
	function promoting(l:Null<Variable>):Bool {
		if (l == null || l.t == null)
			return false;

		return switch (l.t) {
			case CTPath(path, _): path.length == 1 && (path[0] == 'Float' || path[0] == 'Dynamic');
			case _: false;
		}
	}

	/**
	 * Multiplies with Haxe numeric promotion.
	 *
	 * @param a The left operand.
	 * @param b The right operand.
	 * @return `Int` when both operands are `Int`, otherwise `Float`.
	 */
	inline function numMul(a:Dynamic, b:Dynamic):Dynamic {
		if (a is Int && b is Int)
			return (a : Int) * (b : Int);
		if (a is AbstractValue || b is AbstractValue)
			return abstractArith("*", a, b);
		return (a : Float) * (b : Float);
	}

	/**
	 * Modulo with Haxe numeric promotion.
	 *
	 * @param a The left operand.
	 * @param b The right operand.
	 * @return `Int` when both operands are `Int`, otherwise `Float`.
	 */
	inline function numMod(a:Dynamic, b:Dynamic):Dynamic {
		if (a is Int && b is Int)
			return (a : Int) % (b : Int);
		if (a is AbstractValue || b is AbstractValue)
			return abstractArith("%", a, b);
		return (a : Float) % (b : Float);
	}

	/**
	 * Divides. Division is always `Float` in Haxe, even for two `Int`s.
	 *
	 * @param a The dividend.
	 * @param b The divisor.
	 * @return The `Float` quotient.
	 */
	inline function numDiv(a:Dynamic, b:Dynamic):Dynamic {
		if (a is AbstractValue || b is AbstractValue)
			return abstractArith("/", a, b);
		return (a : Float) / (b : Float);
	}

	/**
	 * Builds the binary- and assignment-operator tables.
	 *
	 * Arithmetic routes through the `num*` helpers so results keep Haxe's numeric type (an `Int`
	 * operation stays an `Int`) instead of decaying to `Float` through untyped `Dynamic` math.
	 */
	/**
	 * Evaluates a binary operation.
	 *
	 * **Dispatched on length and first character, not on the token.** This used to be a
	 * `Map<String, Expr->Expr->Dynamic>` built per interpreter, so every operator a script evaluated
	 * cost a string hash, a null test and a call through a closure field, and every interpreter
	 * allocated thirty-eight closures and a map before running anything. A scripted class gets its own
	 * interpreter, so that was thirty-eight per class as well.
	 *
	 * Switching on the token itself is worse than the map it replaces: hxcpp lays a string switch out
	 * as a chain of comparisons, so `<` in a loop condition was paying for every operator declared
	 * ahead of it. Both switches here are over integers, which it lays out as jump tables, and no
	 * operator is compared against a string at all.
	 *
	 * @param op The operator token.
	 * @param e1 Its left side.
	 * @param e2 Its right side.
	 * @return The result.
	 */
	function binop(op:String, e1:Expr, e2:Expr):Dynamic {
		var c:Int = StringTools.fastCodeAt(op, 0);

		switch (op.length) {
			case 1:
				switch (c) {
					case '+'.code:
						return addExpr(e1, e2);
					case '-'.code:
						return subExpr(e1, e2);
					case '*'.code:
						return numMul(expr(e1), expr(e2));
					case '/'.code:
						return numDiv(expr(e1), expr(e2));
					case '%'.code:
						return numMod(expr(e1), expr(e2));
					case '<'.code:
						var a:Dynamic = expr(e1), b:Dynamic = expr(e2);
						return (a is AbstractValue || b is AbstractValue) ? abstractCmp("<", a, b) : a < b;
					case '>'.code:
						var a:Dynamic = expr(e1), b:Dynamic = expr(e2);
						return (a is AbstractValue || b is AbstractValue) ? abstractCmp(">", a, b) : a > b;
					case '='.code:
						return assign(e1, e2);
					case '&'.code:
						return (expr(e1) : Int) & (expr(e2) : Int);
					case '|'.code:
						return (expr(e1) : Int) | (expr(e2) : Int);
					case '^'.code:
						return (expr(e1) : Int) ^ (expr(e2) : Int);
				}

			case 2:
				var d:Int = StringTools.fastCodeAt(op, 1);

				switch (c) {
					case '='.code:
						if (d == '='.code) return eqValues(expr(e1), expr(e2));
					case '!'.code:
						if (d == '='.code) return !eqValues(expr(e1), expr(e2));
					case '<'.code:
						if (d == '='.code) {
							var a:Dynamic = expr(e1), b:Dynamic = expr(e2);
							return (a is AbstractValue || b is AbstractValue) ? abstractCmp("<=", a, b) : a <= b;
						}
						if (d == '<'.code) return (expr(e1) : Int) << (expr(e2) : Int);
					case '>'.code:
						if (d == '='.code) {
							var a:Dynamic = expr(e1), b:Dynamic = expr(e2);
							return (a is AbstractValue || b is AbstractValue) ? abstractCmp(">=", a, b) : a >= b;
						}
						if (d == '>'.code) return (expr(e1) : Int) >> (expr(e2) : Int);
					case '&'.code:
						if (d == '&'.code) return expr(e1) == true && expr(e2) == true;
					case '|'.code:
						if (d == '|'.code) return expr(e1) == true || expr(e2) == true;
					case 'i'.code:
						if (d == 's'.code) return #if (haxe_ver >= 4.2) Std.isOfType #else Std.is #end (expr(e1),
							expr(e2));
					case '?'.code:
						if (d == '?'.code) return expr(e1) ?? expr(e2);
				}

				if (d == '='.code)
					return evalAssignOp(op, e1, e2);

			case 3:
				if (c == '.'.code)
					return new IntIterator(expr(e1), expr(e2));

				/**
				 * `>>>` is the only three-character operator that is not a compound assignment, and it
				 * shares its first two characters with `>>=`. The last one is what separates them.
				 */
				if (StringTools.fastCodeAt(op, 2) != '='.code) {
					if (c == '>'.code)
						return (expr(e1) : Int) >>> (expr(e2) : Int);

					return error(EInvalidOp(op));
				}

				return evalAssignOp(op, e1, e2);

			case 4:
				return evalAssignOp(op, e1, e2);
		}

		return error(EInvalidOp(op));
	}

	/**
	 * Combines the current and right-hand values of a compound assignment.
	 *
	 * The target's own declaration decides an overflow here, which is the same rule `addExpr` applies
	 * and the same reason: `t += n` on a `var t:Float` is a total being accumulated, and nothing about
	 * the values says so once a whole `Float` reads back as an `Int`.
	 *
	 * Asking whether it widens costs a slot lookup and sometimes a reach into the receiver, and only
	 * an addition that carried past `Int` cares about the answer. So the operands come in as
	 * expressions and the question is asked where it is needed rather than on the way in: measured on
	 * `s += o.a`, asking every time cost 15%.
	 *
	 * @param op The compound operator token.
	 * @param v1 The current value.
	 * @param v2 The right-hand value.
	 * @param e1 The target expression, for deciding a carry.
	 * @param e2 The right-hand expression, for the same.
	 * @return The combined value.
	 */
	function combine(op:String, v1:Dynamic, v2:Dynamic, e1:Expr, e2:Expr):Dynamic {
		switch (op) {
			case "+=":
				return addValues(v1, v2, e1, e2);
			case "-=":
				return subValues(v1, v2, e1, e2);
			case "*=":
				return numMul(v1, v2);
			case "/=":
				return numDiv(v1, v2);
			case "%=":
				return numMod(v1, v2);
			case "&=":
				return (v1 : Int) & (v2 : Int);
			case "|=":
				return (v1 : Int) | (v2 : Int);
			case "^=":
				return (v1 : Int) ^ (v2 : Int);
			case "<<=":
				return (v1 : Int) << (v2 : Int);
			case ">>=":
				return (v1 : Int) >> (v2 : Int);
			case ">>>=":
				return (v1 : Int) >>> (v2 : Int);
			case "??=":
				return v1 ?? v2;
			default:
				return error(EInvalidOp(op));
		}
	}

	/**
	 * Assigns to a top-level name: writes through a property mirror, sets an existing variable, or (in
	 * global-define mode at top level) defines a new one; otherwise errors.
	 *
	 * @param name The variable name.
	 * @param v The value to assign (unwrapped if it is a boxed abstract).
	 * @return The assigned value.
	 */
	function setVar(name:String, v:Dynamic):Dynamic {
		if (AbstractTools.isAbstract(v))
			v = v.__a;

		var iv = imports.get(name);
		if (iv != null) {
			if (iv is Reference) {
				switch (iv) {
					case RProperty(t, f):
						if (curAccess == f) {
							Reflect.setField(t, f, v);
						} else {
							Reflect.setProperty(t, f, v);
						}
						return Reflect.field(t, f);
					default:
				}
			}

			error(ECustom('Invalid assign'));
		}

		if (variables.exists(name)) {
			var vv = variables.get(name);
			if (vv is Reference) {
				switch (vv) {
					case RProperty(t, f):
						if (curAccess == f) {
							Reflect.setField(t, f, v);
						} else {
							Reflect.setProperty(t, f, v);
						}
						return Reflect.field(t, f);
					default:
				}
			}

			variables.set(name, v);
		} else {
			if (parent != null && parentFields.exists(name)) {
				if (getMeta(':bypassAccessor') != null)
					Reflect.setField(parent, name, v);
				else
					Reflect.setProperty(parent, name, v);

				return v;
			}

			if (stack.length <= 1 && defineGlobals) {
				variables.set(name, v);
				return v;
			}

			error(EUnknownVariable(name));
		}

		return v;
	}

	/**
	 * Evaluates `e1 = e2`, targeting a local, a top-level variable, a field, or a map/array element.
	 *
	 * @param e1 The assignment target.
	 * @param e2 The value expression.
	 * @return The assigned value.
	 */
	function assign(e1:Expr, e2:Expr):Dynamic {
		var v = expr(e2);
		switch (ExprTools.expr(e1)) {
			case EIdent(id):
				var l:Variable = locals.get(id);
				if (l != null) {
					writeLocal(l, id, v);
				} else {
					setVar(id, v);
				}
			case EField(e, f, _):
				v = set(expr(e), f, v);
			case EArray(e, index):
				var arr:Dynamic = expr(e);
				var index:Dynamic = expr(index);
				if (isMap(arr)) {
					setMapValue(arr, index, v);
				} else if (arr is AbstractValue) {
					abstractSetIndex(arr, index, v);
				} else {
					arr[index] = v;
				}

			default:
				error(EInvalidOp("="));
		}
		return v;
	}

	/**
	 * Evaluates a compound assignment `e1 op= e2` against a local, variable, field, or element.
	 *
	 * @param op The compound operator token.
	 * @param e1 The assignment target.
	 * @param e2 The right-hand expression.
	 * @return The new value.
	 */
	function evalAssignOp(op:String, e1:Expr, e2:Expr):Dynamic {
		var v;

		switch (ExprTools.expr(e1)) {
			case EIdent(id):
				var l:Variable = hasCaptures ? null : locals.get(id);
				if (l != null) {
					v = combine(op, readLocal(l, id), expr(e2), e1, e2);
					writeLocal(l, id, v);
				} else {
					v = combine(op, expr(e1), expr(e2), e1, e2);

					if (locals.exists(id)) {
						setLocal(id, v);
					} else {
						setVar(id, v);
					}
				}
			case EField(e, f, _):
				var obj = expr(e);
				v = combine(op, get(obj, f), expr(e2), e1, e2);
				v = set(obj, f, v);
			case EArray(e, index):
				var arr:Dynamic = expr(e);
				var index:Dynamic = expr(index);
				if (isMap(arr)) {
					v = combine(op, getMapValue(arr, index), expr(e2), e1, e2);
					setMapValue(arr, index, v);
				} else if (arr is AbstractValue) {
					v = combine(op, abstractGetIndex(arr, index), expr(e2), e1, e2);
					abstractSetIndex(arr, index, v);
				} else {
					v = combine(op, arr[index], expr(e2), e1, e2);
					arr[index] = v;
				}
			default:
				return error(EInvalidOp(op));
		}
		return v;
	}

	/**
	 * Reads a local/field value, honouring its property getter and access rules (`null`/`never`/`get`/
	 * `dynamic`/`default`).
	 *
	 * @param id The variable or field name.
	 * @param map The slot map to read from; defaults to the current locals.
	 * @return The value, or null if the slot doesn't exist.
	 */
	public function getLocal(id:String, ?map:Map<String, Variable>):Dynamic {
		var varMap:Map<String, Variable> = (map ?? locals);
		var l:Variable = varMap.get(id);
		if (l == null)
			return null;

		return readLocal(l, id);
	}

	/**
	 * Reads an already-resolved slot, honouring its property accessor.
	 *
	 * @param l The slot.
	 * @param id Its name, for the accessor call and for error reporting.
	 * @return The value.
	 */
	function readLocal(l:Variable, id:String):Dynamic {
		if (l.get == null)
			return (l.a != null) ? l.a : l.r;

		switch (l.get) {
			case 'null':
				if (accessingInterp != this)
					throw 'This expression cannot be accessed for reading';
				return (l.a ?? l.r);
			case 'never':
				throw 'This expression cannot be accessed for reading';
				return null;
			case 'get' | 'dynamic' if (getMeta(':bypassAccessor') != null):
				return (l.a ?? l.r);
			case 'get' | 'dynamic':
				if (curAccess == id)
					return l.r;

				var hasLocal:Bool = locals.exists('get_$id');
				if (hasLocal || variables.exists('get_$id')) {
					var prevAccess:String = curAccess;
					curAccess = id;
					var v = Reflect.callMethod(this, hasLocal ? locals.get('get_$id').r : variables.get('get_$id'), []);
					curAccess = prevAccess;
					return v;
				}

				error(ECustom('Method get_$id required by property $id is missing'));
				return null;
			case 'default' | null:
				return (l.a ?? l.r);
			default:
				throw 'Invalid property accessor';
				return null;
		}
	}

	/**
	 * Writes a value into a variable slot: checks the value against the slot's declared type, then
	 * keeps the abstract box in step with the stored value.
	 *
	 * A slot holding an abstract keeps the wrapper in `a` and the boxed value in `r`, and reads
	 * prefer `a`, so a write that left `a` alone would keep handing back the replaced value.
	 *
	 * @param l The slot to write.
	 * @param v The new value.
	 * @return The assigned value.
	 */
	inline function store(l:Variable, v:Dynamic):Dynamic {
		if (l.t != null)
			v = enforce(l, v);

		if (l.a != null)
			return storeBoxed(l, v);

		l.r = v;
		return v;
	}

	/**
	 * Writes into a slot holding an abstract, replacing or clearing its box.
	 *
	 * @param l The slot to write.
	 * @param v The new value.
	 * @return The assigned value.
	 */
	function storeBoxed(l:Variable, v:Dynamic):Dynamic {
		if (v is AbstractValue) {
			l.a = v;
			l.r = v.__a;
		} else {
			l.a = null;
			l.r = v;
		}
		return v;
	}

	/**
	 * Writes a local/field value, honouring its property setter, `final`, and method-rebind rules.
	 *
	 * @param id The variable or field name.
	 * @param v The value to store.
	 * @param map The slot map to write to; defaults to the current locals.
	 * @return The stored value, or null if the slot doesn't exist.
	 * @throws String On a `final` reassignment or a non-`dynamic` method rebind.
	 */
	public function setLocal(id:String, v:Dynamic, ?map:Map<String, Variable>):Dynamic {
		var map:Map<String, Variable> = (map ?? locals);
		var l:Variable = map.get(id);
		if (l == null)
			return null;

		return writeLocal(l, id, v);
	}

	/**
	 * Writes an already-resolved slot, honouring finality, method rebinding and its accessor.
	 *
	 * The write-side counterpart of `readLocal`, split out for the same two reasons: a caller holding
	 * the slot should not look it up a second time, and a plain variable, which is nearly every
	 * write, should not fall through a switch over five string constants to reach `store`.
	 *
	 * @param l The slot.
	 * @param id Its name, for the accessor call and for error reporting.
	 * @param v The value to write.
	 * @return The stored value.
	 */
	function writeLocal(l:Variable, id:String, v:Dynamic):Dynamic {
		if (l.isFinal)
			throw 'Cannot assign to final';

		if (l.access != null && Reflect.isFunction(l.r) && !l.access.contains(ADynamic))
			throw 'Cannot rebind method $id: please use \'dynamic\' before method declaration';

		if (l.set == null)
			return store(l, v);

		switch (l.set) {
			case 'null':
				if (accessingInterp != this)
					throw 'This expression cannot be accessed for writing';
				return store(l, v);
			case 'never':
				throw 'This expression cannot be accessed for writing';
				return null;
			case 'set' | 'dynamic' if (getMeta(':bypassAccessor') != null):
				return store(l, v);
			case 'set' | 'dynamic':
				if (curAccess == id)
					return store(l, v);

				var hasLocal:Bool = locals.exists('set_$id');
				if (hasLocal || variables.exists('set_$id')) {
					var prevAccess:String = curAccess;
					curAccess = id;
					Reflect.callMethod(this, hasLocal ? locals.get('set_$id').r : variables.get('set_$id'), [v]);
					curAccess = prevAccess;
					return l.r;
				}

				error(ECustom('Method set_$id required by property $id is missing'));
				return null;
			case 'default' | null:
				return store(l, v);
			default:
				error(ECustom('Invalid property accessor ${l.set}'));
				return null;
		}
	}

	/**
	 * Evaluates `++`/`--` on a local, variable, field, or element.
	 *
	 * @param e The operand expression.
	 * @param prefix True for the prefix form (`++x`), false for the postfix form (`x++`).
	 * @param delta `+1` to increment or `-1` to decrement.
	 * @return The prefix or postfix result value, matching Haxe semantics.
	 */
	function increment(e:Expr, prefix:Bool, delta:Int):Dynamic {
		position = e.pos;
		var e = e.e;

		switch (e) {
			case EIdent(id):
				var l:Variable = locals.get(id);
				if (l == null) {
					var v:Dynamic = resolve(id);
					var next:Dynamic = numAdd(v, delta);
					setVar(id, next);
					return prefix ? next : v;
				}

				var v:Dynamic = readLocal(l, id);
				if (prefix) {
					v = numAdd(v, delta);
					writeLocal(l, id, v);
				} else {
					writeLocal(l, id, numAdd(v, delta));
				}
				return v;
			case EField(e, f, _):
				var obj = expr(e);
				var v:Dynamic = get(obj, f);
				if (prefix) {
					v = numAdd(v, delta);
					set(obj, f, v);
				} else
					set(obj, f, numAdd(v, delta));
				return v;
			case EArray(e, index):
				var arr:Dynamic = expr(e);
				var index:Dynamic = expr(index);
				if (isMap(arr)) {
					var v = getMapValue(arr, index);
					if (prefix) {
						v = numAdd(v, delta);
						setMapValue(arr, index, v);
					} else {
						setMapValue(arr, index, numAdd(v, delta));
					}
					return v;
				} else {
					var v = arr[index];
					if (prefix) {
						v = numAdd(v, delta);
						arr[index] = v;
					} else
						arr[index] = numAdd(v, delta);
					return v;
				}
			default:
				return error(EInvalidOp((delta > 0) ? "++" : "--"));
		}
	}

	/**
	 * Runs a module's top-level program: processes its `using` and `import` declarations (type
	 * declarations themselves are initialized separately). Errors are wrapped as `InterpException`s.
	 *
	 * @param decls The module's declarations.
	 * @param path The module path (used for the stack frame).
	 */
	public function executeModule(decls:Array<ModuleDecl>, path:String):Void {
		try {
			if (stack.length == 0)
				pushStack(SModule(path));

			for (decl in decls) {
				position = decl.pos;

				switch (decl.d) {
					default:
					case DPackage(path):
						packagePath = path.join('.');
					case DUsing(path):
						usingType(path);
					case DImport(path, mode):
						importPath(path, mode);
				}
			}
		} catch (e:haxe.Exception) {
			if (e is InterpException) {
				throw e;
			} else {
				pushStack();

				throw new InterpException(stack, e.message);
			}
		}
	}

	/**
	 * Runs a full expression program from a clean stack. Errors are wrapped as `InterpException`s.
	 *
	 * @param expr The program to evaluate.
	 * @return The program's result value.
	 */
	public function execute(expr:Expr):Dynamic {
		try {
			stack.stack.resize(0);
			frameLocals = null;
			declaredNames = new Array();
			declaredOld = new Array();

			return exprReturn(expr);
		} catch (e:haxe.Exception) {
			if (e is InterpException) {
				throw e;
			} else {
				pushStack();

				throw new InterpException(stack, e.message);
			}
		}

		return null;
	}

	/**
	 * Evaluates an expression and absorbs a `return` (yielding the returned value); a stray `break`/
	 * `continue` is an error.
	 *
	 * @param e The expression to evaluate.
	 * @param t An optional expected type for the value.
	 * @return The expression's value, or the returned value if it returned.
	 */
	function exprReturn(e, ?t:CType):Dynamic {
		var v:Dynamic = expr(e, t);
		if (returning) {
			returning = false;
			v = returnValue;
			returnValue = null;
		} else if (breaking) {
			breaking = false;
			throw "Invalid break";
		} else if (continuing) {
			continuing = false;
			throw "Invalid continue";
		}
		return v;
	}

	/**
	 * Pushes a new call frame, stamping the previous frame with the current source position first.
	 *
	 * @param item The descriptor of the frame being entered; null just refreshes the top frame's position.
	 * @param locals The frame's local map; defaults to a fresh duplicate of the current scope.
	 */
	function pushStack(?item:StackItem, ?locals:Map<String, Variable>) {
		var last:StackFrame = stack.stack[0];

		if (last != null) {
			last.item = switch (last.item) {
				case SFilePos(inner, _, _): SFilePos(inner, position.origin, position.line, position.column);
				default: SFilePos(last.item, position.origin, position.line, position.column);
			}
		}
		if (item != null) {
			var frame:StackFrame = {locals: locals ?? duplicate(), item: item};
			stack.stack.unshift(frame);
			frameLocals = frame.locals;

			if (stack.length > callStackDepth)
				error(ECustom('StackFrame overflow'));
		}
	}

	/**
	 * Pops the top call frame, optionally returning its local map to the pool for reuse.
	 *
	 * @param put Whether to recycle the popped frame's locals into the pool.
	 * @return The popped frame.
	 */
	function shiftStack(put:Bool = true):StackFrame {
		var item:StackFrame = stack.stack.shift();

		var top:StackFrame = stack.stack[0];
		frameLocals = (top == null) ? null : top.locals;

		if (put)
			localsPool.push(item.locals);

		return item;
	}

	/**
	 * Gets a local map from the pool (or allocates one), optionally pre-filled from an existing map.
	 *
	 * @param h A map to copy entries from, if any.
	 * @return A ready-to-use local map.
	 */
	inline function duplicate(?h:Map<String, Variable>):Map<String, Variable> {
		if (localsPool.length > 0) {
			var locals:Map<String, Variable> = localsPool.pop();

			locals.clear();

			if (h != null) {
				for (k => v in h)
					locals.set(k, v);
			}

			return locals;
		} else {
			return (h?.copy() ?? new Map());
		}
	}

	/**
	 * Unwinds variable declarations made since a scope began, restoring shadowed bindings.
	 *
	 * @param old The `declared` length to roll back to (the scope's starting mark).
	 */
	function restore(old:Int) {
		while (declaredNames.length > old) {
			var n:String = declaredNames.pop();
			var previous:Variable = declaredOld.pop();

			if (previous == null) {
				locals.remove(n);
			} else {
				locals.set(n, previous);
			}
		}
	}

	/**
	 * Raises an interpreter error with the current stack.
	 *
	 * @param e The error to raise.
	 * @param rethrow Whether to rethrow (preserving the native trace) rather than throw fresh.
	 * @return Never returns normally; typed `Dynamic` so it can stand in an expression.
	 */
	function error(e:ErrorKind, rethrow = false):Dynamic {
		pushStack();

		var exception:InterpException = new InterpException(stack, hxscript.error.Printer.errorToString(e), null, e);
		if (rethrow)
			this.rethrow(exception)
		else
			throw exception;

		return null;
	}

	/**
	 * Rethrows a value preserving its original stack (via the HashLink API where available).
	 *
	 * @param e The value to rethrow.
	 */
	inline function rethrow(e:Dynamic) {
		#if hl
		hl.Api.rethrow(e);
		#else
		throw e;
		#end
	}

	/**
	 * Constructs an enum value by constructor index.
	 *
	 * @param t The scripted or native enum.
	 * @param i The constructor index.
	 * @param args Constructor arguments, if any.
	 * @return The enum value.
	 * @throws String If construction fails.
	 */
	function createEnum(t:Dynamic, i:Int, ?args:Array<Dynamic>):Dynamic {
		try {
			return Type.createEnumIndex(t, i, args);
		} catch (e:haxe.Exception) {
			throw 'Failed to construct enum of type ${Type.getEnumName(t)}';
		}
	}

	/**
	 * Constructs an enum-abstract value by constructor index.
	 *
	 * @param t The enum-abstract implementation class.
	 * @param i The constructor index.
	 * @return The wrapped value.
	 * @throws String If construction fails.
	 */
	function createAbstractEnum(t:Class<AbstractValue>, i:Int):AbstractValue {
		try {
			return AbstractTools.createEnumIndex(t, i);
		} catch (e:haxe.Exception) {
			var t:Dynamic = t;
			throw 'Failed to construct enum of type ${t.impl}';
		}
	}

	/**
	 * Value equality for `==`/`!=`. Enum values compare structurally (constructor + arguments), the
	 * way Haxe does; everything else uses native `==`.
	 *
	 * @param a The first value.
	 * @param b The second value.
	 * @return True if equal.
	 */
	inline function eqValues(a:Dynamic, b:Dynamic):Bool {
		if (a is ICustomEnumValueType && b is ICustomEnumValueType)
			return cast(a, ICustomEnumValueType).eq(b);

		if (a is AbstractValue || b is AbstractValue)
			return abstractEq(a, b);
		return a == b;
	}

	/**
	 * Returns the live instance of a scripted enum. A `Reference.REnumValue` can outlive the enum
	 * instance it captured (e.g. a module reloaded under it), leaving `values`/`decl` null; the
	 * environment always maps the enum's path to the current one, so swap to that when the held
	 * instance looks dead. Non-scripted and healthy instances pass straight through.
	 *
	 * @param t The (possibly stale) enum.
	 * @return The live enum, or `t` unchanged when it is healthy or not scripted.
	 */
	function liveEnum(t:Dynamic):Dynamic {
		if (t is ScriptedEnum) {
			var e:ScriptedEnum = cast t;
			if ((!e.initialized || e.values == null) && environment != null) {
				var live:Dynamic = environment.resolve(e.path);
				if (live != null && live is ScriptedEnum)
					return live;
			}
		}
		return t;
	}

	/**
	 * Whether a caught value satisfies a `catch` clause's declared type. Thrown values aren't
	 * wrapped in `haxe.Exception` here, so `Dynamic`/`Any`/`Exception` (and any unresolvable
	 * type) are treated as catch-all; a resolvable path is matched with `Std.isOfType`.
	 *
	 * @param v The caught value.
	 * @param t The catch clause's declared type, or null for an untyped catch.
	 * @return True if `v` should be caught by this clause.
	 */
	function catchMatches(v:Dynamic, t:Null<CType>):Bool {
		if (t == null)
			return true;
		switch (t) {
			case CTPath(path, _):
				var name:String = path[path.length - 1];
				if (name == 'Dynamic' || name == 'Any' || name == 'Exception')
					return true;
				var type:Dynamic = null;
				try {
					type = ScriptedTools.resolveType(t, null, this);
				} catch (_:Dynamic) {}
				if (type == null)
					return true;
				return Std.isOfType(v, type);
			default:
				return true;
		}
	}

	/**
	 * Materializes a bare enum constructor `Reference.REnumValue`. Re-resolves the enum to its live
	 * instance first (a cached import can outlive a reloaded module), so a bare `Foo` builds
	 * against the current type exactly like qualified `Enum.Foo`. A parameterized constructor
	 * yields a varargs builder; a parameterless one yields the value itself so it matches `case Foo`.
	 *
	 * @param t The enum the constructor belongs to.
	 * @param i The constructor index.
	 * @return The value, or a var-args builder for a parameterized constructor.
	 */
	function resolveEnumValue(t:Dynamic, i:Int):Dynamic {
		t = liveEnum(t);
		if (enumConstructorHasArgs(t, i))
			return Reflect.makeVarArgs(function(params:Array<Dynamic>) return createEnum(t, i, params));
		return createEnum(t, i);
	}

	/**
	 * Whether enum `t`'s constructor at index `i` takes parameters. Scripted enums answer from their
	 * declaration; native enums are probed by whether a parameterless value of that constructor exists.
	 *
	 * @param t The enum.
	 * @param i The constructor index.
	 * @return True if that constructor is parameterized.
	 */
	function enumConstructorHasArgs(t:Dynamic, i:Int):Bool {
		if (t is ScriptedEnum)
			return cast(t, ScriptedEnum).constructorHasArgs(i);

		var constructs:Array<String> = HaxeType.getEnumConstructs(t);
		if (constructs == null || i < 0 || i >= constructs.length)
			return false;

		var name:String = constructs[i];
		for (v in HaxeType.allEnums(t))
			if (HaxeType.enumConstructor(v) == name)
				return false;
		return true;
	}

	/**
	 * Materializes a stored value: a `Reference` (property, enum constructor, or enum-abstract constant)
	 * is turned into its live value; anything else is returned unchanged.
	 *
	 * @param v The stored value or mirror.
	 * @return The materialized value.
	 */
	inline function resolveMirror(v:Dynamic):Dynamic {
		if (v is Reference) {
			switch (v) {
				default:
					return v;
				case RProperty(t, f):
					if (curAccess == f) {
						return Reflect.field(t, f);
					} else {
						return Reflect.getProperty(t, f);
					}
				case REnumValue(t, i):
					return resolveEnumValue(t, i);
				case RAbstractEnumValue(t, i):
					return createAbstractEnum(t, i);
			}
		} else {
			return v;
		}
	}

	/**
	 * Materializes a mirror standing for a constant, and answers nothing for one that is not.
	 *
	 * The import table holds a `Reference` wherever a name stands for something that is not a plain
	 * value, so anything reading that table to find out what a name means gets the mirror unless it
	 * asks through here. A compiler is the caller that needs it: a name it reads straight is answered
	 * with the mirror itself.
	 *
	 * **A property is deliberately not answered.** An enum's constructor and an enum abstract's
	 * constant are fixed, so taking one and keeping it is right. A property has storage because
	 * something may write it, and a compiler that took one here would read it once and never see the
	 * write; that name has to be compiled as a read of its owner instead.
	 *
	 * @param v The stored value or mirror.
	 * @return The value, unchanged when it was never a mirror, or null for a mirror of a property.
	 */
	public function constantMirror(v:Dynamic):Dynamic {
		if (!(v is Reference))
			return v;

		return switch (cast(v, Reference)) {
			case REnumValue(t, i): resolveEnumValue(t, i);
			case RAbstractEnumValue(t, i): createAbstractEnum(t, i);
			case _: null;
		}
	}

	/**
	 * Resolves a bare identifier to a value, checking imports first, then top-level variables, and
	 * materializing any mirror it finds.
	 *
	 * @param id The identifier.
	 * @return The resolved value.
	 * @throws InterpException If the identifier is unknown.
	 */
	public function resolve(id:String):Dynamic {
		var v:Dynamic = imports.get(id);
		if (v != null) {
			return resolveMirror(v);
		}

		if (imports.exists(id)) {
			error(ECustom('Module $id does not define type $id'));
		}

		v = variables.get(id);
		if (v != null) {
			return resolveMirror(v);
		}

		if (parent != null && parentFields.exists(id)) {
			if (getMeta(':bypassAccessor') != null)
				return Reflect.field(parent, id);
			else
				return Reflect.getProperty(parent, id);
		}

		var near:Dynamic = packageType(id);
		if (near != null) {
			return resolveMirror(near);
		}

		if (!variables.exists(id)) {
			error(EUnknownVariable(id));
		}

		return null;
	}

	/**
	 * Resolves a name against the running module's own package, and binds what it finds.
	 *
	 * The last question asked about a name, and only about one that could be a type. What it finds is
	 * imported under that name, so the search happens once per name per interpreter and every later
	 * read is the map lookup it would have been had the module written the import itself.
	 *
	 * @param id The name.
	 * @return The type the package holds under that name, or null when it holds none.
	 */
	public function packageType(id:String):Dynamic {
		if (packagePath.length == 0 || id == null || id.length == 0)
			return null;
		if (!id.isTypeIdentifier() || packageMisses.exists(id))
			return null;

		var found:Dynamic = TypeTools.resolve(packagePath + '.' + id, environment);

		if (found == null) {
			packageMisses.set(id, true);
			return null;
		}

		importType(id, found);
		return imports.get(id);
	}

	/**
	 * Whether a bare identifier can be resolved (is a known import or variable).
	 *
	 * @param id The identifier.
	 * @return True if `resolve` would succeed.
	 */
	public function isResolvable(id:String):Bool {
		return ((imports.exists(id) || variables.exists(id)) || (parent != null && parentFields.exists(id))
			|| packageType(id) != null);
	}

	/**
	 * Imports a resolved type under a name, dispatching by kind: a typedef binds its alias, an enum
	 * also exposes its constructors, an enum abstract exposes its constants, and classes/enums bind
	 * directly. Initializes a not-yet-initialized scripted type first when allowed.
	 *
	 * @param name The name to bind the import under.
	 * @param t The resolved type; null is ignored.
	 * @param enumValueImport Whether to also expose an enum's constructors unqualified.
	 * @throws String If `t` is not an importable kind.
	 */
	function importType(name:String, t:Dynamic, enumValueImport:Bool = true) {
		if (t == null)
			return;

		if (canInit && t is IScriptedType && t.module != null && !t.initializing && !t.initialized && !t.failed)
			t.module.startType(environment, t);

		if (t is ScriptedTypedef) {
			var td:ScriptedTypedef = cast t;

			if (td.alias != null)
				imports.set(name, td.alias);
			else if (td.structural)
				imports.set(name, td);
		} else if (t is ScriptedEnum) {
			imports.set(name, t);

			if (enumValueImport)
				importEnumValues(t);
		} else if (t is IScriptedType) {
			imports.set(name, t);
		} else if (TypeTools.isEnumType(t)) {
			/**
			 * Ahead of the class branch, because on hxcpp that branch would take this. A class and an
			 * enum are one runtime object there, so `t is Class` is true of an enum too and every
			 * import of one bound the type and left its constructors unbound: `import haxe.ds.Option;`
			 * then `None` read whatever else was in scope under that name.
			 */
			imports.set(name, t);

			if (enumValueImport)
				importEnumValues(t);
		} else if (t is Class) {
			if (Type.getSuperClass(t) == AbstractValue && t.isEnum) {
				for (i => construct in AbstractTools.getEnumConstructs(t))
					imports.set(construct, RAbstractEnumValue(t, i));
				imports.set(name, t);
				return;
			}

			imports.set(name, t);
		} else if (t != null && Type.getClassName(cast t) != null) {
			imports.set(name, t);
		} else {
			throw 'Invalid import type $t';
		}
	}

	/**
	 * Exposes an enum's constructors unqualified, each as a `Reference.REnumValue`.
	 *
	 * @param t The enum whose constructors to import.
	 */
	function importEnumValues(t:Dynamic) {
		for (i => v in Type.getEnumConstructs(t))
			imports.set(v, REnumValue(t, i));
	}

	/**
	 * Processes an `import` declaration: a wildcard import brings in a package's types, and a plain or
	 * aliased import brings in a single type (or one of its static fields / enum constructors).
	 *
	 * @param path The dotted import path.
	 * @param mode Whether it is a normal, aliased, or wildcard import.
	 */
	function importPath(path:Array<String>, mode:ImportMode):Void {
		if (mode == IAll) {
			var fullPath:String = path.join('.');

			var cache:Map<String,
				Array<ImportEntry>> = (environment != null ? environment.importCache : globalImportCache);
			var entries:Array<ImportEntry> = cache.get(fullPath);

			if (entries == null) {
				var types:Array<TypeInfo> = TypeTools.listTypesEx(fullPath, true,
					[TypeCollection.main, environment?.types]);

				if (types == null)
					return;

				entries = [];
				for (type in types) {
					var main:String = type.module.substr(type.module.lastIndexOf('.') + 1);
					if (main != type.name && type.name != 'Main')
						continue;
					if (type.name.indexOf('_Impl_') > -1 || type.name.startsWith('AbstractValue_'))
						continue;

					entries.push({
						name: type.name,
						type: (type.kind == 'abstract' ? AbstractTools.resolve(type.compilePath()) : type.resolve(environment))
					});
				}

				cache.set(fullPath, entries);
			}

			imports.set(fullPath.substr(fullPath.lastIndexOf('.') + 1), null);
			for (entry in entries)
				importType(entry.name, entry.type, false);

			return;
		}

		var fields:Array<String> = [];

		var i:Int = path.length;
		while (i-- > 0) {
			var fullPath:String = path.slice(0, i + 1).join('.');

			if (path[i].isTypeIdentifier()) {
				var types:Array<TypeInfo> = TypeTools.listTypesEx(fullPath, [TypeCollection.main, environment?.types]);

				if (types != null) {
					var field:String = fields.shift();
					if (fields.length > 0)
						error(EUnexpected(field));

					if (field != null) {
						var t:Dynamic = null;
						for (type in types) {
							if (type.name == path[i])
								t = type.resolve(environment);

							if (type.name == '${path[i]}_Fields_') {
								var t = type.resolve(environment);

								if (!Type.getClassFields(t).contains(field))
									continue;

								switch (mode) {
									case IAsName(alias):
										return imports.set(alias, RProperty(t, field));
									default:
										return imports.set(field, RProperty(t, field));
								}
							}
						}

						if (t is Class || t is ScriptedClass) {
							if (!Type.getClassFields(t).contains(field))
								error(ECustom('Module ${path[i]} does not define field $field'));

							switch (mode) {
								case IAsName(alias):
									return imports.set(alias, RProperty(t, field));
								default:
									return imports.set(field, RProperty(t, field));
							}
						} else if (t is Enum || t is ScriptedEnum) {
							var i:Int = Type.getEnumConstructs(t).indexOf(field);

							if (i >= 0) {
								switch (mode) {
									case IAsName(alias):
										return imports.set(alias, REnumValue(t, i));
									default:
										return imports.set(field, REnumValue(t, i));
								}
							} else {
								error(EUnknownField(path[i], field));
							}
						} else {
							error(ECustom('Module ${path[i]} does not define type $field'));
						}
					}

					switch (mode) {
						case IAsName(alias):
							for (type in types) {
								if (type.name == path[i]) {
									importType(alias, type.resolve(environment));

									return;
								}
							}

							error(ECustom('Module ${path[i]} does not define ${path[i]}'));

						default:
							imports.set(path[i], null);

							for (type in types) {
								if (type.name.indexOf('_Impl_') > -1)
									continue;

								if (type.name.endsWith('_Fields_')) {
									var t = type.resolve(environment);

									if (imports.get(path[i]) == null)
										imports.set(path[i], t);

									for (field in Reflect.fields(t))
										imports.set(field, RProperty(t, field));

									continue;
								}

								importType(type.name,
									type.kind == 'abstract' ? AbstractTools.resolve(type.compilePath()) : type.resolve(environment));
							}
					}

					return;
				}
			}

			fields.unshift(path[i]);
		}

		error(EUnknownType(path.join('.')));
	}

	/**
	 * Processes a `using` declaration: registers the named class as an extension provider (and imports
	 * it) so its static methods become callable as instance methods.
	 *
	 * @param path The dotted path of the class to use.
	 */
	function usingType(path:Array<String>):Void {
		var tf:String = null;

		var i:Int = path.length;
		while (i-- > 0) {
			var fullPath:String = path.slice(0, i + 1).join('.');

			if (path[i].isTypeIdentifier()) {
				var types:Array<TypeInfo> = TypeTools.listTypesEx(fullPath, [TypeCollection.main, environment?.types]);

				if (types != null && types.length > 0) {
					for (type in types) {
						var t = type.resolve();
						if ((t is Class || t is ScriptedClass) && !usings.contains(t))
							usings.push(t);
						imports.set(type.name, t);
					}

					return;
				}

				if (tf != null)
					error(ECustom('Module ${path[i]} does not define type $tf'));
			}

			if (tf != null)
				break;
			tf = path[i];
		}

		error(EUnknownType(path.join('.')));
	}

	/**
	 * Adds metadata to a declaration, unless it is already there. Re-running a declaration (a reloaded
	 * script, a module started twice) would otherwise accumulate duplicates of the same entry.
	 *
	 * @param decl The declaration to annotate.
	 * @param entry The metadata entry.
	 */
	function attachMeta(decl:ModuleDecl, entry:MetadataEntry):Void {
		var meta:Metadata = switch (decl.d) {
			case DClass(m) | DInterface(m): m.meta;
			case DAbstract(m): m.meta;
			case DEnum(m): m.meta;
			case DTypedef(m): m.meta;
			default: null;
		}
		if (meta == null)
			return;

		for (m in meta)
			if (m.name == entry.name)
				return;

		meta.push(entry);
	}

	/**
	 * Initializes an inline (nested) type declaration and binds it under its name.
	 *
	 * @param decl The declaration to start.
	 */
	public function startDecl(decl:ModuleDecl) {
		position = decl.pos;

		switch (decl.d) {
			case DClass(m):
				if (variables.exists(m.name))
					return;

				var cls = new ScriptedClass(m);
				cls.init(environment, this);
				cls.initialized = true;

				imports.set(m.name, cls);

				for (meta in m.meta) {
					if (meta.name != ':enumAbstract')
						continue;
					for (field in m.fields)
						if (field.access.contains(AStatic))
							imports.set(field.name, Reference.RProperty(cls, field.name));
					break;
				}

			case DInterface(m):
				if (variables.exists(m.name))
					return;

				var iface = new ScriptedInterface(m);
				iface.init(environment, this);
				iface.initialized = true;

				imports.set(m.name, iface);

			case DEnum(m):
				if (variables.exists(m.name))
					return;

				var en = new ScriptedEnum(m);
				en.init(environment, this);
				en.initialized = true;

				imports.set(m.name, en);

				for (i => v in en.constructNames())
					imports.set(v, Reference.REnumValue(en, i));

			case DAbstract(m):
				if (variables.exists(m.name))
					return;

				var ab = new ScriptedAbstract(m);
				ab.init(environment, this);
				ab.initialized = true;

				imports.set(m.name, ab);

			case DTypedef(m):
				if (variables.exists(m.name))
					return;

				var td = new ScriptedTypedef(m);
				td.init(environment, this);
				td.initialized = true;

				if (td.alias != null)
					imports.set(m.name, td.alias);
				else if (td.structural)
					imports.set(m.name, td);

			default:
		}
	}

	/**
	 * Builds a callable closure for a function declaration: it captures the enclosing scope, fills in
	 * optional/rest parameters, pushes a call frame per invocation, and casts arguments and the result
	 * to their declared types. A named function is additionally bound in its scope (as a self-recursive
	 * local, or a global in define-globals mode).
	 *
	 * @param name The function name, or null for an anonymous function.
	 * @param params The parameter list.
	 * @param fexpr The body expression.
	 * @param ret The declared return type, if any.
	 * @param id The runtime slot id for an anonymous function, used in stack traces.
	 * @param functionLocals A fixed locals map to run in (for methods), instead of capturing the current scope.
	 * @param su Whether a `super(...)` call is permitted in the body (constructors).
	 * @return The callable closure.
	 */
	public function buildFunction(?name:String, params:Array<Argument>, fexpr:Expr, ?ret:CType, ?id:Int,
			?functionLocals:Map<String, Variable>, su:Bool = false) {
		var capturedLocals = (functionLocals == null ? duplicate(locals) : null);

		/**
		 * The frame this closure runs in, built once and reused.
		 */
		var frame:Map<String, Variable> = null;

		/** Whether an invocation is currently running in `frame`, so a re-entrant one takes a copy. */
		var frameBusy:Bool = false;

		var hasOpt = false, hasRest = false, minParams = 0;

		for (p in params) {
			if (p.opt) {
				hasOpt = true;
			} else if (p.rest) {
				hasRest = true;
			} else {
				minParams++;
			}
		}

		var f = Reflect.makeVarArgs(function(args:Array<Dynamic>) {
			superConstructorAllowed = su;

			if ((args?.length ?? 0) != params.length) {
				if (args.length < minParams) {
					var str = "Invalid number of parameters. Got " + args.length + ", required " + minParams;
					if (name != null)
						str += " for function '" + name + "'";
					error(ECustom(str));
				}
				var args2 = [];
				var extraParams = args.length - minParams;
				var pos = 0;
				for (p in params) {
					if (p.rest) {
						if (pos < args.length)
							args2.push(args[pos++]);
					} else if (p.opt) {
						if (extraParams > 0) {
							args2.push(args[pos++]);
							extraParams--;
						} else {
							args2.push(p.value == null ? null : expr(p.value));
						}
					} else
						args2.push(args[pos++]);
				}
				if (hasRest)
					args2 = args2.concat(args.slice(params.length));
				args = args2;
			}
			var old = declaredNames.length;

			var reused:Bool = false;
			var scope:Map<String, Variable>;

			if (functionLocals != null) {
				scope = functionLocals;
			} else if (frameBusy) {
				scope = duplicate(capturedLocals);
			} else {
				frame ??= duplicate(capturedLocals);
				frameBusy = true;
				reused = true;
				scope = frame;
			}

			var recycle:Bool = functionLocals == null && !reused;

			pushStack(name == null ? SLocalFunction(id) : SMethod(position.origin, name), scope);

			for (i in 0...params.length) {
				var name:String = params[i].name;

				declaredNames.push(name);
				declaredOld.push(locals.get(name));

				if (i == params.length - 1 && hasRest) {
					locals.set(name, {ref: args.slice(params.length - 1)});
				} else {
					locals.set(name, {ref: tryCast(args[i], params[i].t), t: params[i].t});
				}
			}

			var r = null;
			if (inTry) {
				try {
					r = tryCast(exprReturn(fexpr), ret);
				} catch (e:Dynamic) {
					restore(old);

					if (reused)
						frameBusy = false;

					shiftStack(recycle);
					superConstructorAllowed = false;
					#if neko
					neko.Lib.rethrow(e);
					#else
					throw e;
					#end
				}
			} else {
				r = tryCast(exprReturn(fexpr), ret);
			}

			restore(old);

			if (reused)
				frameBusy = false;

			shiftStack(recycle);
			superConstructorAllowed = false;

			return r;
		});

		if (name != null) {
			if (stack.length > 1) {
				declaredNames.push(name);
				declaredOld.push(locals.get(name));
				var ref:Variable = {ref: f};
				locals.set(name, ref);
				capturedLocals.set(name, ref);
			} else {
				if (defineGlobals) {
					variables.set(name, f);
				} else {
					locals.set(name, {ref: f});
				}
			}
		}

		return f;
	}

	/**
	 * Evaluates an array literal, or an array/map comprehension when the single element is a `for`.
	 *
	 * @param arr The literal's elements, or the single comprehension expression.
	 * @param t The declared type, used to pick the map implementation for an empty `Map` literal.
	 * @return The array or map.
	 */
	function evalArrayDecl(arr:Array<Expr>, t:Null<CType>):Dynamic {
		var compr:Dynamic = null;

		var ranComprehension:Bool = false;

		var exprCompr:(e:Expr, ?inFor:Bool) -> Dynamic = null;

		/**
		 * Accumulates one element of a comprehension, choosing an array or a map from whether the
		 * element is a `=>` pair.
		 *
		 * @param e The element expression.
		 */
		function forExpr(e:Expr) {
			var v:Dynamic = exprCompr(e, true);

			if (v is ExprDef) {
				switch (v) {
					default:
					case EBinop('=>', e1, e2):
						var key:Dynamic = expr(e1);

						if (key is String) {
							compr ??= new haxe.ds.StringMap();
						} else if (key is Int) {
							compr ??= new haxe.ds.IntMap();
						} else if (HaxeReflect.isEnumValue(key)) {
							compr ??= new haxe.ds.EnumValueMap();
						} else {
							compr ??= new haxe.ds.ObjectMap();
						}

						compr.set(key, expr(e2));
						return;
				}
			}

			if (v != Interp.void && !unwinding) {
				compr ??= new Array();

				compr.push(v);
			}
		}

		exprCompr = function(e:Expr, inFor:Bool = false):Dynamic {
			return switch (ExprTools.expr(e)) {
				case EBlock(e):
					var v = Interp.void;

					for (e in e) {
						v = exprCompr(e, inFor);
						if (unwinding)
							break;
					}

					v;

				case EParent(e):
					exprCompr(e, inFor);

				case EFor(n, it, e):
					ranComprehension = true;
					forLoop(n, it, forExpr.bind(e));

					Interp.void;

				case EForGen(it, e):
					ranComprehension = true;
					ExprTools.getKeyIterator(it, function(vk, vv, it) {
						if (vk == null) {
							position = it.pos;
							error(ECustom('Invalid for expression'));
							return;
						}

						forKeyValueLoop(vk, vv, it, forExpr.bind(e));
					});

					Interp.void;

				default:
					expr(e, inFor, inFor);
			}
		}

		if (arr.length > 0 && ExprTools.expr(arr[0]).match(EBinop("=>", _))) {
			var keys = [];
			var values = [];
			for (e in arr) {
				switch (ExprTools.expr(e)) {
					case EBinop("=>", eKey, eValue):
						keys.push(expr(eKey));
						values.push(expr(eValue));
					default:
						position = e.pos;
						error(ECustom("Invalid map key=>value expression"));
				}
			}
			return makeMap(keys, values);
		} else {
			if (arr.length == 1) {
				exprCompr(arr[0]);

				if (compr != null)
					return compr;
			}

			switch (t) {
				case CTPath(path, params):
					var fullPath:String = path.join('.');

					if (fullPath == 'Map') {
						if (params == null || params.length < 2)
							error(ECustom('Not enough type parameters for Map'));
						else if (params.length > 2)
							error(ECustom('Too many type parameters for Map'));

						switch (params[0]) {
							case CTAnon(_):
								return new haxe.ds.ObjectMap<Dynamic, Dynamic>();
							case CTPath(path, _):
								var fullPath:String = path.join('.');

								if (fullPath == 'String') {
									return new Map<String, Dynamic>();
								} else if (fullPath == 'Int') {
									return new Map<Int, Dynamic>();
								} else {
									var type:TypeInfo = null;
									var r = (TypeTools.resolve(fullPath, environment) ?? imports.get(fullPath));
									if (r is Class) {
										type = TypeCollection.main.fromCompilePath(Type.getClassName(r))[0];
									} else if (r == null) {
										error(EUnknownType(fullPath));
									}

									if (/*Reflect.isEnumValue(r)*/ false) {
										return new haxe.ds.EnumValueMap<Dynamic, Dynamic>();
									} else if (type?.kind == 'class') {
										return new haxe.ds.ObjectMap<Dynamic, Dynamic>();
									}
								}
							default:
						}

						var p = new Printer();
						error(ECustom('Map of type <${p.typeToString(params[0])}, ${p.typeToString(params[1])}> is not accepted'));
					} else if (isResolvable(fullPath)) {
						var t:Dynamic = resolve(fullPath);

						if (t is haxe.ds.IntMap
							|| t is haxe.ds.StringMap
							|| t is haxe.ds.ObjectMap
							|| t is haxe.ds.EnumValueMap)
							return Type.createInstance(t, []);
					}
				default:
			}

			var a = new Array();

			if (!ranComprehension) {
				for (e in arr)
					a.push(expr(e));
			}

			return a;
		}
	}

	/**
	 * Evaluates a `switch`, including capture variables, extractors, guards and `|` alternatives.
	 *
	 * @param e The value being matched.
	 * @param cases Its cases.
	 * @param def Its default branch, if any.
	 * @param void Whether the result is going to be discarded.
	 * @param mapCompr Whether this sits inside a map comprehension.
	 * @return The value of the branch that matched, or null when none did.
	 */
	function evalSwitch(e:Expr, cases:Array<{values:Array<Expr>, expr:Expr, ?guard:Expr}>, def:Null<Expr>, void:Bool,
			mapCompr:Bool):Dynamic {
		var hasCapture:Bool = false;

		/**
		 * Sets `hasCapture` if a sub-expression of a pattern binds a name rather than matching a value.
		 *
		 * @param e The sub-expression to inspect.
		 */
		function iterCapture(e:Expr) {
			switch (e.e) {
				case EIdent('_') | EIdent(_.isTypeIdentifier() => false):
					hasCapture = true;

				case EIdent(id):

				case EVar(_):
					hasCapture = true;

				default:
					e.iter(iterCapture);
			}
		}

		/**
		 * Whether a pattern binds anything, which decides if a `case` needs its own scope.
		 *
		 * @param e The pattern.
		 * @return Whether it captures.
		 */
		function checkCapture(e:Expr) {
			hasCapture = false;
			e.iter(iterCapture);
			return hasCapture;
		}

		/**
		 * Matches one `case` pattern against a value, binding any captures it declares.
		 *
		 * A lower-case identifier is a capture and an upper-case one is a type or constructor, which is
		 * why an unresolved upper-case name is an error rather than a silent catch-all.
		 *
		 * @param e The pattern.
		 * @param match The value being matched.
		 * @param deep Whether to descend into sub-patterns.
		 * @return Whether the pattern matched.
		 */
		function testCase(e:Expr, match:Dynamic, deep:Bool = true) {
			return switch (e.e) {
				case EIdent(id):
					if (imports.exists(id) || variables.exists(id))
						return matchValues(resolve(id), match);

					/**
					 * A constructor of whatever is being matched, which is how Haxe reads a bare
					 * upper-case name in a pattern: the subject's type is what the pattern is checked
					 * against, so `case None:` needs no import and names nothing that has to resolve.
					 * Only reached once the name has failed to resolve as anything else, and only
					 * when the subject really is an enum value, so a mistyped name still says so.
					 */
					if (id != '_' && id.isTypeIdentifier() && constructorOf(match) != null)
						return constructorOf(match) == id;

					if (id != '_' && id.isTypeIdentifier())
						throw 'Unknown identifier: $id, pattern variables must be lower-case or with \'var \' prefix';

					captures.set(id, match);
					hasCaptures = true;
					return true;

				case EField(ve, f, m):
					testCase(ve, match);
					matchValues(get(expr(ve), f, m), match);

				case EVar(id):
					captures.set(id, match);
					hasCaptures = true;
					true;

				case EConst(_):
					(expr(e) == match);

				case EParent(exr):
					testCase(exr, match);

				case EBinop('=>', e1, e2):
					captures.set('_', match);
					hasCaptures = true;

					var a:Dynamic = expr(e1);
					testCase(e2, a);

					matchValues(a, expr(e2));

				case EBinop('|', e1, e2):
					testCase(e1, match);
					testCase(e2, match);
					(matchValues(match, expr(e1)) || matchValues(match, expr(e2)));

				case EObject(f):
					if (!Reflect.isObject(match))
						return false;
					for (f in f) {
						if (!Reflect.hasField(match, f.name) || !testCase(f.e, Reflect.field(match, f.name)))
							return false;
					}
					true;

				case EArrayDecl(a):
					if (!(match is Array))
						return false;
					if (a.length != match.length)
						return false;
					for (i => e in a) {
						if (!testCase(e, match[i]))
							return false;
					}
					true;

				case ECall(ce, params):
					/**
					 * The same rule as a bare name, for a constructor that takes parameters. The old
					 * path had to evaluate the constructor and build a value with nulls in it just to
					 * ask what it was called, which cannot be done for a name that resolves to
					 * nothing. Reading the name off the subject asks the question directly.
					 */
					var named:Null<String> = patternName(ce);

					if (named != null && constructorOf(match) != null) {
						if (constructorOf(match) != named)
							return false;

						var held:Array<Dynamic> = Type.enumParameters(match);

						for (i => param in params) {
							if (!testCase(param, i < held.length ? held[i] : null))
								return false;
						}

						return true;
					}

					if (checkCapture(ce)) {
						testCase(ce, match);
					} else {
						var v = expr(ce);

						var ev = Reflect.callMethod(null, v, [for (_ in params) null]);
						if (Type.getEnum(ev) == Type.getEnum(match)
							&& Type.enumConstructor(ev) == Type.enumConstructor(match)) {
							var matchParams = Type.enumParameters(match);

							for (i => param in params) {
								if (!testCase(param, matchParams[i]))
									return false;
							}
						} else {
							return false;
						}
					}
					true;

				default:
					error(EUnrecognizedPattern(e));
			}
		}

		var val:Dynamic = expr(e);
		var match = false;
		for (c in cases) {
			for (exr in c.values) {
				captures.clear();
				hasCaptures = false;

				match = testCase(exr, val);

				captures.remove('_');

				if (match && c.guard != null && !expr(c.guard))
					match = false;

				if (match)
					break;
			}
			if (match) {
				val = expr(c.expr, void, mapCompr);
				break;
			}
		}

		if (!match)
			val = def == null ? null : expr(def, void, mapCompr);

		captures.clear();
		hasCaptures = false;

		return val;
	}

	/**
	 * Evaluates a `try`/`catch`, kept out of `expr` deliberately.
	 */
	@:noinline function evalTry(e:Expr, n:String, t:Null<CType>, ecatch:Expr,
			extra:Array<{v:String, t:Null<CType>, expr:Expr}>):Dynamic {
		var old = declaredNames.length;
		var oldTry = inTry;
		try {
			inTry = true;
			var v:Dynamic = expr(e);
			restore(old);
			inTry = oldTry;
			return v;
		} catch (err:Stop) {
			inTry = oldTry;
			throw err;
		} catch (err:Dynamic) {
			restore(old);
			inTry = oldTry;
			var raw:Dynamic = (err is haxe.ValueException) ? (cast(err, haxe.ValueException)).value : err;
			/**
			 * Runs one `catch` clause with its exception variable bound, restoring the scope afterwards.
			 *
			 * Clauses are tried in declaration order (typed multi-catch); the first whose declared type
			 * accepts the value runs, otherwise the error is rethrown.
			 *
			 * @param cn The exception variable's name.
			 * @param ce The clause body.
			 * @return The clause's value.
			 */
			function runCatch(cn:String, ce:Expr):Dynamic {
				declaredNames.push(cn);
				declaredOld.push(locals.get(cn));
				locals.set(cn, {ref: raw});
				var rv:Dynamic = expr(ce);
				restore(old);
				return rv;
			}
			if (catchMatches(raw, t))
				return runCatch(n, ecatch);
			if (extra != null)
				for (c in extra)
					if (catchMatches(raw, c.t))
						return runCatch(c.v, c.expr);
			throw err;
		}
	}

	/**
	 * Evaluates a metadata wrapper, kept out of `expr` for the same reason `evalTry` is.
	 *
	 * Metadata never appears inside a loop, so this body only ever competed for registers and
	 * instruction cache with the node kinds that do.
	 */
	@:noinline function evalMeta(meta:String, args:Array<Expr>, e:Expr):Dynamic {
		switch (ExprTools.expr(e)) {
			case EDecl(decl):
				attachMeta(decl, {name: meta, params: args});
			default:
		}

		var r:Dynamic = null, old = metas.length;
		metas.push({name: meta, params: args});

		try {
			r = expr(e);
			metas.resize(old);
		} catch (e:Dynamic) {
			metas.resize(old);
			#if neko neko.Lib.rethrow(e); #else throw e; #end
		}

		return r;
	}

	/**
	 * Evaluates one expression, and whatever it contains.
	 *
	 * The centre of the interpreter: every form the language has is a case here, and everything else
	 * in this class is reached through it. Hot enough that the shape of the switch and the order of
	 * its cases are load-bearing rather than stylistic.
	 *
	 * @param e The expression, or null for an absent one.
	 * @param t The type the result is expected to take, when the caller knows it; used to pick a
	 *        concrete map for an empty literal, and to box a value into an abstract.
	 * @param void Whether the value is going to be discarded, which lets some forms skip building one.
	 * @param mapCompr Whether this sits inside a map comprehension, where a `=>` is an entry rather
	 *        than an operator.
	 * @return The value it evaluates to.
	 */
	public function expr(e:Expr, ?t:CType, void:Bool = false, mapCompr:Bool = false):Dynamic {
		if (trackAccess && accessingInterp != this) {
			accessingInterp = this;
			#if hxscript_profile
			interpSwitches++;
			#end
		}
		if (Type.environment != environment)
			Type.environment = environment;

		position = e.pos;
		var e = e.e;

		if (frameLocals == null)
			pushStack(SScript(position.origin));

		switch (e) {
			case EDecl(decl):
				startDecl(decl);
			case EUsing(path):
				usingType(path);
			case EImport(path, mode):
				importPath(path, mode);
			case EConst(c):
				switch (c) {
					case CInt(v): return v;
					case CFloat(f): return f;
					case CString(s): return s;
					case CReg(p, m): return new EReg(p, m);
				}
			case EIdent(id):
				if (hasCaptures && captures.exists(id))
					return captures.get(id);
				var l:Variable = locals.get(id);
				if (l != null)
					return readLocal(l, id);
				return resolve(id);
			case EVar(n, t, e, get, set, isFinal):
				declaredNames.push(n);
				declaredOld.push(locals.get(n));

				var v:Dynamic = (e == null ? null : expr(e, t));
				var l:Variable = bindDeclared(v, t);

				if (get != null) {
					l.get = get;
					noteAccessor(get);
				}
				if (set != null) {
					l.set = set;
					noteAccessor(set);
				}
				if (isFinal)
					l.isFinal = isFinal;

				locals.set(n, l);
			case EParent(e):
				return expr(e, void, mapCompr);
			case EBlock(exprs):
				var old = declaredNames.length;
				var v = null;
				for (e in exprs) {
					v = expr(e, void, mapCompr);
					if (unwinding)
						break;
				}
				restore(old);
				return v;
			case EField(e, f, m):
				return resolveField(e, f, m);
			case EBinop('=>', e1, e2) if (mapCompr):
				return e;
			case EBinop(op, e1, e2):
				return binop(op, e1, e2);
			case EUnop(op, prefix, e):
				switch (op) {
					case "!":
						var v:Dynamic = expr(e);
						return (v is AbstractValue) ? abstractUnop("u!", v) : v != true;
					case "-":
						var v:Dynamic = expr(e);
						if (v is Int)
							return -(v : Int);
						return (v is AbstractValue) ? abstractUnop("u-", v) : -(v : Float);
					case "++":
						return increment(e, prefix, 1);
					case "--":
						return increment(e, prefix, -1);
					case "~":
						var v:Dynamic = expr(e);
						return (v is AbstractValue) ? abstractUnop("u~", v) : ~(v : Int);
					default:
						error(EInvalidOp(op));
				}
			case ECall(e, params):
				var args = new Array();
				for (p in params)
					args.push(expr(p));

				switch (ExprTools.expr(e)) {
					case EField(e, f, m):
						var obj = expr(e);
						if (obj == null) {
							if (m)
								return null;
							error(EInvalidAccess(f));
						}
						return fcall(obj, f, args);
					default:
						return call(null, expr(e), args);
				}
			case EIf(econd, e1, e2):
				return if (expr(econd)) expr(e1, void,
					mapCompr) else if (e2 == null) (void ? Interp.void : null) else expr(e2, void, mapCompr);
			case EWhile(econd, e):
				whileLoop(econd, e);
				return null;
			case EDoWhile(econd, e):
				doWhileLoop(econd, e);
				return null;
			case EFor(v, it, e):
				forLoop(v, it, expr.bind(e));
				return null;
			case EForGen(it, e):
				ExprTools.getKeyIterator(it, function(vk, vv, it) {
					if (vk == null) {
						position = it.pos;
						error(ECustom("Invalid for expression"));
						return;
					}
					forKeyValueLoop(vk, vv, it, expr.bind(e));
				});
				return null;
			case EBreak:
				breaking = true;
				return null;
			case EContinue:
				continuing = true;
				return null;
			case EReturn(e):
				returnValue = e == null ? null : expr(e, void, mapCompr);
				returning = true;
				return null;
			case EFunction(params, fexpr, name, ret, id):
				return buildFunction(name, params, fexpr, ret, id);
			case EArrayDecl(arr):
				return evalArrayDecl(arr, t);
			case EArray(e, index):
				var arr:Dynamic = expr(e);
				var index:Dynamic = expr(index);
				if (isMap(arr))
					return getMapValue(arr, index);
				if (arr is AbstractValue)
					return abstractGetIndex(arr, index);
				return arr[index];
			case ENew(cl, params):
				var a = new Array();
				for (e in params)
					a.push(expr(e));
				return cnew(cl, a);
			case EThrow(e):
				throw expr(e);
			case ETry(e, n, t, ecatch, extra):
				return evalTry(e, n, t, ecatch, extra);
			case EObject(fl):
				var o = {};
				for (f in fl)
					set(o, f.name, expr(f.e));
				return o;
			case ETernary(econd, e1, e2):
				return if (expr(econd) == true) expr(e1) else expr(e2);
			case ESwitch(e, cases, def):
				return evalSwitch(e, cases, def, void, mapCompr);
			case EMeta(meta, args, e):
				return evalMeta(meta, args, e);
			case ECast(e, t):
				return tryCast(expr(e), t);
			case ECheckType(e, t):
				return tryCast(expr(e), t);
		}
		return (void ? Interp.void : null);
	}

	/**
	 * Resolves a field-access chain (`a.b.c`) as a whole, so a leading run of names can name a type
	 * (or package path) before member access begins. The chain is queued and, once the outermost call
	 * is reached, walked left to right: names resolve against captures/locals/imports or the type
	 * collection, then remaining segments are field accesses.
	 *
	 * @param e The base expression of the chain.
	 * @param f The field being accessed on it.
	 * @param m Whether this is a null-safe (`?.`) access.
	 * @return The resolved value, or null while an inner call defers to the outermost one.
	 */
	function resolveField(e:Expr, f:String, m:Bool = false):Dynamic {
		final canResolve = (resolveFields.length == 0);

		if (canResolve) {
			switch (ExprTools.expr(e)) {
				case EIdent(id):
					var base:Dynamic = null;
					if (hasCaptures && captures.exists(id)) {
						base = captures.get(id);
					} else {
						var l:Variable = locals.get(id);
						if (l != null) {
							base = readLocal(l, id);
						} else {
							var found:Dynamic = imports.get(id);
							if (found == null)
								found = variables.get(id);
							if (found != null)
								base = resolveMirror(found);
						}
					}

					/**
					 * Through `fromType`, because an import answered here may be an enum and a
					 * constructor of one reads like a static without being one. This is the short
					 * path, taken whenever a chain's first segment is a name already in scope, and it
					 * answered by reflection alone: `haxe.ds.Option.None` is resolved segment by
					 * segment and was built, `Option.None` after importing it came through here and
					 * was not.
					 *
					 * On HashLink that was a null where the constructor belonged, with nothing said
					 * about it. `Option.Some(3)` was right throughout, being a call rather than a
					 * read, which is what made it look like a problem with the name.
					 */
					if (base != null)
						return fromType(base, f, m);
				default:
			}
		}

		resolveFields.unshift(m ? RMaybe(f) : RNormal(f));
		switch (ExprTools.expr(e)) {
			case EIdent(id):
				resolveFields.unshift(RNormal(id));
			case EField(_, _, _):
				expr(e);
			default:
				resolveFields.unshift(RExpr(e));
		}

		if (!canResolve)
			return null;

		var __tempResolveFields:Array<Resolve> = resolveFields;
		resolveFields = [];

		var got:Dynamic = null,
			gotType:TypeInfo = null,
			namedHolder:Dynamic = null,
			unknown:Null<String> = null;

		var fullProp:String = '';
		for (i => prop in __tempResolveFields) {
			var field:String, maybe:Bool;

			switch (prop) {
				case RNormal(f):
					field = f;
					maybe = false;
				case RMaybe(f):
					field = f;
					maybe = true;
				case RExpr(e):
					got = expr(e);
					continue;
			}

			if (got == null) {
				fullProp = (fullProp.length == 0 ? field : '$fullProp.$field');

				if (i == 0) {
					if (captures.exists(field)) {
						got = captures.get(field);
					} else if (locals.exists(field)) {
						got = getLocal(field);
					} else if (isResolvable(field)) {
						got = resolve(field);
					} else {
						unknown = field;
					}

					if (got != null)
						continue;
				}

				var info = (TypeCollection.main.fromPath(fullProp) ?? environment?.types.fromPath(fullProp));

				if (info != null) {
					unknown = null;
					gotType = info[0];

					if (i == __tempResolveFields.length - 1)
						got = gotType.resolve(environment);
				} else if (gotType != null) {
					var t = gotType.resolve(environment);
					got = fromType(t, field, maybe);
				} else if (namedHolder != null) {
					got = fromType(namedHolder, field, maybe);
				} else {
					/**
					 * A fully-qualified path the index does not carry, resolved by name.
					 *
					 * Writing `haxe.Json.stringify(o)` with no import is ordinary Haxe and was an
					 * `Unknown identifier: haxe` here, because the only paths a chain could be
					 * resolved by were the ones some macro had put in the index. The runtime knows
					 * about a great many more, and asking it is what the compiled backends already
					 * did, so this is also what stops the two disagreeing about which types exist.
					 *
					 * Held rather than used, exactly as a type found in the index is, so that a
					 * longer path still gets its turn: `haxe.ds.Option` resolving does not settle
					 * whether `haxe.ds.Option.None` is a longer type name or a field of that one.
					 *
					 * Last, and only once nothing else has answered, so it costs nothing on the path
					 * a resolvable name already takes.
					 */
					var named:Dynamic = TypeTools.resolve(fullProp, environment);

					if (named != null) {
						unknown = null;

						if (i == __tempResolveFields.length - 1)
							got = named;
						else
							namedHolder = named;
					}
				}
			} else {
				/**
				 * Through `fromType`, because what a chain has already resolved may be an enum, and a
				 * constructor of one reads like a static without being one. `haxe.ds.Option.None` was
				 * built and `Option.None` after importing it was not: the first is a path resolved
				 * segment by segment, the second an import answered whole, and only the first reached
				 * the question that builds the value.
				 *
				 * On HashLink that showed as a null where the constructor belonged, with nothing said
				 * about it. `Option.Some(3)` was right throughout, being a call rather than a read,
				 * which is what made it look like a problem with the name.
				 */
				got = fromType(got, field, maybe);
			}
		}

		if (unknown != null)
			error(EUnknownVariable(unknown));

		return got;
	}

	/**
	 * Finds a metadata entry among the metas gathered for the current declaration.
	 *
	 * @param name The metadata name (e.g. `:bypassAccessor`).
	 * @return The entry, or null if absent.
	 */
	inline function getMeta(name:String):MetadataEntry {
		var entry:MetadataEntry = null;

		for (meta in metas) {
			if (meta.name == name) {
				entry = meta;
				break;
			}
		}

		return entry;
	}

	/**
	 * Whether a value matches a `switch` pattern value, including structural enum equality (scripted
	 * and native).
	 *
	 * @param v The value being switched on.
	 * @param with The pattern value.
	 * @return True if they match.
	 */
	public static function matchValues(v:Dynamic, with:Dynamic):Bool {
		if (v == with) {
			return true;
		} else if (v is ICustomEnumValueType && with is ICustomEnumValueType) {
			return cast(v, ICustomEnumValueType).eq(with);
		} else if (Reflect.isEnumValue(v) && Type.getEnum(v) != null && Type.getEnum(with) != null) {
			return Type.enumEq(v, with);
		}

		return false;
	}

	/**
	 * Whether a value satisfies a type annotation, without coercing it or raising an error.
	 *
	 * This is the test `tryCast` makes, separated out so a structural shape can be checked field by
	 * field: `tryCast` reports which field is wrong and throws, while a plain `is` only needs the
	 * yes or no. Outside typed mode nothing is checked, matching `tryCast`.
	 *
	 * @param v The value to test.
	 * @param t The annotation to test it against.
	 * @return True if the value satisfies the annotation.
	 */
	public function matchesType(v:Dynamic, t:CType):Bool {
		switch (t) {
			case null:
				return true;
			case CTParent(inner):
				return matchesType(v, inner);
			case CTOpt(inner):
				return v == null || matchesType(v, inner);
			case CTPath(['Null'], params) if (params != null && params.length > 0):
				return v == null || matchesType(v, params[0]);
			case CTAnon(fields):
				if (!Config.typedMode || v == null)
					return true;
				for (f in fields) {
					if (!Reflect.hasField(v, f.name)) {
						if (ExprTools.isOptionalField(f))
							continue;
						return false;
					}
					if (!matchesType(Reflect.field(v, f.name), f.t))
						return false;
				}
				return true;
			case CTFun(_, _):
				return !Config.typedMode || v == null || Reflect.isFunction(v);
			case CTPath(p, _):
				if (!Config.typedMode || v == null)
					return true;

				var path:String = (p.length == 1 ? p[0] : p.join('.'));
				switch (path) {
					case 'Dynamic' | 'Any' | 'Void' | 'Class' | 'Enum':
						return true;
					case 'Int':
						return Std.isOfType(v, Int);
					case 'Float':
						return Std.isOfType(v, Float);
					case 'Bool':
						return Std.isOfType(v, Bool);
					case 'String':
						return Std.isOfType(v, String);
					case 'Map' | 'IMap':
						return v is IMap;
					default:
				}

				var rt:Dynamic = imports.get(path);
				if (rt == null) {
					var info = TypeCollection.main.fromPath(path);
					if (info != null)
						rt = info[0].compilePath().resolve();
				}

				if (rt == null)
					return true;

				if (rt is ScriptedTypedef) {
					var td:ScriptedTypedef = cast rt;
					return !td.structural || td.structFields == null || td.matchesStructure(v);
				}

				if (rt is Class || rt is ScriptedClass || rt is ScriptedInterface || rt is Enum || rt is ScriptedEnum)
					return Std.isOfType(v, rt);

				return true;
			default:
				return true;
		}
	}

	/**
	 * Checks a non-null value against a core type in typed mode, coercing where Haxe allows it
	 * implicitly. Split out of `tryCast` so the fast path and the general path share one definition.
	 *
	 * @param e The value to check.
	 * @param path The core type name.
	 * @return The value, widened to `Float` where that is the implicit conversion.
	 * @throws InterpException If the value is not of that type.
	 */
	function castCoreType(e:Dynamic, path:String):Dynamic {
		switch (path) {
			case 'Int':
				if (Std.isOfType(e, Int))
					return e;
				return error(ECustom('${AbstractTools.resolveName(e)} should be Int'));
			case 'Float':
				if (Std.isOfType(e, Int))
					return (e : Int) + 0.0;
				if (Std.isOfType(e, Float))
					return e;
				return error(ECustom('${AbstractTools.resolveName(e)} should be Float'));
			case 'Bool':
				if (Std.isOfType(e, Bool))
					return e;
				return error(ECustom('${AbstractTools.resolveName(e)} should be Bool'));
			case 'String':
				if (Std.isOfType(e, String))
					return e;
				return error(ECustom('${AbstractTools.resolveName(e)} should be String'));
			default:
				if (e is IMap)
					return e;
				return error(ECustom('${AbstractTools.resolveName(e)} should be Map'));
		}
	}

	/**
	 * Builds the slot for an annotated binding: applies the declared type, boxes an abstract, and records the
	 * type so later writes are checked against it.
	 *
	 * @param v The evaluated initial value.
	 * @param t The declared type, or null when the binding is unannotated.
	 * @return The slot to store.
	 */
	public function bindDeclared(v:Dynamic, ?t:CType):Variable {
		if (t != null)
			v = tryCast(v, t);

		var l:Variable = (AbstractTools.isAbstract(v) ? {ref: v.__a, a: v} : {ref: v});
		if (t != null)
			l.t = t;
		return l;
	}

	/**
	 * Whether a value satisfies a declared type, without throwing.
	 *
	 * @param v The value to test.
	 * @param t The declared type, or null (which matches anything).
	 * @return Whether `v` would pass `tryCast` against `t`.
	 */
	function typeMatches(v:Dynamic, ?t:CType):Bool {
		if (t == null)
			return true;
		try {
			tryCast(v, t);
			return true;
		} catch (_:Dynamic)
			return false;
	}

	/**
	 * Coerces a value to a declared type, or throws if it cannot hold it.
	 *
	 * This is the single enforcement point for typed mode: annotations, arguments, returns, `cast`
	 * and abstract boxing all arrive here, and `typeMatches` is the same test without the throw, so
	 * checking a type and enforcing one cannot drift apart.
	 *
	 * @param e The value to coerce.
	 * @param type The declared type, or null to accept anything.
	 * @return The value, boxed or widened where the type requires it.
	 */
	/** The declared type needs the full walk, which is everything `castPlan` does not shortcut. */
	static inline var CAST_SLOW:Int = 0;

	/** It names something that takes any value as it is. */
	static inline var CAST_PASS:Int = 1;

	/** It names `Int`. */
	static inline var CAST_INT:Int = 2;

	/** It names `Float`, which an `Int` widens into. */
	static inline var CAST_FLOAT:Int = 3;

	/** It names `Bool`. */
	static inline var CAST_BOOL:Int = 4;

	/** It names `String`. */
	static inline var CAST_STRING:Int = 5;

	/** It names `Map` or `IMap`. */
	static inline var CAST_MAP:Int = 6;

	/**
	 * Enforces a slot's declared type on a value, remembering how rather than working it out again.
	 *
	 * **A typed write was paying a map miss for its own annotation.** `tryCast` resolves the written
	 * name against `imports` on every store, to see whether an import shadows it, and for `Int` or
	 * `String` that is a miss every time. Skipping the whole of `tryCast` measured `varTyped` at 106ms
	 * against 64, and `varTypedObj` at 117 against 61, so it is the entire cost of annotating a
	 * variable.
	 *
	 * What makes remembering sound is that the answer only depends on the annotation, which cannot
	 * change, and on the import table, which can. `Bindings.stamp` moves whenever that table or
	 * anything it falls back to does, so a plan is used only while it is still true and worked out
	 * again when it is not.
	 *
	 * The plan is an integer rather than the written name, so the test a core type really is costs an
	 * integer switch instead of a chain of string comparisons.
	 *
	 * @param l The slot being written.
	 * @param v The value.
	 * @return The value as its declared type takes it.
	 */
	function enforce(l:Variable, v:Dynamic):Dynamic {
		var now:Int = imports.stamp();

		if ((l.castState >>> 3) != now || l.castState < 0)
			l.castState = (now << 3) | planCast(l);

		var plan:Int = l.castState & 7;

		/**
		 * A boxed abstract takes neither shortcut, because `tryCast` reaches for its underlying value
		 * before doing anything else with it and that is not a decision the annotation can carry.
		 */
		if (!(v is AbstractValue)) {
			if (plan == CAST_PASS)
				return v;

			if (plan != CAST_SLOW) {
				if (!Config.typedMode || v == null)
					return v;

				/**
				 * The test a core type really is, and no string anywhere. `castCoreType` decides which
				 * type it was asked about by comparing the name, which is a chain of string compares on
				 * hxcpp and was most of what a typed write cost. It is still what builds the complaint,
				 * since that path is not the hot one.
				 */
				switch (plan) {
					case CAST_INT:
						if (v is Int)
							return v;
					case CAST_FLOAT:
						if (v is Int)
							return (v : Int) + 0.0;
						if (v is Float)
							return v;
					case CAST_BOOL:
						if (v is Bool)
							return v;
					case CAST_STRING:
						if (v is String)
							return v;
					case _:
						if (v is IMap)
							return v;
				}

				return castCoreType(v, CORE_NAMES[plan]);
			}
		}

		return tryCast(v, l.t);
	}

	/**
	 * Works out how a slot's declared type enforces itself, against the import table as it stands.
	 *
	 * Only a plain one-segment name is shortcut, which is what `var x:Int` and `var s:String` are.
	 * Anything wrapped, parameterised or dotted keeps the full walk, so the shortcut can only ever be
	 * taken for the shapes it was checked against.
	 *
	 * @param l The slot.
	 * @return Its plan.
	 */
	function planCast(l:Variable):Int {
		switch (l.t) {
			case CTPath(p, _) if (p.length == 1):
				var path:String = p[0];

				/** Something imported under that name is what `tryCast` prefers, so leave it to it. */
				if (imports.get(path) != null)
					return CAST_SLOW;

				return switch (path) {
					case 'Dynamic' | 'Any' | 'Void' | 'Class' | 'Enum': CAST_PASS;
					case 'Int': CAST_INT;
					case 'Float': CAST_FLOAT;
					case 'Bool': CAST_BOOL;
					case 'String': CAST_STRING;
					case 'Map' | 'IMap': CAST_MAP;
					default: CAST_SLOW;
				}

			case _:
				return CAST_SLOW;
		}
	}

	/** The name each core-type plan stands for, for the complaint when a value is not one. */
	static var CORE_NAMES:Array<String> = ['', '', 'Int', 'Float', 'Bool', 'String', 'Map'];

	function tryCast(e:Dynamic, ?type):Dynamic {
		switch (type) {
			case null:
				return e;
			case CTParent(inner):
				return tryCast(e, inner);
			case CTOpt(inner):
				return (e == null) ? e : tryCast(e, inner);
			case CTPath(['Null'], params) if (params != null && params.length > 0):
				return (e == null) ? e : tryCast(e, params[0]);
			case CTPath(p, _):
				var path = (p.length == 1 ? p[0] : p.join('.'));
				var t = imports.get(path);

				if (t == null) {
					if (!(e is AbstractValue)) {
						switch (path) {
							case 'Dynamic' | 'Any' | 'Void' | 'Class' | 'Enum':
								return e;
							case 'Int' | 'Float' | 'Bool' | 'String' | 'Map' | 'IMap':
								return (!Config.typedMode || e == null) ? e : castCoreType(e, path);
							default:
						}
					}

					var info = TypeCollection.main.fromPath(path);
					if (info != null)
						t = info[0].compilePath().resolve();
				}

				if (e != null && t is ScriptedAbstract)
					return (cast t : ScriptedAbstract).fromValue(e);

				if (e != null && TypeTools.isClass(t)) {
					if (Type.getSuperClass(t) == AbstractValue) {
						/** Already the wrapper being cast to, so it is its own answer rather than a second one. */
						if (Std.isOfType(e, t))
							return e;

						return Type.createInstance(t, [e]);
					}
					if (e is AbstractValue) {
						var r = e.resolveTo(Type.getClassName(t));
						if (r == null)
							throw 'Can\'t cast ${e.impl} to $path';
						return r;
					}
				}

				if (!Config.typedMode || e == null)
					return e;

				switch (path) {
					case 'Dynamic' | 'Any' | 'Void' | 'Class' | 'Enum':
						return e;
					case 'Int' | 'Float' | 'Bool' | 'String' | 'Map' | 'IMap':
						if (e is AbstractValue) {
							var opened:Dynamic = AbstractTools.openTo(cast e, path);
							if (opened != null && opened != e)
								return castCoreType(opened, path);
						}
						return castCoreType(e, path);
					default:
						if (t == null)
							return e;
						if (t is ScriptedTypedef) {
							var td:ScriptedTypedef = cast t;
							if (td.structural && td.structFields != null && !td.matchesStructure(e))
								return error(ECustom('${AbstractTools.resolveName(e)} should be $path'));
							return e;
						}
						if ((t is Class
							|| t is ScriptedClass
							|| t is ScriptedInterface
							|| t is Enum
							|| t is ScriptedEnum)
							&& !Std.isOfType(e, t)) {
							if (isCompiledAs(t, e))
								return e;
							return error(ECustom('${AbstractTools.resolveName(e)} should be $path'));
						}
						return e;
				}
			case CTAnon(fields):
				if (!Config.typedMode || e == null)
					return e;
				for (f in fields) {
					if (!Reflect.hasField(e, f.name)) {
						if (ExprTools.isOptionalField(f))
							continue;
						return error(ECustom('${AbstractTools.resolveName(e)} should have field ${f.name}'));
					}
					if (!matchesType(Reflect.field(e, f.name), f.t))
						return
							error(ECustom('field ${f.name} of ${AbstractTools.resolveName(e)} should be ${new Printer().typeToString(f.t)}'));
				}
				return e;
			case CTFun(_, _):
				if (!Config.typedMode || e == null || Reflect.isFunction(e))
					return e;
				return error(ECustom('${AbstractTools.resolveName(e)} should be a function'));
			default:
				return e;
		}
	}

	/**
	 * Runs a `do`/`while` loop.
	 *
	 * @param econd The continuation condition.
	 * @param e The body expression.
	 */
	function doWhileLoop(econd, e) {
		var old = declaredNames.length;
		do {
			if (!loopRun(expr.bind(e)))
				break;
		} while (expr(econd) == true);
		restore(old);
	}

	/**
	 * Runs a `while` loop.
	 *
	 * @param econd The continuation condition.
	 * @param e The body expression.
	 */
	function whileLoop(econd, e) {
		var old = declaredNames.length;
		while (expr(econd) == true) {
			if (!loopRun(expr.bind(e)))
				break;
		}
		restore(old);
	}

	/**
	 * Produces an iterator for a value, accepting arrays, iterables, and iterators.
	 *
	 * @param v The value to iterate.
	 * @return An iterator over it.
	 * @throws InterpException If the value cannot be iterated.
	 */
	function makeIterator(v:Dynamic):Iterator<Dynamic> {
		if (v is Array)
			return (v : Array<Dynamic>).iterator();

		if (v is IntIterator) {
			var range:Iterator<Int> = (v : IntIterator);
			return cast range;
		}

		var iter = Reflect.field(v, 'iterator');
		if (iter != null)
			v = Reflect.callMethod(v, iter, []);

		var has:Dynamic = Reflect.field(v, 'hasNext');
		var next:Dynamic = Reflect.field(v, 'next');

		if (has == null || next == null)
			error(EInvalidIterator(v));

		/**
		 * A scripted object is handed back wrapped, because finding its methods and calling them are
		 * two different questions. `Reflect` here is the library's own and looks in the instance's
		 * slots, so both were found; the loop then calls `hasNext` on the value directly, which is a
		 * native dynamic call that knows nothing about those slots. The lookup succeeded and the call
		 * did not, which read as `Null Function Pointer` rather than as anything to do with
		 * iterating. Nothing else needs the wrapper, so nothing else pays for it.
		 */
		return (v is IScriptedInstance) ? new SlotIterator(has, next) : v;
	}

	/**
	 * Produces a key-value iterator for a value, accepting maps, arrays, and key-value iterables.
	 *
	 * @param v The value to iterate.
	 * @return A key-value iterator over it.
	 * @throws InterpException If the value cannot be key-value iterated.
	 */
	function makeKeyValueIterator(v:Dynamic):KeyValueIterator<Dynamic, Dynamic> {
		if ((v is haxe.ds.IntMap)
			|| (v is haxe.ds.StringMap)
			|| (v is haxe.ds.ObjectMap)
			|| (v is haxe.ds.EnumValueMap)) {
			return (v : IMap<Dynamic, Dynamic>).keyValueIterator();
		} else if (v is Array) {
			return (v : Array<Dynamic>).keyValueIterator();
		}

		var iter = Reflect.field(v, 'keyValueIterator');
		if (iter != null)
			v = Reflect.callMethod(v, iter, []);

		if (Reflect.field(v, 'hasNext') == null || Reflect.field(v, 'next') == null)
			error(EInvalidIterator(v));

		return v;
	}

	/**
	 * Runs a `for (n in it)` loop, binding the loop variable each iteration.
	 *
	 * @param n The loop variable name.
	 * @param it The iterable expression.
	 * @param ef The body callback.
	 */
	function forLoop(n, it, ef:Dynamic) {
		var old = declaredNames.length;
		declaredNames.push(n);
		declaredOld.push(locals.get(n));

		var it = makeIterator(expr(it));

		while (it.hasNext()) {
			locals.set(n, {ref: it.next()});

			if (!loopRun(ef))
				break;
		}

		restore(old);
	}

	/**
	 * Runs a `for (k => v in it)` loop, binding both key and value each iteration.
	 *
	 * @param vk The key variable name.
	 * @param vv The value variable name.
	 * @param it The key-value iterable expression.
	 * @param ef The body callback.
	 */
	function forKeyValueLoop(vk, vv, it, ef:Dynamic) {
		var old = declaredNames.length;
		declaredNames.push(vk);
		declaredOld.push(locals.get(vk));
		declaredNames.push(vv);
		declaredOld.push(locals.get(vv));

		var it = makeKeyValueIterator(expr(it));

		while (it.hasNext()) {
			var v = it.next();

			if (v.key == null)
				error(EUnknownField(v, 'key'));
			if (v.value == null)
				error(EUnknownField(v, 'value'));

			locals.set(vk, {ref: v.key});
			locals.set(vv, {ref: v.value});

			if (!loopRun(ef))
				break;
		}

		restore(old);
	}

	/**
	 * Runs one loop-body iteration, absorbing `break`/`continue` (a `return` still propagates).
	 *
	 * @param f The body to run.
	 * @return True to continue looping, false if the body broke.
	 */
	inline function loopRun(f:Void->Void) {
		var cont = true;
		f();
		if (continuing)
			continuing = false;
		if (breaking) {
			breaking = false;
			cont = false;
		}
		if (returning)
			cont = false;
		return cont;
	}

	/**
	 * @param o A value.
	 * @return Whether it is a map.
	 */
	inline function isMap(o:Dynamic):Bool {
		return (o is IMap);
	}

	/**
	 * @param map A map.
	 * @param key The key.
	 * @return The mapped value.
	 */
	inline function getMapValue(map:Dynamic, key:Dynamic):Dynamic {
		return cast(map, haxe.Constraints.IMap<Dynamic, Dynamic>).get(key);
	}

	/**
	 * @param map A map.
	 * @param key The key.
	 * @param value The value to store.
	 */
	inline function setMapValue(map:Dynamic, key:Dynamic, value:Dynamic):Void {
		cast(map, haxe.Constraints.IMap<Dynamic, Dynamic>).set(key, value);
	}

	/**
	 * Builds the right kind of map for an object literal used as a map, picking the implementation
	 * from the key types (int, string, enum, or object).
	 *
	 * @param keys The keys.
	 * @param values The values, positionally matched to keys.
	 * @return The constructed map.
	 */
	function makeMap(keys:Array<Dynamic>, values:Array<Dynamic>):Dynamic {
		var isAllString:Bool = true;
		var isAllInt:Bool = true;
		var isAllObject:Bool = true;
		var isAllEnum:Bool = true;
		for (key in keys) {
			isAllString = isAllString && (key is String);
			isAllInt = isAllInt && (key is Int);
			isAllObject = isAllObject && Reflect.isObject(key);
			isAllEnum = isAllEnum && HaxeReflect.isEnumValue(key);
		}

		#if (haxe_ver >= 4.1)
		if (isAllInt) {
			var m = new Map<Int, Dynamic>();
			for (i => key in keys)
				m.set(key, values[i]);
			return m;
		}
		if (isAllString) {
			var m = new Map<String, Dynamic>();
			for (i => key in keys)
				m.set(key, values[i]);
			return m;
		}
		if (isAllEnum) {
			var m = new haxe.ds.EnumValueMap<Dynamic, Dynamic>();
			for (i => key in keys)
				m.set(key, values[i]);
			return m;
		}
		if (isAllObject) {
			var m = new Map<{}, Dynamic>();
			for (i => key in keys)
				m.set(key, values[i]);
			return m;
		}
		#else
		var m:Dynamic = {
			if (isAllInt)
				new haxe.ds.IntMap<Dynamic>();
			else if (isAllString)
				new haxe.ds.StringMap<Dynamic>();
			else if (isAllEnum)
				new haxe.ds.EnumValueMap<Dynamic, Dynamic>();
			else if (isAllObject)
				new haxe.ds.ObjectMap<Dynamic, Dynamic>();
			else
				null;
		}
		if (m != null) {
			for (n in 0...keys.length)
				setMapValue(m, keys[n], values[n]);
			return m;
		}
		#end
		error(ECustom("Invalid map keys " + keys));
		return null;
	}

	/**
	 * Rejects reads/writes of a script-declared `private` member from outside the declaring class.
	 * Access is automatically given if the read/write site has the `@:privateAccess` metadata.
	 * Active when either `Config.strictAccess` or `Config.typedMode` is on (typed mode enforces access
	 * the way Haxe does); native fields carry no access information at runtime and are never checked.
	 *
	 * @param o The object being accessed.
	 * @param f The field name.
	 * @throws InterpException If the field is private, the caller isn't in the declaring class, and @:privateAccess is not used.
	 */
	inline function checkAccess(o:Dynamic, f:String):Void {
		if (!Config.strictAccess && !Config.typedMode)
			return;

		var owner:ScriptedClass = ScriptedAccess.declaringClass(o);
		if (owner == null)
			return;

		var declaring:ScriptedClass = owner.privateOwnerOf(f);
		if (declaring == null)
			return;

		if (getMeta(':privateAccess') != null)
			return;

		if (ownerClass == null || !ownerClass.isOrExtends(declaring))
			error(ECustom('Cannot access private field $f of ${declaring.path}'));
	}

	/**
	 * Reads field `f` of `o`, honouring properties, `super` mirrors, `:bypassAccessor`, and static
	 * `_Fields_` hosts. Defers if the target is an uninitialized scripted type.
	 *
	 * @param o The object to read from.
	 * @param f The field name.
	 * @param maybe Whether this is a null-safe (`?.`) access (returns null instead of erroring on a null object).
	 * @return The field value.
	 */
	function get(o:Dynamic, f:String, maybe:Bool = false):Dynamic {
		if (canDefer && o is IScriptedType && !o.initialized)
			throw DDefer;

		checkAccess(o, f);

		if (o == null) {
			if (!maybe) {
				error(EInvalidAccess(f));
			} else {
				return null;
			}
		}

		o = staticHost(o);

		if (o is ScriptedAbstractValue) {
			var box:ScriptedAbstractValue = cast o;
			return box.owner.getField(box.boxed, f);
		}

		if (o is Reference) {
			switch (cast(o, Reference)) {
				case RSuper(locals, _, _):
					if (locals == null) {
						error(EHasNoSuper);
					} else if (locals.exists(f)) {
						return (locals.get(f).a ?? locals.get(f).r);
					} else {
						error(EUnknownVariable(f));
					}
				default:
			}
		}

		var bypassAccessor:Bool = (getMeta(':bypassAccessor') != null);
		var prop = (if (bypassAccessor) {
			Reflect.field(o, f);
		} else {
			#if php
			try {
				Reflect.getProperty(o, f);
			} catch (e:Dynamic) {
				Reflect.field(o, f);
			}
			#else
			Reflect.getProperty(o, f);
			#end
		});

		if (prop == null && o is AbstractValue && AbstractTools.forwards(o, f)) {
			var boxed:Dynamic = AbstractTools.underlying(o);
			var forwarded:Dynamic = Reflect.getProperty(boxed, f);

			if (Reflect.isFunction(forwarded))
				return Reflect.makeVarArgs(function(args:Array<Dynamic>):Dynamic return Reflect.callMethod(boxed,
					forwarded, args));

			if (forwarded == null && resolveCallShim(boxed, f) != null)
				return Reflect.makeVarArgs(function(args:Array<Dynamic>):Dynamic return fcall(boxed, f, args));

			return forwarded;
		}

		if (prop == null && o is ScriptedAbstract)
			return (cast o : ScriptedAbstract).impl.reflectGetField(f);

		if (prop == null && hasField(o, f) == false) {
			var fields = getFieldsClass((o is Class || o is ScriptedClass) ? Type.getClassName(o) : Type.getEnumName(o));
			if (fields != null)
				return (bypassAccessor ? Reflect.field(fields, f) : Reflect.getProperty(fields, f));
		}

		if (hxscript.debug.Metrics.on)
			hxscript.debug.Metrics.reads++;

		return boolean(o, f, prop);
	}

	/**
	 * @param v A value being matched.
	 * @return The constructor it was made with, or null when it is not an enum value at all.
	 */
	function constructorOf(v:Dynamic):Null<String> {
		/**
		 * Asked before reading, not caught after. `Type.enumConstructor` on something that is not an
		 * enum value is not a throw on every target: on hxcpp it ends the process, so a `try` around
		 * it is a guard that does not guard.
		 */
		if (v == null || !((v is ICustomEnumValueType) || HaxeReflect.isEnumValue(v)))
			return null;

		return Type.enumConstructor(v);
	}

	/**
	 * @param e A pattern's callee.
	 * @return The bare upper-case name it is, when that name resolves to nothing and so can only be
	 *         a constructor of whatever is being matched.
	 */
	function patternName(e:Expr):Null<String> {
		return switch (ExprTools.expr(e)) {
			case EIdent(id) if (id.isTypeIdentifier() && !isResolvable(id)): id;
			case _: null;
		}
	}

	/**
	 * Reads a member off something a path resolved to, which may be an enum.
	 *
	 * `haxe.ds.Option.None` reads like a static and is not one: reflection finds nothing on the enum,
	 * so the read answered null and the script got a null where Haxe gives a value. It is built here
	 * instead, the way a scripted enum's constructor already is.
	 *
	 * **Only where a type is known to be what was resolved.** The obvious place for this was the end
	 * of `get`, and that was wrong twice over: it ran on every field read that came back empty, which
	 * is not rare, and `Type.getEnumConstructs` on something that is not an enum ends the hxcpp
	 * process rather than throwing. Two asserted cases died of it.
	 *
	 * @param t The resolved type.
	 * @param f The member's name.
	 * @param maybe Whether the access was null-safe.
	 * @return The member, or the enum value when the name is one of its constructors.
	 */
	function fromType(t:Dynamic, f:String, maybe:Bool):Dynamic {
		var read:Dynamic = get(t, f, maybe);

		if (read != null || t == null || (t is IScriptedType))
			return read;

		/**
		 * `is Enum` rather than asking reflection anything, because reflection is what is dangerous
		 * here. `Type.getEnumName` stood in this place and it ends the hxcpp process for a value that
		 * is not an enum, which was survivable only while this was reached with a resolved type and
		 * nothing else. It is now reached with whatever a name in scope resolved to, and the first
		 * ordinary thing to arrive was a scripted instance with a null field: `t.maybe == null` took
		 * the process down. A value test cannot.
		 */
		if (!(t is Enum))
			return read;

		var names:Array<String> = HaxeType.getEnumConstructs(t);
		if (names == null)
			return read;

		var at:Int = names.indexOf(f);
		return at < 0 ? read : resolveEnumValue(t, at);
	}

	/**
	 * Restores a `Bool` that compiled code handed back as an `Int`.
	 *
	 * @param o The receiver the value came from, either a compiled class or an instance of one.
	 * @param f The member it came from.
	 * @param v The value as reflection produced it.
	 * @return The value, as a `Bool` when that is what it was declared.
	 */
	function boolean(o:Dynamic, f:String, v:Dynamic):Dynamic {
		#if hxscript_cppia
		if (!Std.isOfType(v, Int) || environment == null || !environment.substituting)
			return v;

		var cls:Dynamic = (o is Class) ? o : HaxeType.getClass(o);

		while (cls != null) {
			var name:String = HaxeType.getClassName(cls);
			if (name != null && environment.booleansOf(name).exists(f))
				return (v : Int) != 0;

			cls = HaxeType.getSuperClass(cls);
		}
		#end

		return v;
	}

	/**
	 * Writes field `f` of `o`, honouring properties, `:bypassAccessor`, and static `_Fields_` hosts.
	 * Unwraps a boxed abstract value, and defers if the target is an uninitialized scripted type.
	 *
	 * @param o The object to write to.
	 * @param f The field name.
	 * @param v The value to store.
	 * @return The stored value.
	 */
	function set(o:Dynamic, f:String, v:Dynamic):Dynamic {
		if (hxscript.debug.Metrics.on)
			hxscript.debug.Metrics.writes++;

		if (o == null)
			error(EInvalidAccess(f));

		if (canDefer && o is IScriptedType && !o.initialized)
			throw DDefer;

		checkAccess(o, f);

		o = staticHost(o);

		if (o is ScriptedAbstractValue) {
			var box:ScriptedAbstractValue = cast o;
			return box.owner.setField(box.boxed, f, v);
		}

		if (AbstractTools.isAbstract(v))
			v = v.__a;

		var bypassAccessor:Bool = (getMeta(':bypassAccessor') != null);

		if (Reflect.field(o, f) == null && hasField(o, f) == false) {
			var fields = getFieldsClass((o is Class || o is ScriptedClass) ? Type.getClassName(o) : Type.getEnumName(o));
			if (fields != null)
				(bypassAccessor ? Reflect.setField(fields, f, v) : Reflect.setProperty(fields, f, v));
		} else if (bypassAccessor) {
			Reflect.setField(o, f, v);
		} else {
			Reflect.setProperty(o, f, v);
		}

		return v;
	}

	/**
	 * Whether a class/enum value has a static field or constructor named `f`.
	 *
	 * @param o A class or enum value.
	 * @param f The field/constructor name.
	 * @return True/false for classes and enums, or null when `o` is neither.
	 */
	inline function hasField(o:Dynamic, f:String):Null<Bool> {
		if (o is Class || o is ScriptedClass) {
			return Type.getClassFields(o).contains(f);
		} else if (o is Enum || o is ScriptedEnum) {
			return Type.getEnumConstructs(o).contains(f);
		} else {
			return null;
		}
	}

	/**
	 * Resolves the generated `_Fields_` host class that holds a module's top-level fields.
	 *
	 * @param path The owning type's name.
	 * @return The `_Fields_` host class, or null if there isn't one.
	 */
	inline function getFieldsClass(path:String):Dynamic {
		if (path.endsWith('_Fields_'))
			return null;

		if (path.startsWith('AbstractValue_'))
			path = Type.resolveClass(path).impl;

		var pack = path.substr(0, path.lastIndexOf('.') + 1);
		var name = path.substr(path.lastIndexOf('.') + 1);

		return TypeTools.resolve('${pack}_$name.${name}_Fields_', environment);
	}

	/**
	 * Finds an emulation shim (`Config.callShims`) for method `f` on `o`, walking up `o`'s superclass
	 * chain so a shim registered on a base class covers subclasses too. Handles `o` being a class value
	 * (static-method shims) or an instance.
	 *
	 * @param o The receiver (class value or instance).
	 * @param f The method name.
	 * @return The shim closure, or null if none is registered.
	 */
	function resolveCallShim(o:Dynamic, f:String):(Dynamic, Array<Dynamic>) -> Dynamic {
		if (o == null)
			return null;

		var cls:Dynamic = (o is Class) ? o : HaxeType.getClass(o);
		while (cls != null) {
			var name:String = HaxeType.getClassName(cls);
			if (name != null) {
				var shim = Config.callShims.get(name + '.' + f);
				if (shim != null)
					return shim;
			}
			cls = HaxeType.getSuperClass(cls);
		}
		return null;
	}

	/**
	 * Calls method `f` on `o`: reads the method and invokes it, falling back to a `using` extension
	 * method and then to a registered call shim (for inline-extern methods with no runtime form).
	 *
	 * @param o The receiver.
	 * @param f The method name.
	 * @param args The call arguments (boxed abstracts are unwrapped first).
	 * @return The call result.
	 * @throws InterpException If no method, extension, or shim can be found.
	 */
	function fcall(o:Dynamic, f:String, args:Array<Dynamic>):Dynamic {
		o = staticHost(o);

		var fun:Dynamic = get(o, f);

		if (o != Std || f != 'string') {
			for (i => arg in args)
				args[i] = (AbstractTools.isAbstract(arg) ? arg.__a : arg);
		}

		if (o is Class) {
			var shim = resolveCallShim(o, f);
			if (shim != null)
				return shim(o, args);
		}

		if (!Reflect.isFunction(fun)) {
			/**
			 * A constructor of a host enum, which is not a field of the enum on every target: hxcpp
			 * answers with a function and HashLink answers with nothing, so asking the enum to make
			 * one is what agrees everywhere.
			 */
			if (o is Enum || o is ScriptedEnum) {
				var at:Int = Type.getEnumConstructs(o).indexOf(f);
				if (at >= 0)
					return Type.createEnum(o, f, args);
			}

			for (t in usings) {
				var fun = get(t, f, true);
				if (!Reflect.isFunction(fun))
					continue;

				var scripted:ScriptedClass = (t is ScriptedClass) ? cast t : null;
				if (scripted != null) {
					var argType:CType = scripted.staticArgType(f);
					if (argType != null && !typeMatches(o, argType))
						continue;

					args.unshift(o);
					return Reflect.callMethod(t, fun, args);
				}

				try {
					args.unshift(o);
					return Reflect.callMethod(t, fun, args);
				} catch (e:Dynamic) {
					args.shift();
				}
			}

			var shim = resolveCallShim(o, f);
			if (shim != null)
				return shim(o, args);

			var members:Array<String> = hxscript.error.Hint.membersOfValue(o);
			if (members.length > 0 && members.indexOf(f) < 0)
				error(EUnknownField(o, f));

			error(ECustom('Cannot call ' + hxscript.error.Hint.typeName(o) + '.' + f));
		}

		return boolean(o, f, call(o, fun, args));
	}

	/**
	 * Invokes a function value with a receiver, resolving a `super` mirror to the base constructor
	 * (only inside a constructor).
	 *
	 * @param o The receiver (`this`).
	 * @param f The function value or `super` mirror.
	 * @param args The call arguments (boxed abstracts are unwrapped first).
	 * @return The call result.
	 * @throws InterpException If a `super` call is made where none is valid.
	 */
	function call(o:Dynamic, f:Dynamic, args:Array<Dynamic>):Dynamic {
		if (hxscript.debug.Metrics.on)
			hxscript.debug.Metrics.calls++;

		if (f is Reference) {
			switch (cast(f, Reference)) {
				case RSuper(locals, constructor, rebuilt):
					if (constructor == null) {
						error(EHasNoSuper);
					} else if (!superConstructorAllowed) {
						error(ECustom('Cannot call super constructor outside class constructor'));
					} else {
						f = constructor;

						/**
						 * A rebuilt base's constructor takes the host class's parameters, so the same
						 * placing a `new` of that class gets applies here: `super(label, held)` against
						 * `(label, ?tint, ?held)` means the first and the last.
						 */
						if (rebuilt != null)
							args = ArgumentTools.forConstructor(rebuilt, args);
					}
				default:
			}
		}

		if (f != Std.string) {
			for (i => arg in args)
				args[i] = (AbstractTools.isAbstract(arg) ? arg.__a : arg);
		}

		return Reflect.callMethod(o, f, args);
	}

	/**
	 * The class that owns a scripted class's statics.
	 *
	 * @param o The value a field is being read from, written to, or called on.
	 * @return The compiled class standing in for it, or `o` unchanged.
	 */
	function staticHost(o:Dynamic):Dynamic {
		#if (hxscript_cppia || hxscript_hl)
		if (environment != null && environment.substituting && o is ScriptedClass) {
			var native:Class<Dynamic> = environment.compiled.get((cast o : ScriptedClass).path);
			if (native != null)
				return native;
		}
		#end
		return o;
	}

	/**
	 * Whether a value is an instance of the compiled form of a scripted class.
	 *
	 * With substitution on, a scripted class that was compiled is reached through its compiled form
	 * everywhere, so an `is` against the scripted type has to answer for the compiled one too.
	 *
	 * @param t The scripted type being tested against.
	 * @param e The value.
	 * @return Whether the value is that type's compiled form.
	 */
	function isCompiledAs(t:Dynamic, e:Dynamic):Bool {
		#if (hxscript_cppia || hxscript_hl)
		if (environment == null || !environment.substituting || !(t is ScriptedClass))
			return false;

		var native:Class<Dynamic> = environment.compiled.get((cast t : ScriptedClass).path);
		return native != null && Std.isOfType(e, native);
		#else
		return false;
		#end
	}

	/**
	 * Builds an instance of a type named by path.
	 *
	 * @param cl The type's path as written.
	 * @param args Constructor arguments.
	 * @return The new instance.
	 */
	function cnew(cl:String, args:Array<Dynamic>):Dynamic {
		var c = TypeTools.resolve(cl, environment);

		if (c == null) {
			if (cl == 'Map' || cl == 'haxe.ds.Map')
				return new AnyMap();

			c = resolve(cl);
		}

		if (canDefer && c is IScriptedType && !c.initialized)
			throw DDefer;

		#if (hxscript_cppia || hxscript_hl)
		if (c is ScriptedClass && environment != null && environment.substituting) {
			var native:Class<Dynamic> = environment.compiled.get((cast c : ScriptedClass).path);
			if (native != null)
				return HaxeType.createInstance(native, args);
		}
		#end

		if (c is ScriptedAbstract)
			return (cast c : ScriptedAbstract).create(args);

		var boxed:Dynamic = AbstractTools.construct(c, args);
		if (boxed != null)
			return boxed;

		return Type.createInstance(c, ArgumentTools.forConstructor(c, args));
	}
}

/**
 * An iterator over a scripted object's own `hasNext` and `next`.
 *
 * The two closures are taken once, from the instance's slots, and each already knows its receiver.
 * That is what makes this work where handing the object itself to a `for` does not: the loop calls
 * an ordinary function value rather than dispatching a method name against a native object that
 * never declared one.
 */
private class SlotIterator {
	/** The object's own `hasNext`, bound to it. */
	var more:Dynamic;

	/** The object's own `next`, bound to it. */
	var take:Dynamic;

	/**
	 * @param more The bound `hasNext`.
	 * @param take The bound `next`.
	 */
	public function new(more:Dynamic, take:Dynamic) {
		this.more = more;
		this.take = take;
	}

	/** @return Whether anything is left. */
	public function hasNext():Bool {
		return HaxeReflect.callMethod(null, more, []) == true;
	}

	/** @return The next value. */
	public function next():Dynamic {
		return HaxeReflect.callMethod(null, take, []);
	}
}
