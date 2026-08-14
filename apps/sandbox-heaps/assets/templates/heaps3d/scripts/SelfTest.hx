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
			'stepped'
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
}
