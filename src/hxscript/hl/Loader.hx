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

#if (hl && hxscript_hl)
import haxe.io.Bytes;

/** A module the VM has read and jitted, kept alive for as long as anything can call into it. */
typedef Loaded = hl.Abstract<"hxs_module">;

/**
 * Why a build can or cannot run compiled scripts.
 *
 * Three of the four are things a host may want to put in front of whoever is running it, since they
 * are all fixable and each is fixed differently. `available` is the same question asked as a
 * boolean, for the far more common case of not caring which.
 */
enum abstract Availability(Int) from Int to Int {
	/** The loader is here and agrees with the libhl it is running against. */
	var Usable = 0;

	/**
	 * The native module carries no loader.
	 *
	 * Either because the architecture has none, which `architecture` names and nothing here fixes,
	 * or because the build asked for none with `-D hxscript_no_jit`, which building again without it
	 * does.
	 */
	var NoLoader = 1;

	/** The loader is here and was built against a different hashlink than the one running. */
	var Disagrees = 2;

	/**
	 * There is no native module.
	 *
	 * Only reachable on HL/JIT, where the natives are marked optional and resolve to stubs when
	 * `hxscript.hdll` is absent. An HL/C program links them or fails to link at all.
	 */
	var NotLinked = 3;
}

/**
 * Which architecture the native module was built for, as `hxs_arch.h` decides it.
 *
 * Only 64 bit is named. hashlink's jit reaches 32 bit x86 as well and this library does not go
 * there, so a 32 bit build reads as `Unrecognised` and interprets, which is what every architecture
 * with no loader does.
 */
enum abstract Architecture(Int) from Int to Int {
	/** Neither of the two below, which is every 32 bit architecture and everything unnamed. */
	var Unrecognised = 0;

	/** The one architecture the carried loader compiles for. */
	var X86_64 = 1;

	/** 64 bit ARM, which has no loader yet, so everything on it is interpreted. */
	var Arm64 = 2;
}

/**
 * Reaches HashLink's bytecode loader, which the VM does not otherwise offer.
 *
 * `hl_code_read` and `hl_module_init` are compiled into `hl.exe` rather than into `libhl`, so there
 * is no way to them from Haxe. `hxscript.hdll` carries hashlink's own copies and these are its entry
 * points; `src/hxscript/hl/native/build.sh` builds it, and a build with `-D hxscript_hl` builds it
 * for itself.
 *
 * Every native names the library as `?hxscript`, which is what makes shipping it a choice rather
 * than a condition of starting. HashLink resolves a module's natives before any of its code runs, so
 * without the mark a program built to be able to compile scripts would refuse to run at all on a
 * machine that had not got the module. With it, an absent or unusable one leaves these bound to a
 * stub, `available` says so, and everything is interpreted.
 */
class Loader {
	/** Whether the module is here and agrees with this VM, which is what decides if this can be used. */
	public static var available(get, never):Bool;

	/** The same question asked so that a negative answer says which negative it is. */
	public static var availability(get, never):Availability;

	/**
	 * Which architecture the module was built for, or null when there is no module or it predates
	 * being asked.
	 *
	 * Reported rather than acted on, the way `builtFor` is. What it decides is already in
	 * `availability`; this is for a host that wants to name the reason rather than restate it.
	 */
	public static var architecture(get, never):Null<Architecture>;

	static var probed:Null<Availability> = null;

	static var built:Null<Architecture> = null;

	static var askedBuilt:Bool = false;

	static function get_available():Bool {
		return get_availability() == Usable;
	}

	/**
	 * Works out which of the four this is, once.
	 *
	 * `state` is asked for separately from `read` because a module built before it existed is a real
	 * thing to run into: it answers `agrees` and nothing else, and treating that as no module at all
	 * would interpret everything on a machine that had gone to the trouble of building one.
	 */
	static function get_architecture():Null<Architecture> {
		if (!askedBuilt) {
			askedBuilt = true;

			try {
				if (hl.Api.isPrimLoaded(builtArch))
					built = (builtArch() : Architecture);
			} catch (e:Dynamic) {
				built = null;
			}
		}

		return built;
	}

