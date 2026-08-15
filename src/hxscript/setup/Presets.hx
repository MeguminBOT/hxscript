package hxscript.setup;

/**
 * One [`Library`](Library.hx) record per library hxScript knows how to wire up.
 */
class Presets {
	/**
	 * Records a host added for itself, for a library not shipped here, or to override one that is.
	 */
	public static var custom:Array<Library> = [];

	/**
	 * The library's own additions to what a script can reach, always on because `-lib hxscript`
	 * defines `hxscript`.
	 */
	public static final CORE:Library = {
		define: 'hxscript',
		title: 'hxscript',
		roots: [],
		ignore: [],
		types: [
			'hxscript.stdlib.BytesTools',
			'haxe.io.Bytes',
			'haxe.io.BytesOutput',
			'haxe.io.BytesInput'
		],
		bases: [],
		abstractPackages: [],
		abstracts: [],
		abstractExclude: [],
		globals: ['hxscript.stdlib.BytesTools']
	};

	/**
	 * Lime is the layer under openfl, and a script reaches it for windows, input codes and timing
	 * rather than for anything to draw with.
	 */
	public static final LIME:Library = {
		define: 'lime',
		title: 'lime',
		roots: ['lime.app', 'lime.math', 'lime.system', 'lime.ui', 'lime.utils'],
		ignore: [
			'lime.tools',
			'lime._backend',
			'lime._internal',
			'lime.system.CFFI',
			'lime.system.JNI'
		],
		types: [],
		bases: [],
		abstractPackages: [],
		abstracts: ['lime.ui.KeyCode', 'lime.ui.MouseButton', 'lime.ui.GamepadButton'],
		abstractExclude: [],
		globals: ['lime.system.System', 'lime.ui.KeyCode', 'lime.ui.MouseButton']
	};

	/**
	 * OpenFL, with the two constraints its display list imposes.
	 */
	public static final OPENFL:Library = {
		define: 'openfl',
		title: 'openfl',
		roots: [
			'openfl.display',
			'openfl.events',
			'openfl.filters',
			'openfl.geom',
			'openfl.text',
			'openfl.utils'
		],
		ignore: [
			'openfl._internal',
			'openfl.utils._internal',
			'openfl.display._internal',
			'openfl.text._internal'
		],
		types: ['hxscript.openfl.SoundTools'],
		bases: ['openfl.display.Sprite'],
		abstractPackages: [],
		abstracts: [
			'openfl.display.BlendMode',
			'openfl.display.CapsStyle',
			'openfl.display.JointStyle',
			'openfl.text.TextFormatAlign'
		],
		abstractExclude: [],
		globals: [
			'hxscript.openfl.SoundTools',
			'openfl.display.Sprite',
			'openfl.display.Shape',
			'openfl.display.Bitmap',
			'openfl.display.BitmapData',
			'openfl.display.BlendMode',
			'openfl.geom.Point',
			'openfl.geom.Rectangle',
			'openfl.geom.Matrix',
			'openfl.text.TextField',
			'openfl.text.TextFormat',
			'openfl.Lib'
		]
	};

	/**
	 * Flixel, which is the library this arrangement was designed against.
	 */
	public static final FLIXEL:Library = {
		define: 'flixel',
		title: 'flixel',
		roots: ['flixel'],
		ignore: ['flixel.system.macros', 'flixel.system.debug'],
		types: ['hxscript.flixel.TriangleTools'],
		bases: [
			'flixel.FlxBasic',
			'flixel.FlxObject',
			'flixel.FlxSprite',
			'flixel.FlxState',
			'flixel.FlxSubState',
			'flixel.group.FlxSpriteGroup',
			'flixel.text.FlxText'
		],
		abstractPackages: ['flixel'],
		abstracts: [],
		abstractExclude: [],
		globals: [
			'hxscript.flixel.TriangleTools',
			'flixel.FlxG',
			'flixel.FlxBasic',
			'flixel.FlxObject',
			'flixel.FlxSprite',
			'flixel.FlxState',
			'flixel.FlxSubState',
			'flixel.FlxCamera',
			'flixel.FlxStrip',
			'flixel.group.FlxSpriteGroup',
			'flixel.text.FlxText',
			'flixel.ui.FlxButton',
			'flixel.util.FlxColor',
			'flixel.util.FlxTimer',
			'flixel.math.FlxPoint',
			'flixel.math.FlxRect',
			'flixel.math.FlxMath',
			'flixel.tweens.FlxTween',
			'flixel.tweens.FlxEase'
		]
	};

