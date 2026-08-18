package hxscript.setup;

/**
 * One [`Library`](Library.hx) record per library hxScript knows how to wire up.
 *
 * A record says what a script may `import`: types to compile in, bases to bridge, abstracts to wrap.
 * `globals` is empty in all of them on purpose, since pre-importing a name into every script is the
 * host's call. See [`Boot.importGlobals`](Boot.hx).
 */
class Presets {
	/** Records a host added for itself, for a library not shipped here, or to override one shipped. */
	public static var custom:Array<Library> = [];

	/** The library's own additions, always on because `-lib hxscript` defines `hxscript`. */
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
		globals: []
	};

	/** The layer under openfl: windows, input codes and timing rather than anything to draw with. */
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
		globals: []
	};

	/** OpenFL, with the two constraints its display list imposes. */
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
		/**
		 * `openfl.Lib` is here rather than left to the roots, and it is the one type in this record
		 * the roots cannot reach: it sits at the `openfl` package root, and every root below names a
		 * sub-package. Without this line nothing put it in the build, so `import openfl.Lib;` in a
		 * script found no type to bind.
		 */
		types: ['hxscript.openfl.SoundTools', 'openfl.Lib'],
		bases: ['openfl.display.Sprite'],
		abstractPackages: [],
		abstracts: [
			'openfl.display.BlendMode',
			'openfl.display.CapsStyle',
			'openfl.display.JointStyle',
			'openfl.text.TextFormatAlign'
		],
		abstractExclude: [],
		globals: []
	};

	/** Flixel, which is the library this arrangement was designed against. */
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
		globals: []
	};

	/**
	 * flixel-addons, covered by flixel's recursive include, so this is the skip list and extra bases.
	 * `nape` and `editors.spine` integrate libraries a project may not ship, and fail the build rather
	 * than being quietly absent.
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
		globals: []
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
		globals: []
	};

	/**
	 * The 2D half of heaps, plus the `h3d` types the 2D half names: `h2d.Drawable` declares `colorAdd`
	 * an `h3d.Vector` and `colorMatrix` an `h3d.Matrix`, and `h2d.Tile` is a region of an
	 * `h3d.mat.Texture`. Nothing else under `h3d` is reachable from `h2d`, which is what makes the cut.
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
			/** Read per frame the way the keyboard is; `wait` hands over a pad as one arrives. */
			'hxd.Pad',
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
		 * All five are `@:forward` abstracts with no runtime class, so without a wrapper
		 * `new h2d.col.Point(3, 4)` resolves to nothing. `Point` is what `getBounds`, `globalToLocal`
		 * and every collision shape are written in; the `h3d` three are what tinting a sprite names.
		 */
		abstracts: ['h2d.BlendMode', 'h2d.col.Point', 'h3d.Vector', 'h3d.Vector4', 'h3d.Matrix'],
		abstractExclude: [],
		globals: []
	};

	/**
	 * The 3D half of heaps, on whenever heaps is and separable because a project uses one scene graph
	 * or the other. Nine of the ten heaps bridges are here, and a bridge costs one generated override
	 * per inherited method, so `-D hxscript_setup_skip=heaps3d` is what a 2D project turns off.
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
			 * With `Bounds.rayIntersection`, every hitscan shot and ground probe, and arithmetic with no
			 * device behind it. `h3d.col.Point` cannot join it: it aliases the `h3d.Vector` abstract, and
			 * the manifest holds a value reference per type, which an abstract is not.
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
		globals: []
	};

	/** SmidrUI, a UI toolkit rather than a game framework, and here for that reason. */
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
		globals: []
	};

	/**
	 * hxvlc, video playback through libVLC, so a script can run a cutscene without the host exposing a
	 * video API of its own. `hxvlc.impl` is out of the roots because it is the libVLC extern layer,
	 * written in `cpp.RawPointer` and `cpp.Callable`; the two public classes pull in what they need.
	 */
	public static final HXVLC:Library = {
		define: 'hxvlc',
		title: 'hxvlc',
		roots: ['hxvlc.openfl', 'hxvlc.util', 'hxvlc.flixel'],
		ignore: ['hxvlc.util.macros'],
		types: [],
		/**
		 * `openfl.Video` deliberately not: it inherits most of the display list, and a script holds one
		 * and adds it to the stage rather than being one. A flixel object is reached by being one.
		 */
		bases: ['hxvlc.flixel.FlxVideoSprite'],
		abstractPackages: [],
		/** `Location` is a typedef of this, and it is the argument type of every `load` call. */
		abstracts: ['hxvlc.util.typeLimit.OneOfTwo'],
		abstractExclude: [],
		globals: []
	};

	/**
	 * extension-androidtools: toasts, permissions, build info. Every module opens with
	 * `#if (!android && !native) #error`, so requiring the platform as well as the library is what
	 * keeps a desktop build that merely lists it compiling.
	 */
	public static final ANDROIDTOOLS:Library = {
		define: 'extension-androidtools',
		requires: 'extension-androidtools,android',
		title: 'extension-androidtools',
		roots: ['extension.androidtools'],
		/** JNI plumbing rather than an API, and the callback bridge is called from native code. */
		ignore: ['extension.androidtools.jni', 'extension.androidtools.callback'],
		types: [],
		bases: [],
		abstractPackages: [],
		abstracts: [],
		abstractExclude: [],
		globals: []
	};

	/**
	 * extension-haptics, vibration on Android and iOS. Ungated because `Haptic` keeps every
	 * platform-specific branch inside a conditional, so it compiles everywhere and does nothing where
	 * there is no hardware. `HapticAndroid` and `HapticIOS` compile on one platform each, so naming
	 * them would undo that.
	 */
	public static final HAPTICS:Library = {
		define: 'extension-haptics',
		title: 'extension-haptics',
		roots: [],
		ignore: [],
		types: ['extension.haptics.Haptic'],
		bases: [],
		abstractPackages: [],
		abstracts: [],
		abstractExclude: [],
		globals: []
	};

	/**
	 * haxe.ui core: the components and the layout, abstract over what draws them. `haxe.ui.backend` is
	 * left to the backend record, since core ships that package as the shape a backend must fill and
	 * the backend library shadows it on the classpath.
	 */
	public static final HAXEUI_CORE:Library = {
		define: 'haxeui-core',
		title: 'haxe.ui core',
		roots: ['haxe.ui'],
		ignore: ['haxe.ui.macros', 'haxe.ui._module', 'haxe.ui.parsers', 'haxe.ui.backend'],
		types: ['haxe.ui.Toolkit'],
		/**
		 * None, deliberately: a haxe.ui screen is composed rather than subclassed, and `Component` is
		 * the root of everything here, so bridging it would be the most expensive base shipped.
		 */
		bases: [],
		/**
		 * The whole package: every constant is an enum abstract, `Variant` is what a component's value
		 * is typed as, and `EventType` is how an event is named.
		 */
		abstractPackages: ['haxe.ui'],
		abstracts: [],
		abstractExclude: [],
		globals: []
	};

	/**
	 * The flixel backend for haxe.ui, its own haxelib and so its own record: a project picks one
	 * backend, and naming flixel's here would be wrong for the openfl and heaps ones.
	 */
	public static final HAXEUI_FLIXEL:Library = {
		define: 'haxeui-flixel',
		title: 'haxe.ui flixel',
		roots: ['haxe.ui.backend'],
		ignore: [],
		types: [],
		/** The one place such a project subclasses: a screen is a `UIState`. A fragment is composed. */
		bases: ['haxe.ui.backend.flixel.UIState', 'haxe.ui.backend.flixel.UISubState'],
		abstractPackages: [],
		abstracts: [],
		abstractExclude: [],
		globals: []
	};

	/** Every library shipped here, whether or not this build has it. */
	public static final SHIPPED:Array<Library> = [
		CORE,
		LIME,
		OPENFL,
		FLIXEL,
		FLIXEL_ADDONS,
		FLIXEL_UI,
		HXVLC,
		ANDROIDTOOLS,
		HAPTICS,
		HAXEUI_CORE,
		HAXEUI_FLIXEL,
		HEAPS,
		HEAPS_3D,
		SMIDR
	];

	/**
	 * The libraries this build actually has, with `custom` folded in.
	 *
	 * A record switches on by `requires` where it has one and by `define` otherwise, and is addressed
	 * by `define` either way, which is what lets `-D hxscript_setup_skip=heaps3d` drop half of heaps.
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
				if (enabled(lib.requires ?? lib.define)
					&& skip.indexOf(lib.define) < 0
					&& (only.length == 0 || only.indexOf(lib.define) >= 0)) lib
		];
	}

	/**
	 * Whether a record's switch is on, which is every define it names being set.
	 *
	 * @param define One define, or several separated by commas.
	 * @return Whether the build defines all of them.
	 */
	public static function enabled(define:String):Bool {
		for (one in define.split(','))
			if (!defined(StringTools.trim(one)))
				return false;

		return true;
	}

	/**
	 * Whether a define is set, asked in whichever of the two worlds this is running in.
	 *
	 * @param define The define to test.
	 * @return Whether the build defines it.
	 */
	static function defined(define:String):Bool {
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
