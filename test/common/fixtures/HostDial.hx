/**
 * A host class whose statics are named without naming it.
 *
 * `import HostDial.turns` puts a name in scope that is a field of something rather than a type, and
 * the interpreter records that in the same table it records types in, as a mirror rather than as a
 * value. Anything reading that table to find out what a name means has to materialize the mirror or
 * it gets the mirror; and a static something writes has to stay readable afterwards rather than be
 * taken once and kept, which is the other half of the same question.
 */
class HostDial {
	/** A static nothing writes, so a backend that takes it once is still right about it. */
	public static var step:Int = 3;

	/** A static a script writes, so a backend that takes it once is wrong about it. */
	public static var turns:Int = 0;
}
