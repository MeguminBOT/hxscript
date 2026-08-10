import Palette;

/**
 * A flixel project, and the shape most projects will take.
 *
 * This is not a wrapper with a few methods forwarded. `Playground` **is** an `FlxState` and `Mote`
 * **is** an `FlxSprite`: `add`, `bgColor`, `update`, `super.update`, `makeGraphic`, `velocity`,
 * `FlxTween` and `FlxText` are flixel's own, reached by name, with nobody in between.
 *
 * The launcher finds this class because it extends `FlxState`. `project.json` names it explicitly as
 * well, which is what you want once a project has more than one state, since otherwise the first by name
 * wins, which is fine until it is not.
 *
 * Edit this file and save it. The sandbox notices and reloads without being asked.
 */
class Playground extends FlxState {
	static var COUNT:Int = 24;

	override public function create():Void {
		super.create();

		bgColor = Palette.of(Tone.Fade(0.09));

		var label:FlxText = new FlxText(10, 8, FlxG.width - 20, 'a scripted FlxState with $COUNT scripted FlxSprites, F1 to go back', 12);
		label.color = Palette.of(Tone.Fade(0.85));
		add(label);

		for (i in 0...COUNT)
			add(new Mote(i, COUNT));

		#if flixel_addons
		var skewed:FlxSkewedSprite = new FlxSkewedSprite(0, FlxG.height - 60);
		skewed.makeGraphic(FlxG.width, 40, Palette.of(Tone.Accent));
		skewed.alpha = 0.22;
		skewed.skew.x = 24;
		add(skewed);
		#end

		var footer:FlxText = new FlxText(10, FlxG.height - 22, FlxG.width - 20, footerText(), 10);
		footer.color = Palette.of(Tone.Fade(0.55));
		add(footer);
	}

	/**
	 * `#if` in a script reads the **host's** compiler defines, so one file covers every build.
	 *
	 * @return Which of the flixel libraries this build of the sandbox carries.
	 */
	function footerText():String {
		var libs:Array<String> = ['flixel'];

		#if flixel_addons
		libs.push('flixel-addons');
		#end
		#if flixel_ui
		libs.push('flixel-ui');
		#end

		return 'wired: ' + libs.join(', ');
	}
}

/**
 * A scripted `FlxSprite`, which is what a bridge exists to make possible.
 *
 * `update` here is a real override of `FlxSprite.update`: the generated bridge dispatches to this
 * when the script defines it and falls through to `super` when it does not, so flixel's own update
 * loop drives it without knowing anything has been replaced.
 */
class Mote extends FlxSprite {
	var index:Int;
	var count:Int;
	var phase:Float;

	public function new(index:Int, count:Int) {
		super(0, 0);

		this.index = index;
		this.count = count;
		this.phase = index * 0.26;

		var size:Int = 6 + Std.int((count - index) * 0.5);
		makeGraphic(size, size, Palette.step(index, count));

		FlxTween.tween(this, {alpha: 0.35}, 1.1 + index * 0.03, {ease: FlxEase.quadInOut});
	}

	override public function update(elapsed:Float):Void {
		super.update(elapsed);

		phase += elapsed * 0.9;

		x = FlxG.width * 0.5 + Math.cos(phase) * (34 + index * 7) - width * 0.5;
		y = FlxG.height * 0.5 + Math.sin(phase * 1.4) * (26 + index * 5) - height * 0.5;
		angle = phase * 26;
	}
}
