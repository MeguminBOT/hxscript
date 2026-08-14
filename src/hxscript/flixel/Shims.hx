package hxscript.flixel;

#if flixel
import flixel.FlxG;
import flixel.FlxSprite;
import flixel.math.FlxRect;
import flixel.sound.FlxSound;
import flixel.sound.FlxSoundGroup;

/**
 * flixel members that have no runtime form, re-registered as real closures (flixel 6.2.0).
 *
 * `FlxCamera`, `FlxFrame` and `AtlasBase` declare more of these. Only the ones a script is likely to
 * reach are shimmed: each is a closure somebody has to keep correct across upgrades, and an unused
 * shim keeps compiling long after the signature it emulates has moved.
 */
class Shims {
	/**
	 * Registers one shim through the setup registrar.
	 *
	 * @param key `<fully.qualified.Owner>.<method>`.
	 * @param shim Receives the receiver and the call arguments.
	 */
	static function set(key:String, shim:(o:Dynamic, args:Array<Dynamic>) -> Dynamic):Void {
		hxscript.setup.Shims.set(key, shim);
	}

	/** Registers every flixel member whose runtime form the library does not carry. */
	public static function register():Void {
		#if (flixel >= "6.0.0")
		set('flixel.FlxG.switchState', function(o:Dynamic, args:Array<Dynamic>):Dynamic {
			var next:Dynamic = args[0];
			var current:Dynamic = FlxG.state;

			FlxG.state.startOutro(function():Void {
				if (FlxG.state == current)
					@:privateAccess FlxG.game._nextState = next;
				else
					FlxG.log.warn('`onOutroComplete` was called after the state was switched. This will be ignored');
			});

			return null;
		});

		set('flixel.system.frontEnds.SoundFrontEnd.playMusic', function(o:Dynamic, args:Array<Dynamic>):Dynamic {
			var asset:Dynamic = args[0];
			var rest:Array<Dynamic> = args.slice(1);
			var group:Dynamic = null;

			if (rest.length > 0 && (rest[0] == null || Std.isOfType(rest[0], FlxSoundGroup)))
				group = rest.shift();

			var volume:Float = (rest.length > 0 && rest[0] != null) ? rest[0] : 1.0;
			var loop:Bool = (rest.length > 1 && rest[1] != null) ? rest[1] : true;

			var sound:FlxSound = FlxG.sound.create(asset, group);
			sound.volume = volume;
			sound.looped = loop;

			if (rest.length > 2 && rest[2] != null)
				sound.onComplete = rest[2];

			FlxG.sound.music = sound;
			return sound.play();
		});

		set('flixel.FlxSprite.clipToWorldRect', function(o:Dynamic, args:Array<Dynamic>):Dynamic {
			var sprite:FlxSprite = cast o;

			if (args.length == 1) {
				var rect:FlxRect = cast args[0];
				sprite.clipToWorldBounds(rect.x, rect.y, rect.x + rect.width, rect.y + rect.height);
			} else {
				var x:Float = args[0];
				var y:Float = args[1];
				sprite.clipToWorldBounds(x, y, x + args[2], y + args[3]);
			}

			return null;
		});
		#end
	}
}
#end