	static function get_availability():Availability {
		if (probed == null) {
			try {
				if (!hl.Api.isPrimLoaded(read))
					probed = NotLinked;
				else if (hl.Api.isPrimLoaded(state))
					probed = (state() : Availability);
				else
					probed = agrees() ? Usable : Disagrees;
			} catch (e:Dynamic) {
				probed = NotLinked;
			}
		}
		return probed;
	}

	/**
	 * @return One sentence naming what is wrong and what would fix it, or null when nothing is.
	 *
	 * For a host that reports rather than guesses. Everything here is already knowable from
	 * `availability`; this is the wording, so that every host does not write its own.
	 */
	public static function why():Null<String> {
		return switch (get_availability()) {
			case Usable:
				null;

			case NoLoader:
				switch (get_architecture()) {
					case X86_64:
						'the loader was left out of this build, which is what -D hxscript_no_jit asks for; '
						+ 'build the module again without it';

					case null:
						'this build carries no loader, because the carried one is x86-64 only; '
						+ 'every script is interpreted';

					case on:
						'this build carries no loader, because the carried one is x86-64 only and this is '
						+ spell(on)
						+ '; every script is interpreted';
				}

			case Disagrees:
				'the native module was built against hashlink '
				+ version(builtFor())
				+ ' and does not match the one running; '
				+ 'rebuild it against this HashLink';

			case NotLinked:
				'there is no hxscript.hdll beside what is running; ' + 'build one with src/hxscript/hl/native/build.sh';
		}
	}

	/**
	 * @param on An architecture.
	 * @return It as this library names them.
	 */
	static function spell(on:Architecture):String {
		return switch (on) {
			case X86_64: 'x86-64';
			case Arm64: 'arm64';
			case Unrecognised: 'neither x86-64 nor arm64';
		}
	}

	/**
	 * @param packed What `built_for` reports, which is hashlink's own `HL_VERSION`.
	 * @return The version as hashlink tags them.
	 *
	 * One byte each, so 0x011000 is 1.16.0.
	 */
	static function version(packed:Int):String {
		if (packed < 0)
			return 'an unknown version';

		return ((packed >> 16) & 0xFF) + '.' + ((packed >> 8) & 0xFF) + '.' + (packed & 0xFF);
	}

	/**
	 * @return The hashlink the module was built against, or -1 when there is no module.
	 *
	 * Reported rather than acted on. A module that disagrees with the VM makes `available` false on
	 * its own; this is for a host that wants to say which two things did not match.
	 */
	public static function builtFor():Int {
		try {
			return hl.Api.isPrimLoaded(builtVersion) ? builtVersion() : -1;
		} catch (e:Dynamic) {
			return -1;
		}
	}

	/**
	 * Reads, links and jits a module.
	 *
	 * @param bytes The module.
	 * @param at Which of its types stand for a class the world already has, by index.
	 * @param bases What each of those is, in the same order.
	 * @return It, or null when it could not be read; `error` then says why.
	 */
	public static function load(bytes:Bytes, ?at:Array<Int>, ?bases:Array<hl.Type>):Null<Loaded> {
		if (!wired) {
			wired = true;
			try {
				var through:hl.NativeArray<Dynamic> = new hl.NativeArray<Dynamic>(11);
				through[0] = Runtime.fetch;
				through[1] = Runtime.store;
				through[2] = Runtime.fetchInt;
				through[3] = Runtime.fetchFloat;
				through[4] = Runtime.dispatch0;
				through[5] = Runtime.dispatch1;
				through[6] = Runtime.dispatch2;
				through[7] = Runtime.dispatch3;
				through[8] = Runtime.storeInt;
				through[9] = Runtime.storeFloat;
				through[10] = Runtime.memberOf;
				setFallback(through);
			} catch (e:Dynamic) {}
		}

		var count:Int = (at == null || bases == null) ? 0 : (at.length < bases.length ? at.length : bases.length);
		var indexes:hl.NativeArray<Int> = new hl.NativeArray<Int>(count);
		var supers:hl.NativeArray<hl.Type> = new hl.NativeArray<hl.Type>(count);

		for (i in 0...count) {
			indexes[i] = at[i];
			supers[i] = bases[i];
		}

		return read(@:privateAccess bytes.b, bytes.length, indexes, supers);
	}

