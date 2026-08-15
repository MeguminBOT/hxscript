/** Something to give a `HostShaped` that is not another `HostShaped`, so the two cannot be confused. */
class HostTint {
	public var name:String;

	public function new(name:String) {
		this.name = name;
	}
}

/**
 * A compiled class whose constructor a call can be short in the middle of.
 *
 * `h3d.scene.Mesh` declares `(primitive, ?material, ?parent)` and a 3D project writes `new Mesh(prim,
 * parent)` all day, because a mesh with a default material is the ordinary one. That call is two
 * arguments to a three-parameter constructor, and which parameter is missing is decided by type:
 * Haxe asks whether the second argument is a `Material`, finds it is not, and puts it in `parent`
 * with a `null` left behind it.
 *
 * The shape is the whole fixture, so the same three parameters are here with types nothing can
 * confuse: a required one, an optional one of a type of its own, and one of this class. A binding
 * that goes in order puts the parent in `tint`, and `held` says which of the two happened.
 */
class HostShaped {
	/** What it was named, so a case can tell one instance from another. */
	public var label:String;

	/** The optional in the middle, which a short call means to leave out. */
	public var tint:HostTint;

	/** The parameter behind it, which a short call means to fill. */
	public var held:HostShaped;

	public function new(label:String, ?tint:HostTint, ?held:HostShaped) {
		this.label = label;
		this.tint = tint;
		this.held = held;
	}

	/** @return What was placed where, on one line. */
	public function shape():String {
		return label + '/' + (tint == null ? '-' : tint.name) + '/' + (held == null ? '-' : held.label);
	}
}
