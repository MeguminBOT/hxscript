import game.Battle;
import game.Entity;
import game.Mods;
import game.Output;
#if openfl
import openfl.display.Sprite;
import openfl.text.TextField;
import openfl.text.TextFormat;
#end

/**
 * The app the library is embedded into: a tiny turn-based battle.
 *
 * The host owns the rules, meaning health, damage, turn order and who wins, and knows nothing about what
 * fights in them. It never names a script: it asks the loaded world which classes are entities and which
 * side each one put itself on. Dropping a new file into `scripts/` puts a new creature in the fight.
 *
 * Runs either way. As a console program, with nothing but the compiler:
 *
 *     haxe -cp src -cp examples/battle -main Main --macro include('bridges') --macro macros.BridgeMacro.generate() --interp
 *
 * or as a Lime/OpenFL application, which is the shape a game actually builds in, and where the same
 * log is drawn into a window:
 *
 *     cd examples/battle && lime test windows
 *
 * Adding `-D scriptable -D hxscript_cppia -dce no` to a native build compiles the scripts to
 * bytecode at runtime instead of interpreting them. The fight comes out the same; the first line of
 * the log says which way it ran. See `Mods.compile`.
 */
class Main #if openfl extends Sprite #end {
	static function main():Void {
		#if openfl
		openfl.Lib.current.addChild(new Main());
		#else
		play();
		#end
	}

	#if openfl
	/** Builds the window's log view, then fights the battle into it. */
	public function new() {
		super();

		var view:TextField = new TextField();
		view.width = 900;
		view.height = 700;
		view.multiline = true;
		view.wordWrap = true;
		view.selectable = false;
		view.defaultTextFormat = new TextFormat('_typewriter', 12, 0xE6E6E6);
		addChild(view);

		Output.onLine = function(line:String):Void {
			view.appendText(line + '\n');
			view.scrollV = view.maxScrollV;
		};

		play();
	}
	#end

	/** Loads the scripts, builds the encounter out of what they declared, and runs it. */
	static function play():Void {
		Mods.setup(scriptFolder());

		// What the scripts are running as. Interpreted unless the build asked for the compiler; the
		// fight is identical either way, which is the point.
		Output.write('scripts: ${Mods.compileReport}');

		var battle:Battle = new Battle(20260726);

		// The one fighter the host itself provides, so the mix is visible in the log.
		battle.add(new Entity('knight', 96, 15, true));

		for (e in Mods.roster('party'))
			battle.add(e);
		for (e in Mods.roster('enemy'))
			battle.add(e);

		Output.write('a fight breaks out');
		for (e in battle.entities)
			Output.write('  ${e.friendly ? "party" : "enemy"}  ${e.name} (${e.health} hp)');

		battle.run(20);
	}

	/**
	 * Finds the scripts. A Lime build copies them next to the executable, while running straight from
	 * the compiler leaves them where they are in the repository.
	 *
	 * @return The folder to load scripts from.
	 */
	static function scriptFolder():String {
		for (dir in ['scripts', 'examples/battle/scripts'])
			if (sys.FileSystem.exists(dir))
				return dir;

		return 'scripts';
	}
}