	/**
	 * @param module A loaded module.
	 * @param index One of its type-table entries.
	 * @return That type, which is what a class value is made against.
	 */
	public static function typeAt(module:Loaded, index:Int):Null<hl.Type> {
		return typeOf(module, index);
	}

	/**
	 * @param base A class the world already has.
	 * @return How many entries its method table holds, which is where one it does not have goes.
	 */
	public static function protoCount(base:hl.Type):Int {
		return protos(base);
	}

	/**
	 * @param base A class the world already has.
	 * @return How many fields it has, counting the ones it inherits, which is where a new one goes.
	 */
	public static function fieldCount(base:hl.Type):Int {
		return fields(base);
	}

	/**
	 * @param base A class the world already has.
	 * @param name A method name.
	 * @return Where it sits in that class's method table, or -1 when nothing up its chain declares it.
	 */
	public static function protoAt(base:hl.Type, name:String):Int {
		return protoOf(base, @:privateAccess name.bytes);
	}

	/**
	 * @param base A class the world already has.
	 * @param name A field name.
	 * @return Whether that class, or anything it extends, already declares it.
	 */
	public static function declares(base:hl.Type, name:String):Bool {
		return hasField(base, @:privateAccess name.bytes);
	}

	/**
	 * @param base A class the world already has.
	 * @param self An instance of something that extends it.
	 * @param name A method name.
	 * @return That base's own version of the method, bound to the instance, or null when it has none.
	 */
	public static function superMethod(base:hl.Type, self:Dynamic, name:String):Dynamic {
		return above(base, self, @:privateAccess name.bytes);
	}

	/**
	 * @param base A class the world already has.
	 * @param name A method name.
	 * @return The shape it keeps that method in, as [nargs, return, each argument] by type kind and
	 *         counting the receiver, or null when nothing up its chain declares it.
	 */
	/**
	 * @param base A class the world already has.
	 * @param name A field name.
	 * @return The type kind it keeps that field as, or -1 when nothing up its chain declares it.
	 */
	public static function fieldKind(base:hl.Type, name:String):Int {
		return kindOf(base, @:privateAccess name.bytes);
	}

	public static function protoShape(base:hl.Type, name:String):Null<Array<Int>> {
		var found:hl.NativeArray<Int> = shapeOf(base, @:privateAccess name.bytes);
		return found == null ? null : [for (i in 0...found.length) found[i]];
	}

	/** Whether the runtime has been given the world's reader and writer for what it cannot resolve. */
	static var wired:Bool = false;

	/**
	 * Wraps one of a loaded module's functions as an ordinary function value.
	 *
	 * What comes back is a closure like any other, which is what lets a compiled function stand in
	 * for an interpreted one without anything above having to know.
	 *
	 * @param module The module.
	 * @param findex The function's index.
	 * @return The closure, or null when there is no such function.
	 */
	public static function bind(module:Loaded, findex:Int):Dynamic {
		return closure(module, findex);
	}

	/** @return The function index the module names as its entry point, or -1 when there is none. */
	public static function entryIndex(module:Loaded):Int {
		return entry(module);
	}

	/**
	 * Puts a value in one of a loaded module's globals.
	 *
	 * @param module The module.
	 * @param index The global's index.
	 * @param value What to put there.
	 */
	public static function set(module:Loaded, index:Int, value:Dynamic):Void {
		setGlobal(module, index, value);
	}

	/** The bit `hooks` sets when a load took a field of `hl_setup` this build has never heard of. */
	public static inline var HOOK_UNKNOWN:Int = 128;

	/**
	 * @return Which fields of libhl's `hl_setup` loading has taken, as bits.
	 *
	 * All of them are given back or chained, so `HOOK_UNKNOWN` is a test failing rather than a fault.
	 */
	public static function hooks():Int {
		try {
			return hl.Api.isPrimLoaded(hookBits) ? hookBits() : 0;
		} catch (e:Dynamic) {
			return 0;
		}
	}

