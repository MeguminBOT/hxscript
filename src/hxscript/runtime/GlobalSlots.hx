package hxscript.runtime;

/**
 * Real typed statics for compiled code to read a host-bound name out of.
 *
 * **A typed static is the only spelling that costs nothing.** Measured over two million reads with
 * the JIT on: reading an `Int`, `Float`, `Bool` or `String` static is 2.3ns, the same as reading a
 * local, while reaching the same name through the interpreter is 92ns and reading a `Dynamic` static
 * is ten times a typed one. The type is what makes the difference, because it decides whether the
 * value lands in a register or is boxed on the way.
 *
 * Nothing can create a static at runtime, so they are declared here up front and handed out. A pool
 * per type, because a slot's type is the whole point of it; a name whose type has no pool, or whose
 * pool is used up, keeps the interpreter call and is no worse than it was.
 *
 * The pool is filled by `Globals`, which is also what keeps it honest: a slot is a copy, and every
 * write to the table it was copied from reaches it before anything can read the stale value.
 */
@:keep
@:build(hxscript.macro.Slots.build())
class GlobalSlots {
	/**
	 * How many names of each type can be held this way.
	 *
	 * Generous rather than tuned: a slot costs one static field in the binary and nothing at all at
	 * runtime until something is put in it, and running out means a name quietly goes back to being
	 * as slow as it used to be, which is hard to notice and annoying to diagnose.
	 */
	public static inline var PER_TYPE:Int = 256;
}
