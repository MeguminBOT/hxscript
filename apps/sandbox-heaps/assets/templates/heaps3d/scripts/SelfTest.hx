import h3d.Matrix;
import h3d.Quat;
import h3d.Vector;
import h3d.col.Bounds;
import h3d.mat.Material;
import h3d.prim.Cube;
import h3d.scene.Mesh;
import h3d.scene.Object;

/**
 * What a 3D project reaches, asked as a list.
 *
 * `--conform heaps3d` runs each of these interpreted and again compiled and compares. The point is
 * not the arithmetic: it is that every type named here has a runtime form a script can reach. A
 * heaps type that is an `@:forward abstract` has no class to resolve unless the setup made it one,
 * and the two most used in 3D, `h3d.Vector` and `h3d.Matrix`, are exactly that.
 */
class SelfTest {
	public static function cases():Array<String> {
		return [
			'vector', 'vectorMaths', 'matrix', 'quat', 'bounds', 'primitives', 'mesh', 'material', 'nested', 'moved',
			'stepped', 'extended', 'extendedMoved', 'extendedOwn', 'extendedMesh', 'extendedLight'
		];
	}

	/** The type every 3D position is written in, constructed and read. */
	public static function vector():Dynamic {
		var v:Vector = new Vector(1, 2, 3);
		return v.x + ',' + v.y + ',' + v.z;
	}

	/** Its arithmetic, which is what a project actually calls. */
	public static function vectorMaths():Dynamic {
		var a:Vector = new Vector(3, 4, 0);
		var b:Vector = new Vector(1, 0, 0);

		return Math.round(a.length()) + ' ' + Math.round(a.dot(b));
	}

	/** A matrix, made and asked what it holds. */
	public static function matrix():Dynamic {
		var m:Matrix = new Matrix();
		m.identity();
		m.translate(2, 3, 4);

		var out:Vector = m.getPosition();
		return out.x + ',' + out.y + ',' + out.z;
	}

	/** A quaternion, which is a plain class rather than an abstract and so a different path. */
	public static function quat():Dynamic {
		var q:Quat = new Quat();
		q.initRotation(0, 0, Math.PI);

		return Math.round(Math.abs(q.z) * 100) / 100;
	}

	/** Bounds, which every collision test is written in. */
	public static function bounds():Dynamic {
		var b:Bounds = new Bounds();
		b.addPos(0, 0, 0);
		b.addPos(2, 4, 6);

		return b.xSize + ',' + b.ySize + ',' + b.zSize;
	}

	/** The three primitives a first project builds, each of them really built. */
	public static function primitives():Dynamic {
		var cube:h3d.prim.Cube = new Cube(1, 1, 1, true);
		var sphere:h3d.prim.Sphere = new h3d.prim.Sphere(1, 8, 6);
		var cylinder:h3d.prim.Cylinder = new h3d.prim.Cylinder(8, 1, 2);

		return (cube != null) + ' ' + (sphere != null) + ' ' + (cylinder != null);
	}

	/** A mesh in a scene graph, which is the object a project spends its time on. */
	public static function mesh():Dynamic {
		var root:Object = new Object();
		var m:Mesh = new Mesh(new Cube(1, 1, 1, true), root);

		return root.numChildren + ' ' + (m.material != null);
	}

	/** A material's colour, which is a `Vector` reached through the mesh. */
	public static function material():Dynamic {
		var m:Mesh = new Mesh(new Cube(1, 1, 1, true));
		m.material.color.setColor(0x804020);

		return Math.round(m.material.color.r * 255) + ' ' + Math.round(m.material.color.g * 255);
	}

	/** Objects inside objects, since a transform is inherited down the graph. */
	public static function nested():Dynamic {
		var root:Object = new Object();
		var pivot:Object = new Object(root);
		var leaf:Object = new Object(pivot);

		pivot.x = 3;
		leaf.x = 4;

		var at:Vector = leaf.getAbsPos().getPosition();
		return at.x;
	}

	/** A host property with a setter, in three dimensions rather than two. */
	public static function moved():Dynamic {
		var o:Object = new Object();
		o.x = 5;
		o.y = 6;
		o.z = 7;

		var at:Vector = o.getAbsPos().getPosition();
		return at.x + ',' + at.y + ',' + at.z;
	}

	/**
	 * The project's own frame loop, driven without a window.
	 *
	 * `start` is not called, because it builds into the 3D scene and a conformance pass has no
	 * window to have one. What this drives is the part that would run every frame regardless.
	 */
	public static function stepped():Dynamic {
		var w:World = new World();

		for (i in 0...30) {
			w.step(1 / 60);
		}

		return 'pieces ' + w.pieces();
	}

	/** A scripted class that really is an `h3d.scene.Object`, which needs a bridge for the base. */
	public static function extended():Dynamic {
		var m:Marker = new Marker();
		return 'made ' + (m != null) + ' visible ' + m.visible;
	}

	/** A field of the base, written and read back through the subclass. */
	public static function extendedMoved():Dynamic {
		var root:Object = new Object();
		var m:Marker = new Marker(root);
		m.x = 5;
		m.y = 6;

		var at:Vector = m.getAbsPos().getPosition();
		return at.x + ',' + at.y + ' in ' + root.numChildren;
	}

	/** A subclass of `h3d.scene.Mesh`, which is two levels down the scene graph. */
	public static function extendedMesh():Dynamic {
		var root:Object = new Object();
		var b:Blob = new Blob(new Cube(1, 1, 1, true), root);
		b.z = 3;

		return 'material ' + (b.material != null) + ' in ' + root.numChildren + ' at ' + b.getAbsPos().getPosition().z;
	}

	/** A subclass of a light, which is a different branch of the same graph. */
	public static function extendedLight():Dynamic {
		var root:Object = new Object();
		var l:Lamp = new Lamp(root);

		return 'lit ' + l.tally() + ' in ' + root.numChildren;
	}

	/** Its own field and method, beside the ones it inherited. */
	public static function extendedOwn():Dynamic {
		var m:Marker = new Marker();
		m.bump();
		m.bump();
		return m.tag + ' ' + m.count();
	}
}

/**
 * A scripted class extending the 3D scene object.
 *
 * The base's constructor cannot be rebuilt from the compiler's own output, so Haxe constructs it
 * instead: the bridge carries a real `super` call and the instance is made rather than allocated
 * empty. What that buys is this: a script can be part of the scene graph rather than only building
 * into it.
 */
class Marker extends Object {
	public var tag:String = 'marker';

	var bumps:Int = 0;

	public function new(?parent:Object) {
		super(parent);
	}

	public function bump():Void {
		bumps++;
	}

	public function count():Int {
		return bumps;
	}
}

/** A scripted `h3d.scene.Mesh`, two levels below the scene object. */
class Blob extends Mesh {
	public function new(prim:h3d.prim.Primitive, ?parent:Object) {
		super(prim, null, parent);
	}
}

/** A scripted light, on another branch of the same graph. */
class Lamp extends h3d.scene.fwd.PointLight {
	var seen:Int = 0;

	public function new(?parent:Object) {
		super(parent);
		seen = 1;
	}

	public function tally():Int {
		return seen;
	}
}