	/**
	 * Reserves an inline cache for one field access, as a constant the bytecode carries.
	 *
	 * A property is the reason the accessor is asked for here rather than found there. A property has
	 * storage of its own name, so a cache that only looked for a field would find it and write past
	 * the accessor: `o.x = 3` on a framework object would store the three and never tell the framework
	 * it moved. Which accessor matters is decided by the side, and only the compiler knows the side,
	 * so it says so when it reserves the cache.
	 *
	 * @param hash What the field name hashes to, which the cache resolves against.
	 * @param accessor What the accessor this side would go through hashes to, or 0 when this access
	 *        cannot go through one.
	 * @return The site, or -1 when this build has no runtime to hold one.
	 */
	public static function site(hash:Int, accessor:Int = 0):Int {
		return nextSite(hash, accessor);
	}

	/**
	 * @param name A field name.
	 * @return What HashLink hashes it to, asked for rather than reimplemented here.
	 */
	public static function hash(name:String):Int {
		return hashOf(@:privateAccess name.bytes);
	}

	/** @return Why the last `load` failed, or null when it did not. */
	public static function error():Null<String> {
		var raw:hl.Bytes = lastError();
		return raw == null ? null : @:privateAccess String.fromUTF8(raw);
	}

	@:hlNative("?hxscript", "load")
	static function read(data:hl.Bytes, size:Int, at:hl.NativeArray<Int>, bases:hl.NativeArray<hl.Type>):Loaded {
		return null;
	}

	@:hlNative("?hxscript", "type_of") static function typeOf(module:Loaded, index:Int):hl.Type {
		return null;
	}

	@:hlNative("?hxscript", "proto_count") static function protos(base:hl.Type):Int {
		return -1;
	}

	@:hlNative("?hxscript", "field_count") static function fields(base:hl.Type):Int {
		return -1;
	}

	@:hlNative("?hxscript", "proto_index") static function protoOf(base:hl.Type, name:hl.Bytes):Int {
		return -1;
	}

	@:hlNative("?hxscript", "has_field") static function hasField(base:hl.Type, name:hl.Bytes):Bool {
		return false;
	}

	@:hlNative("?hxscript", "super_method") static function above(base:hl.Type, self:Dynamic, name:hl.Bytes):Dynamic {
		return null;
	}

	@:hlNative("?hxscript", "proto_shape") static function shapeOf(base:hl.Type, name:hl.Bytes):hl.NativeArray<Int> {
		return null;
	}

	@:hlNative("?hxscript", "field_kind") static function kindOf(base:hl.Type, name:hl.Bytes):Int {
		return -1;
	}

	@:hlNative("?hxscript", "closure") static function closure(module:Loaded, findex:Int):Dynamic {
		return null;
	}

	@:hlNative("?hxscript", "entry_index") static function entry(module:Loaded):Int {
		return -1;
	}

	@:hlNative("?hxscript", "set_global") static function setGlobal(module:Loaded, index:Int, value:Dynamic):Void {}

	@:hlNative("?hxscript", "last_error") static function lastError():hl.Bytes {
		return null;
	}

	@:hlNative("?hxscript", "agrees") static function agrees():Bool {
		return false;
	}

	@:hlNative("?hxscript", "state") static function state():Int {
		return Availability.NotLinked;
	}

	@:hlNative("?hxscript", "built_for") static function builtVersion():Int {
		return -1;
	}

	@:hlNative("?hxscript", "arch") static function builtArch():Int {
		return Architecture.Unrecognised;
	}

	@:hlNative("?hxscript", "hooks") static function hookBits():Int {
		return 0;
	}

	@:hlNative("?hxscript", "site") static function nextSite(hash:Int, accessor:Int):Int {
		return -1;
	}

	@:hlNative("?hxscript", "fallback")
	static function setFallback(given:hl.NativeArray<Dynamic>):Void {}

	@:hlNative("?hxscript", "hash") static function hashOf(name:hl.Bytes):Int {
		return 0;
	}
}
#end
