package hxscript.runtime;

import haxe.ds.StringMap;
import hxscript.types.AbstractTools;

/**
 * One place a compiled module reaches a host-bound name, resolved once.
 *
 * A site is what the emitter writes into the bytecode: an index, rather than the module and the name
 * it stands for. Interning them that way is most of what a read costs, since two string constants
 * have to be pushed as arguments where one integer does not.
 */
@:structInit
class Site {
	/** The interpreter to resolve against, re-pointed whenever a world claims the module. */
	public var scope:Null<Interp>;

	/** The name, as the script wrote it. */
	public var name:String;

	/** The module this site belongs to, for re-pointing it and for naming it in a complaint. */
	public var key:String;

	/** Which pool holds this name's fast copy, or -1 when it has none. */
	public var kind:Int = -1;

	/** Which slot of that pool, meaningless when `kind` is -1. */
	public var slot:Int = -1;
}

/**
 * What a bare name means when the host put it there rather than the script.
 *
 * A host binds values into scripts through `Environment.variables`, `Module.variables`,
 * `Config.globalVariables`, `Config.globalStatics`, or by overriding `resolve`/`setVar` on an
 * `Interp` of its own. An interpreter has all five in reach; compiled code has none of them, so
 * every one of those names used to refuse its module and take everything naming that module with it.
 *
 * **Resolving through the module's own interpreter rather than through a map is the point.** One
 * hook then covers all five surfaces at once, including the overrides, and a read and a write land
 * on the same table the interpreter reads and writes, so a compiled module and an interpreted one
 * never disagree about what a global holds.
 *
 * The typed accessors exist because a helper's declared return type is what decides the register
 * type on the other side of the call. `getInt` hands back a real `Int` where `get` hands back a
 * boxed `Dynamic`, and `getBool` a real `Bool`, which is also how a boolean global escapes being
 * flattened to an integer on the way through (see HXCPP-ISSUES.md, 8).
 */
@:keep
@:access(hxscript.runtime.Interp)
class Globals {
	/** Every site any module has reserved, indexed by the number written into the bytecode. */
	static var sites:Array<Site> = [];

	/** The site each module and name was given, so a module compiled twice reuses its own. */
	static var reserved:StringMap<Int> = new StringMap();

	/** Which sites belong to each module, so binding a world re-points them together. */
	static var byKey:StringMap<Array<Int>> = new StringMap();

	/**
	 * Reserves the site a name gets in one module, at emit time.
	 *
	 * Process-wide rather than per batch, because the index is written into bytecode that outlives
	 * the batch: a module compiled once and handed to a second world keeps the indices it was built
	 * with, so those indices have to still mean what they meant.
	 *
	 * @param key The module's path.
	 * @param name The name as the script wrote it.
	 * @return The site index to write into the call.
	 */
	public static function reserve(key:String, name:String):Int {
		var at:String = key + ' ' + name;
		var known:Null<Int> = reserved.get(at);

		if (known != null)
			return known;

		var index:Int = sites.length;
		sites.push({scope: null, name: name, key: key});
		reserved.set(at, index);

		var mine:Null<Array<Int>> = byKey.get(key);
		if (mine == null) {
			mine = [];
			byKey.set(key, mine);
		}

		mine.push(index);
		return index;
	}

	/** How many slots of each pool have been handed out. */
	static var taken:Array<Int> = [for (pool in hxscript.macro.Slots.POOLS) 0];

	/** Sites that have a slot, so a rebind refills them and a write can find them. */
	static var slotted:StringMap<Array<Int>> = new StringMap();

	/**
	 * Claims a fast copy for a name, at emit time.
	 *
	 * @param at The site index.
	 * @param kind Which pool its type wants.
	 * @return The slot's field name for the emitter to read, or null when the pool is used up and the
	 *         name has to keep going through the interpreter.
	 */
	public static function claim(at:Int, kind:Int):Null<String> {
		var site:Site = sites[at];

		if (site.kind >= 0)
			return hxscript.macro.Slots.nameOf(site.kind, site.slot);

		if (taken[kind] >= GlobalSlots.PER_TYPE)
			return null;

		site.kind = kind;
		site.slot = taken[kind]++;

		var mine:Null<Array<Int>> = slotted.get(site.key);
		if (mine == null) {
			mine = [];
			slotted.set(site.key, mine);
		}

		mine.push(at);
		return hxscript.macro.Slots.nameOf(site.kind, site.slot);
	}

