package hostalias;

/**
 * The type an import alias points at.
 *
 * `Input` names it through `import hostalias.Reader as Reader`. That alias is a private typedef
 * stored on `Input`'s own module, and a bridge that reprints the typedef's path asks `Input` for a
 * type called `Reader`.
 */
class Reader {
	public var n:Int = 1;

	public function new() {}
}
