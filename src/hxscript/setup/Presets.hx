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
	 */
	public static final HEAPS:Library = {
		define: 'heaps',
		title: 'heaps',
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
			'hxd.res.DefaultFont'
		],
		bases: ['h2d.Object'],
		abstractPackages: [],
		abstracts: ['h2d.BlendMode'],
		abstractExclude: [],
		globals: [
			'h2d.Object',
			'h2d.Bitmap',
			'h2d.Graphics',
			'h2d.Text',
			'h2d.Tile',
			'hxd.Key',
			'hxd.Timer'
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
	public static final SHIPPED:Array<Library> = [CORE, LIME, OPENFL, FLIXEL, FLIXEL_ADDONS, FLIXEL_UI, HEAPS, SMIDR];

	/**
	 * The libraries this build actually has, with `custom` folded in.
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
				if (enabled(lib.define) && skip.indexOf(lib.define) < 0 && (only.length == 0 || only.indexOf(lib.define) >= 0)) lib
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