	/**
	 * Puts a value into a site's slot.
	 *
	 * @param site The site.
	 * @param value What its name now holds.
	 * @return Whether the slot could hold it.
	 */
	static function put(site:Site, value:Dynamic):Bool {
		switch (site.kind) {
			case 0:
				if (!(value is Int))
					return false;
				GlobalSlots.fillInt(site.slot, value);
			case 1:
				if (!(value is Float))
					return false;
				GlobalSlots.fillFloat(site.slot, value);
			case 2:
				if (!(value is Bool))
					return false;
				GlobalSlots.fillBool(site.slot, value);
			case 3:
				if (value != null && !(value is String))
					return false;
				GlobalSlots.fillString(site.slot, value);
			case _:
				return false;
		}

		return true;
	}

	/**
	 * Refills every slot a module owns, from what its interpreter holds now.
	 *
	 * @param key The module's path.
	 */
	static function refill(key:String):Void {
		var mine:Null<Array<Int>> = slotted.get(key);
		if (mine == null)
			return;

		for (at in mine) {
			var site:Site = sites[at];
			if (site.scope == null)
				continue;

			/**
			 * A name nothing holds yet is left alone rather than reported. That is what a host declaring
			 * a name in `Compiler.globalNames` and binding it after the compile looks like, and the
			 * write that binds it is what fills the slot.
			 */
			if (!site.scope.isResolvable(site.name))
				continue;

			var held:Dynamic = AbstractTools.underlying(try site.scope.resolve(site.name) catch (e:Dynamic) null);

			if (!put(site, held))
				mismatch(at, poolName(site.kind), held);
		}
	}

	/**
	 * @param kind Which pool.
	 * @return The type it holds, for a complaint.
	 */
	static inline function poolName(kind:Int):String {
		return hxscript.macro.Slots.POOLS[kind].type;
	}

	/**
	 * Told by a bindings table that one of its names has been written.
	 *
	 * The whole reason `Bindings` exists. A slot is a copy, so it is only sound while every write
	 * reaches it, and a host writing `module.variables.set(...)` is an ordinary documented thing to do.
	 *
	 * **A write is also where a changed type is reported**, rather than the read that would come
	 * later. A slot cannot hold a value of another kind, and it cannot signal that it is holding a
	 * stale one either, so the choice is between saying so here and letting a read answer with what
	 * the name used to hold. Here is also simply the better place: it names the write that broke the
	 * contract instead of some read far away that only suffered from it.
	 *
	 * @param scope The interpreter whose table was written.
	 * @param name The name written.
	 * @param value Its new value.
	 */
	public static function wrote(scope:Interp, name:String, value:Dynamic):Void {
		var mine:Null<Array<Int>> = slotted.get(scope.globalsKey);
		if (mine == null)
			return;

		for (at in mine) {
			var site:Site = sites[at];

			if (site.name != name || site.scope != scope)
				continue;

			var held:Dynamic = AbstractTools.underlying(value);

			if (!put(site, held))
				mismatch(at, poolName(site.kind), held);
		}
	}

	/**
	 * Points a compiled module's sites at the interpreter they belong to.
	 *
	 * Called once per module as it loads, and again whenever a world binds a module that was compiled
	 * for an earlier one: the compiled class is shared for the life of the process, so the latest
	 * world to claim it is the one its globals resolve against.
	 *
	 * @param key The module's path, as the emitter reserved its sites under.
	 * @param interp The interpreter holding that module's names.
	 */
	public static function bind(key:String, interp:Interp):Void {
		var mine:Null<Array<Int>> = byKey.get(key);
		if (mine == null)
			return;

		for (index in mine)
			sites[index].scope = interp;

		/**
		 * The table starts telling `wrote` only now, so a world that never compiles pays nothing, and
		 * the key is recorded on the interpreter because a write arrives holding the table rather than
		 * the module it belongs to.
		 */
		interp.globalsKey = key;
		@:privateAccess interp.variables.watcher = interp;

		refill(key);
	}

	/** Unbinds every site, for a host starting its scripts over. */
	public static function reset():Void {
		for (site in sites)
			site.scope = null;
	}