	/**
	 * flixel-addons. Covered by flixel's recursive include, so this is the skip list and the extra
	 * bases.
	 *
	 * `nape` and `editors.spine` are integrations for libraries a project may not ship, and they
	 * fail the build rather than being quietly absent.
	 */
	public static final FLIXEL_ADDONS:Library = {
		define: 'flixel-addons',
		title: 'flixel-addons',
		roots: [],
		ignore: [
			'flixel.addons.nape',
			'flixel.addons.editors.spine',
			'flixel.addons.tile.FlxRayCastTilemap'
		],
		types: [],
		bases: ['flixel.addons.display.FlxBackdrop', 'flixel.addons.effects.FlxSkewedSprite'],
		abstractPackages: [],
		abstracts: [],
		abstractExclude: [],
		globals: [
			'flixel.addons.display.FlxBackdrop',
			'flixel.addons.effects.FlxSkewedSprite',
			'flixel.addons.util.FlxFSM'
		]
	};

	/** flixel-ui. Also under the `flixel` root, so also just bases and names. */
	public static final FLIXEL_UI:Library = {
		define: 'flixel-ui',
		title: 'flixel-ui',
		roots: [],
		ignore: [],
		types: [],
		bases: [
			'flixel.addons.ui.FlxUIState',
			'flixel.addons.ui.FlxUISubState',
			'flixel.addons.ui.FlxUIGroup'
		],
		abstractPackages: [],
		abstracts: [],
		abstractExclude: [],
		globals: [
			'flixel.addons.ui.FlxUI',
			'flixel.addons.ui.FlxUIState',
			'flixel.addons.ui.FlxUIButton',
			'flixel.addons.ui.FlxUIText',
			'flixel.addons.ui.FlxUIGroup'
		]
	};

	/**
	 * Heaps, which shares no ancestry with the others and so is the honest test of whether the
	 * arrangement generalises.
	 *
	 * **This is the 2D half and whatever 3D types the 2D half names**, with `HEAPS_3D` holding the
	 * rest. The three that live here rather than there are not a judgement call: `h2d.Drawable`
	 * declares `colorAdd` an `h3d.Vector` and `colorMatrix` an `h3d.Matrix`, and `h2d.Tile` is a
	 * region of an `h3d.mat.Texture`, so a project that never draws a triangle in space still names
	 * all three. Nothing else under `h3d` is reachable from `h2d`, which is what makes the cut a cut.
	 */
	public static final HEAPS:Library = {
		define: 'heaps',
		title: 'heaps 2D',
		roots: [],
		ignore: [],
		types: [
			'h2d.Object',
			'h2d.Drawable',
			'h2d.Bitmap',
			'h2d.Graphics',
			'h2d.Text',
			'h2d.Tile',
			'h2d.Anim',
			'h2d.Layers',
			'h2d.Mask',
			'h2d.ScaleGrid',
			'h2d.TileGroup',
			'h2d.Font',
			'h2d.Interactive',
			'h2d.filter.Blur',
			'h2d.filter.Glow',
			'h2d.col.Point',
			'hxd.Key',
			'hxd.Timer',
			'hxd.Math',
			'hxd.Event',
			'hxd.res.Any',
			'hxd.res.Sound',
			'hxd.res.DefaultFont',
			'hxd.snd.Channel',
			'hxd.snd.effect.Pitch',
			'hxscript.heaps.SoundTools',

			/** Named by `h2d.Tile`, and by `h2d.Object.drawTo`. */
			'h3d.mat.Texture'
		],
		bases: ['h2d.Object'],
		abstractPackages: [],
		/**
		 * `h2d.col.Point` is here because it is an `@:forward abstract` over `PointImpl`, so it has no
		 * runtime class and `new h2d.col.Point(3, 4)` in a script resolved to nothing. A wrapper is
		 * what gives an abstract something to resolve to, and this is the one a project reaches for
		 * most: it is what `getBounds`, `globalToLocal` and every collision shape are written in.
		 *
		 * The three `h3d` ones are the same story for the 2D half. `colorAdd` and `colorMatrix` are
		 * declared on `h2d.Drawable` as an `h3d.Vector` and an `h3d.Matrix`, and `color` on the same
		 * class is an `h3d.Vector4`, so tinting a sprite names all three and nothing about it is 3D.
		 */
		abstracts: ['h2d.BlendMode', 'h2d.col.Point', 'h3d.Vector', 'h3d.Vector4', 'h3d.Matrix'],
		abstractExclude: [],
		globals: [
			'hxscript.heaps.SoundTools',
			'h2d.Object',
			'h2d.Bitmap',
			'h2d.Graphics',
			'h2d.Text',
			'h2d.Tile',
			'hxd.Key',
			'hxd.Timer',
			'h3d.Vector'
		]
	};

