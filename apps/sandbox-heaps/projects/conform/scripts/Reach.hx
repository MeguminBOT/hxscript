import h2d.Object;

/**
 * What a script can reach of the host, which is a property of the build rather than of the language.
 *
 * A script calls the host by reflection, so the compiler cannot see the call and dead code
 * elimination removes whatever nothing else referenced. That is per member, not per class, so these
 * cases are worth having one at a time: what they report is this binary, and a case that throws in
 * both passes is a fact about the build rather than a disagreement.
 *
 * `hxd.Math.iabs` is deliberately here: it is `inline`, which is the other way a member ends up with
 * no runtime form.
 */
class Reach {
	/** @return The names of this module's cases. */
	public static function cases():Array<String> {
		return ['timerStatic', 'mathInline', 'point', 'blendEnum', 'objectMap', 'objectArray', 'iterate'];
	}

	/** A plain static variable of the host. */
	public static function timerStatic():Dynamic {
		return hxd.Timer.dt > 0;
	}

	/** A static that is `inline`, so whether it exists at runtime is a question about the build. */
	public static function mathInline():Dynamic {
		return hxd.Math.iabs(-3);
	}

	/**
	 * A native abstract, constructed.
	 *
	 * **Expected to fail, in both passes, and that is what it is here for.** `h2d.col.Point` is an
	 * `@:forward abstract` whose `new` is `inline`, so there is no constructor at runtime to call: the
	 * wrapper falls back to boxing the first argument and reports that it cannot make a `Point` out of
	 * an `Int`. Reading and passing one that heaps hands back works; making one by name does not, and
	 * a case that says so is worth more than one that avoids the question.
	 */
	public static function point():Dynamic {
		var p:h2d.col.Point = new h2d.col.Point(3, 4);
		return p.x + p.y;
	}

	/** A constructor of a host enum, named through its type. */
	public static function blendEnum():Dynamic {
		var mode:h2d.BlendMode = h2d.BlendMode.Add;
		return Std.string(mode);
	}

	/** Host instances carried in a map, which is the container a project reaches for most. */
	public static function objectMap():Dynamic {
		var all:Map<String, Object> = new Map<String, Object>();
		all.set('one', new Object());
		return all.exists('one');
	}

	/** Host instances in an array, read back by index. */
	public static function objectArray():Dynamic {
		var all:Array<Object> = [new Object(), new Object()];
		all[0].x = 5;
		return all[0].x + all.length;
	}

	/** A `for` over host instances, writing each one. */
	public static function iterate():Dynamic {
		var all:Array<Object> = [new Object(), new Object(), new Object()];
		var total:Float = 0;

		for (one in all) {
			one.x = 2;
			total += one.x;
		}

		return total;
	}
}
