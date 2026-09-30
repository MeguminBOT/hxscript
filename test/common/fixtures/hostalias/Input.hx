package hostalias;

import hostalias.Reader as Reader;

/**
 * A bridged base whose constructor names another type through an import alias.
 *
 * Generating the bridge has to compile. The alias is what used to make it fail: the signature was
 * emitted as `hostalias.Input.Reader`, and this module does not define that type.
 */
class Input {
	public var reader:Reader;

	public function new(reader:Reader) {
		this.reader = reader;
	}

	public function value():Int {
		return reader.n;
	}
}