	/**
	 * The 3D half of heaps, which arrives with the rest of it and can be left out.
	 *
	 * heaps is not a 2D engine with 3D bolted on: a project picks one scene graph or the other, and
	 * a preset offering only `h2d` says the library does not support half of what the framework is
	 * for. So this is on whenever heaps is, and is a record of its own for the other reason, which is
	 * that a project only ever wants one of the two graphs and this is the more expensive one. Nine
	 * of the eleven bridges a heaps build generates are here, and a bridge costs one generated
	 * override per inherited method.
	 *
	 * ```
	 * -D hxscript_setup_skip=heaps3d
	 * ```
	 *
	 * A 2D project that says that keeps every `h2d` type, `h3d.Vector`, `h3d.Matrix` and
	 * `h3d.mat.Texture`, and stops paying for a scene graph it never builds into.
	 *
	 * **The 3D scene graph is bridgeable because a base no longer has to be rebuilt to be extended.**
	 * A bridge used to copy the constructor of the class it extends, by turning the compiler's own
	 * output back into source, and this branch does not survive that: `ObjectFlags` is an abstract
	 * whose methods mutate `this`, so every flag property becomes arithmetic on the underlying `Int`
	 * against a field typed as the abstract, which no source may write.
	 *
	 * Such a base is constructed by Haxe instead. The bridge gets a real constructor calling a real
	 * `super`, and the instance is made through it, which means the base runs exactly as compiled and
	 * nothing about it has to survive a round trip. Scripts can be part of the 3D scene rather than
	 * only building into it.
	 */
	public static final HEAPS_3D:Library = {
		define: 'heaps3d',
		requires: 'heaps',
		title: 'heaps 3D',
		roots: [],
		ignore: [],
		types: [
			/**
			 * The scene itself, so a project can say what the host handed it. A 3D project is given the
			 * scene rather than being one, and every camera move, ambient change and renderer setting
			 * is reached through it, so leaving it unnameable made the one object a project always has
			 * the one it could not annotate.
			 */
			'h3d.scene.Scene',
			'h3d.scene.Object',
			'h3d.scene.Mesh',
			'h3d.scene.Graphics',
			'h3d.scene.Box',
			'h3d.scene.Sphere',
			'h3d.scene.Interactive',
			'h3d.scene.CameraController',
			'h3d.scene.fwd.DirLight',
			'h3d.scene.fwd.PointLight',

			/** Ambient light and the light budget, which is `scene.lightSystem`. */
			'h3d.scene.fwd.LightSystem',

			/** Shadows, particles, and the sphere a culling test is written in. */
			'h3d.pass.DefaultShadowMap',
			'h3d.parts.GpuParticles',
			'h3d.col.Sphere',

			/**
			 * The shape a game asks questions of rather than draws. `Ray` with
			 * `Bounds.rayIntersection` is every hitscan shot and every ground probe, and both are
			 * arithmetic with no device behind them, so a project can run its own collision without a
			 * window and a test can drive it without one either.
			 *
			 * `h3d.col.Point` is not here beside it, and cannot be: it is a typedef to `h3d.Vector`,
			 * which is an `@:forward abstract`, and the manifest holds a reference per type so that
			 * dead code elimination keeps them. An abstract is not a value, so naming one there fails
			 * the build inside a macro rather than where it was written. Nothing is lost, since the
			 * 2D preset already wraps `h3d.Vector` and the alias resolves to that.
			 */
			'h3d.col.Ray',
			/**
			 * `Polygon` is the base the shapes share and is worth naming for itself: preparing one to
			 * be drawn is `unindex` and `addNormals`, both declared there, and a project that builds a
			 * mesh of its own builds a `Polygon`.
			 */
			'h3d.prim.Polygon',
			'h3d.prim.Cube',
			'h3d.prim.Sphere',
			'h3d.prim.Cylinder',
			'h3d.prim.Grid',

			/** A sphere built from a subdivided solid rather than from rings, so it lights evenly. */
			'h3d.prim.GeoSphere',
			'h3d.mat.Material',
			'h3d.Camera',
			'h3d.Quat',
			'h3d.col.Bounds'
		],
		bases: [
			'h3d.scene.Object',
			'h3d.scene.Mesh',
			'h3d.scene.Graphics',
			'h3d.scene.Box',
			'h3d.scene.Sphere',
			'h3d.scene.Interactive',
			'h3d.scene.CameraController',
			'h3d.scene.fwd.DirLight',
			'h3d.scene.fwd.PointLight'
		],
		abstractPackages: [],
		abstracts: [],
		abstractExclude: [],
		globals: [
			'h3d.scene.Object',
			'h3d.scene.Mesh',
			'h3d.prim.Cube',
			'h3d.mat.Material'
		]
	};