	/**
	 * @param at The site index.
	 * @return The site, once it is certain something answers for it.
	 */
	static inline function siteAt(at:Int):Site {
		var found:Site = sites[at];

		if (found.scope == null)
			Raise.custom('Cannot reach ' + found.name + ': module ' + found.key + ' has no interpreter bound');

		return found;
	}

	/**
	 * Reads a host-bound name.
	 *
	 * Opened to the underlying value, because a host abstract is held by compiled code as the value
	 * itself rather than as the wrapper an interpreter carries, the same way `Construct.value` hands
	 * one back.
	 *
	 * @param at The site index.
	 * @return Its value.
	 */
	public static function get(at:Int):Dynamic {
		var site:Site = siteAt(at);
		return AbstractTools.underlying(site.scope.resolve(site.name));
	}

	/**
	 * @param at The site index.
	 * @return Its value as an `Int`.
	 * @throws InterpException If it no longer holds one.
	 */
	public static function getInt(at:Int):Int {
		var held:Dynamic = get(at);

		if (!(held is Int))
			mismatch(at, 'Int', held);

		return held;
	}

	/**
	 * @param at The site index.
	 * @return Its value as a `Float`. An `Int` counts, the way it does anywhere a `Float` is wanted.
	 * @throws InterpException If it holds neither.
	 */
	public static function getFloat(at:Int):Float {
		var held:Dynamic = get(at);

		if (!(held is Float))
			mismatch(at, 'Float', held);

		return held;
	}

	/**
	 * @param at The site index.
	 * @return Its value as a `Bool`.
	 * @throws InterpException If it no longer holds one.
	 */
	public static function getBool(at:Int):Bool {
		var held:Dynamic = get(at);

		if (!(held is Bool))
			mismatch(at, 'Bool', held);

		return held;
	}

	/**
	 * @param at The site index.
	 * @return Its value as a `String`, null included, since a `String` may hold one.
	 * @throws InterpException If it holds something that is not a string.
	 */
	public static function getString(at:Int):String {
		var held:Dynamic = get(at);

		if (held != null && !(held is String))
			mismatch(at, 'String', held);

		return held;
	}

	/**
	 * Writes a host-bound name, through the same path an interpreted assignment takes.
	 *
	 * @param at The site index.
	 * @param v The value to store.
	 * @return The value stored.
	 */
	public static function set(at:Int, v:Dynamic):Dynamic {
		var site:Site = siteAt(at);
		return site.scope.setVar(site.name, v);
	}

	/** @return The value stored, as an `Int`. */
	public static function setInt(at:Int, v:Int):Int {
		set(at, v);
		return v;
	}

	/** @return The value stored, as a `Float`. */
	public static function setFloat(at:Int, v:Float):Float {
		set(at, v);
		return v;
	}

	/** @return The value stored, as a `Bool`. */
	public static function setBool(at:Int, v:Bool):Bool {
		set(at, v);
		return v;
	}

	/** @return The value stored, as a `String`. */
	public static function setString(at:Int, v:String):String {
		set(at, v);
		return v;
	}

	/**
	 * Reports a global whose type is no longer the one it was compiled against.
	 *
	 * The emitter reads what a name holds while it compiles and picks the accessor from it, so a host
	 * that rebinds the name to another kind of value afterwards has changed what the compiled code
	 * was built for. Said outright rather than coerced: coercing would make a compiled read answer
	 * something the same interpreted read would not, which is the one thing worth refusing over.
	 *
	 * @param at The site index.
	 * @param wanted The type it was compiled as.
	 * @param held What it holds now.
	 */
	static function mismatch(at:Int, wanted:String, held:Dynamic):Void {
		var name:String = sites[at].name;
		var pin:String = name + ':Dynamic';

		Raise.custom('Global $name was compiled as $wanted and now holds '
			+ (held == null ? 'null' : typeNameOf(held))
			+ '; pin it with Compiler.globalNames = ["$pin"] to read it untyped');
	}

	/**
	 * @param held A value.
	 * @return A readable name for what it is.
	 */
	static function typeNameOf(held:Dynamic):String {
		return switch (Type.typeof(held)) {
			case TInt: 'Int';
			case TFloat: 'Float';
			case TBool: 'Bool';
			case TFunction: 'a function';
			case TObject: 'an object';
			case TClass(c): Type.getClassName(c);
			case TEnum(e): Type.getEnumName(e);
			case _: 'something else';
		}
	}
}