	/**
	 * SmidrUI, which is a UI toolkit rather than a game framework and is here for that reason.
	 */
	public static final SMIDR:Library = {
		define: 'smidr',
		title: 'SmidrUI',
		roots: ['smidr'],
		ignore: ['smidr.flixel'],
		types: [],
		bases: [],
		abstractPackages: ['smidr.types'],
		abstracts: [],
		abstractExclude: [],
		globals: [
			'smidr.UIComponent',
			'smidr.UIRoot',
			'smidr.UITheme',
			'smidr.UIColor',
			'smidr.UITween',
			'smidr.widgets.UILabel',
			'smidr.widgets.UIPanel',
			'smidr.widgets.UIButton',
			'smidr.widgets.UICheckbox',
			'smidr.widgets.UISlider',
			'smidr.widgets.UIList',
			'smidr.widgets.UITextInput',
			'smidr.widgets.UITextArea',
			'smidr.widgets.UIProgressBar',
			'smidr.widgets.UIToolbar',
			'smidr.widgets.UIStatusBar'
		]
	};

	/** Every library shipped here, whether or not this build has it. */
	public static final SHIPPED:Array<Library> = [CORE, LIME, OPENFL, FLIXEL, FLIXEL_ADDONS, FLIXEL_UI, HEAPS, HEAPS_3D, SMIDR];

	/**
	 * The libraries this build actually has, with `custom` folded in.
	 *
	 * A record is turned on by `requires` where it has one and by its own `define` otherwise, and is
	 * named to `hxscript_setup_skip` and `hxscript_setup_only` by its `define` either way. That is
	 * the whole of what lets `-D hxscript_setup_skip=heaps3d` drop half of heaps: nothing defines
	 * `heaps3d`, so it could not switch itself on, and it is the only name that addresses that half.
	 *
	 * @return The active records, custom ones last.
	 */
	public static function active():Array<Library> {
		var only:Array<String> = list('hxscript_setup_only');
		var skip:Array<String> = list('hxscript_setup_skip');

		var overridden:Array<String> = [for (lib in custom) lib.define];
		var out:Array<Library> = [];

		for (lib in SHIPPED) {
			if (overridden.indexOf(lib.define) < 0)
				out.push(lib);
		}

		for (lib in custom)
			out.push(lib);

		return [
			for (lib in out)
				if (enabled(lib.requires ?? lib.define) && skip.indexOf(lib.define) < 0
					&& (only.length == 0 || only.indexOf(lib.define) >= 0)) lib
		];
	}

	/**
	 * Whether a define is set, asked in whichever of the two worlds this is running in.
	 *
	 * @param define The define to test.
	 * @return Whether the build defines it.
	 */
	public static function enabled(define:String):Bool {
		#if macro
		return haxe.macro.Context.defined(define);
		#else
		return hxscript.setup.Defines.compilerDefines.exists(define);
		#end
	}

	/**
	 * A comma-separated define read as a list, in whichever world this is running in.
	 *
	 * @param define The define holding the list.
	 * @return Its entries, trimmed; empty when the define is unset.
	 */
	public static function list(define:String):Array<String> {
		#if macro
		var raw:String = haxe.macro.Context.definedValue(define);
		#else
		var raw:String = hxscript.setup.Defines.compilerDefines.get(define);
		#end

		if (raw == null || raw.length == 0 || raw == '1')
			return [];

		return [for (part in raw.split(',')) StringTools.trim(part)];
	}
}
