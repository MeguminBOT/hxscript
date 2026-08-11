package studio;

import flixel.FlxG;
import flixel.FlxState;
import host.Api;
import host.Sandbox;
import hxscript.error.Diagnostic;
import hxscript.error.Sink;
import openfl.display.Sprite;
import smidr.UIComponent;
import smidr.UIRoot;
import smidr.UITheme;
import smidr.flixel.FlxSmidr;
import smidr.input.UIFocus;
import smidr.widgets.UIButton;
import smidr.widgets.UICheckbox;
import smidr.widgets.UIKeybind;
import smidr.widgets.UILabel;
import smidr.widgets.UIList;
import smidr.widgets.UIModal;
import smidr.widgets.UIPanel;
import smidr.widgets.UIScrollPane;
import smidr.widgets.UISegmentedControl;
import smidr.widgets.UIStatusBar;
import smidr.widgets.UITextArea;
import smidr.widgets.UIToolbar;

/**
 * The window: pick a project on the left, read what it is on the right, watch what it says below.
 *
 * Deliberately small. The interesting parts of this application are the launcher, which accepts four
 * different shapes of project, and the log, which is where the library's diagnostics surface. A
 * larger UI would be more to look at and would not make either of those better.
 *
 * **The log is the point.** `Sink.listen` takes over hxScript's reporting, and every parse, type,
 * run, emit and load diagnostic arrives already carrying its origin, line, column, the source line
 * it happened on and what usually causes it. So a mistyped method in somebody's project shows up
 * here as the line, a caret and `did you mean`, rather than as a stack trace in a terminal nobody
 * has open.
 *
 * Static and mounted once, because the widgets belong to the application rather than to this state. SmidrUI
 * is openfl-level and `FlxSmidr.init` parents its root inside `FlxG.game`, so the same widgets survive a
 * project switching flixel to a state of its own. Which is also why the hotkeys and the file watcher hang
 * off `FlxG.signals.postUpdate` rather than off `update`: while a scripted `FlxState` is running, this state
 * is not being updated at all, and F1 still has to work.
 */
class Shell extends FlxState {
	/** Left column width. */
	static inline var SIDEBAR:Float = 250;

	/** The settings panel's width, wide enough for a 348-pixel row and the scroll bar beside it. */
	static inline var SETTINGS_WIDTH:Float = 396;

	/** How much window is left around the settings panel, so it never runs off the screen. */
	static inline var SETTINGS_MARGIN:Float = 96;

	/** Height of the log pane at the bottom. */
	static inline var LOG:Float = 200;

	/** Height of the status bar. */
	static inline var STATUS:Float = 24;

	/** Height of the toolbar above the detail pane. */
	static inline var BAR:Float = 36;

	/** Padding between panes. */
	static inline var PAD:Float = 8;

	/** How many log lines to keep. */
	static inline var LOG_LINES:Int = 400;

	/** How often to look for changed files, in seconds. */
	static inline var WATCH:Float = 0.5;

	/**
	 * Points added to every font size in the shell.
	 *
	 * SmiðrUI's design sizes suit a dense editor chrome, and this is a window somebody reads error
	 * text out of. Raising the theme's scale instead would grow every control with the text, which
	 * costs the list and the log the rows they are worth having.
	 */
	static inline var FONT_BOOST:Int = 2;

	/** The only shell, so the launcher and the hotkeys can reach it. */
	public static var instance(default, null):Shell = null;

	/** Where a `KSprite` or `KProject` draws: above the game, below the UI. */
	public static var surface(default, null):Sprite = null;

	/**
	 * A project to start straight into, from `--run <name>`.
	 *
	 * Cleared once used, so pressing F1 comes back to the list rather than relaunching for ever.
	 */
	public static var autoRun:String = null;

	/** The UI, which outlives any one state. */
	static var ui:UIRoot = null;

	/** Whether the always-on hooks have been attached. Process-wide, like the signals they use. */
	static var hooked:Bool = false;

	/**
	 * The widgets, and everything they show.
	 *
	 * Static, because the shell outlives its own `FlxState`. Running a scripted `FlxState` switches flixel
	 * away from this one, and flixel destroys a state it switches away from, so coming back means a second
	 * `Shell`. A second `Shell` with its own widgets would add a whole duplicate UI on top of the first,
	 * since the widgets live on `FlxG.game` rather than on the state.
	 *
	 * So the UI is built once and adopted by whichever `Shell` is current. Which is also what keeps
	 * the log: a project that fails, returns you here and loses everything it just told you would be
	 * the single most annoying thing this application could do.
	 */
	static var list:UIList;

	static var heading:UILabel;
	static var summary:UILabel;
	static var log:UITextArea;
	static var status:UIStatusBar;
	static var toolbar:UIToolbar;

	/** The bar across the top, which stays up while a project runs. */
	static var bar:UIToolbar;

	static var sidebar:UIPanel;
	static var listTitle:UILabel;
	static var newButton:UIButton;
	static var detail:UIPanel;
	static var logPanel:UIPanel;

	/** Everything the shell shows, hidden as one while a project runs. */
	static var panes:UIComponent;

	/** `sandbox.log`, opened on the first line written to it. */
	static var file:sys.io.FileOutput = null;

	static var projects:Array<ProjectInfo> = [];
	static var selected:Int = -1;
	static var lines:Array<String> = [];
	static var sinceCheck:Float = 0;

	override public function create():Void {
		super.create();

		instance = this;
		bgColor = 0xff16161c;

		Api.screenWidth = FlxG.width;
		Api.screenHeight = FlxG.height;
		Api.onQuit = Launcher.stop;

		FlxG.autoPause = false;

		UITheme.setFontBoost(FONT_BOOST);

		Settings.load();
		Settings.apply();

		mount();

		if (hooked) {
			panes.visible = true;
			refreshStatus();
			return;
		}

		hooked = true;

		build();

		Sink.listen(onDiagnostic);
		Launcher.onStopped = show;
		FlxG.signals.postUpdate.add(tick);
		FlxG.signals.gameResized.add(function(_, _):Void layout());

		Metrics.hook();
		hxscript.debug.Metrics.on = true;
		capture();

		note('hxScript sandbox');
		note('${Settings.name(Settings.run)} runs the selected project, ${Settings.name(Settings.back)} comes back here. Settings changes both.');
		note('projects: ' + (Projects.root == null ? '(none)' : Projects.root));

		rescan();

		if (autoRun != null) {
			var wanted:String = autoRun;
			autoRun = null;

			var at:Int = -1;
			for (i in 0...projects.length)
				if (projects[i].name == wanted)
					at = i;

			if (at < 0) {
				note('--run $wanted: no project of that name');
			} else {
				note('--run $wanted');
				list.select(at, true);
				pick(at);
				run();
			}
		}
	}

	/**
	 * Creates the surface and the UI root, once per process.
	 *
	 * Order matters and is the only reason this is its own function: the surface goes in first so the
	 * UI ends up above it, which is what lets the log stay readable over a running project.
	 */
	static function mount():Void {
		if (surface == null) {
			surface = new Sprite();
			FlxG.addChildBelowMouse(surface);
		}

		if (ui == null) {
			ui = FlxSmidr.init(false);
			FlxSmidr.autoBlockMouse = true;

			FlxSmidr.cursorMode = CURSOR_SYSTEM_OVER_UI;
		}

		pointer();

		if (panes == null) {
			panes = new UIComponent(false, false);
			ui.content.addChild(panes);
		}

		Overlay.mount(ui);
		Panels.mount(ui);
		Viewport.apply();

		ui.setViewport(0, 0, 1, 1);
		layout();

		ui.visible = true;
		panes.visible = true;
	}

	/**
	 * Creates the widgets, once, and then lays them out.
	 *
	 * Split in two because the window changes size. Everything here is made once and positioned by `layout`,
	 * which runs again on every resize. The alternative, building at one size and leaving it there, is a
	 * browser that keeps its old shape in the corner of a fullscreen window.
	 */
	static function build():Void {
		bar = new UIToolbar(Viewport.TOP);
		bar.addButton('Stop', 60, Launcher.stop);
		bar.addSpacer();
		bar.addButton('Scripts', 74, Panels.toggleScript);
		bar.addButton('Sandbox', 78, Panels.toggleSandbox);
		bar.addButton('Console', 78, Panels.toggleConsole);
		ui.content.addChild(bar);

		sidebar = new UIPanel(SIDEBAR, 10);
		panes.addChild(sidebar);

		listTitle = new UILabel('projects', 12, SECONDARY);
		panes.addChild(listTitle);

		list = new UIList(SIDEBAR - 20, 10);
		list.onSelect = pick;
		panes.addChild(list);

		newButton = new UIButton('New project', SIDEBAR - 20, 28, createOne);
		panes.addChild(newButton);

		detail = new UIPanel(10, 10);
		panes.addChild(detail);

		heading = new UILabel('no project selected', 16);
		panes.addChild(heading);

		summary = new UILabel('', 12, SECONDARY);
		panes.addChild(summary);

		toolbar = new UIToolbar(BAR);
		toolbar.addButton('Run', 92, run);
		toolbar.addButton('Reload', 80, reload);
		toolbar.addButton('Rescan', 80, rescan);
		toolbar.addSpacer();
		toolbar.addButton('Settings', 84, openSettings);
		toolbar.addButton('Clear log', 84, clearLog);
		panes.addChild(toolbar);

		logPanel = new UIPanel(10, LOG);
		panes.addChild(logPanel);

		log = new UITextArea(10, LOG - 12, '');
		log.readOnly = true;
		log.fontSize = 11;
		log.wordWrap = false;
		panes.addChild(log);

		status = new UIStatusBar(10, STATUS);
		ui.content.addChild(status);

		layout();
		refreshStatus();
	}

	/**
	 * Positions everything for the window's current size.
	 *
	 * The browser is laid out inside the viewport band rather than the window, so it occupies exactly
	 * the space a project would. Which is the point of doing it that way: the space a project gets is
	 * visible before one is running, rather than being a surprise the first time you press Run.
	 *
	 * The bar and the status bar are laid out against the window, because they are the window's: they
	 * are what the band is measured from.
	 */
	static function layout():Void {
		if (bar == null)
			return;

		ui.setViewport(0, 0, 1, 1);
		Panels.layout();

		var w:Float = FlxG.stage.stageWidth;
		var h:Float = Viewport.height;

		bar.resize(w, Viewport.TOP);
		bar.x = 0;
		bar.y = 0;

		status.resize(w, STATUS);
		status.x = 0;
		status.y = FlxG.stage.stageHeight - STATUS;

		panes.y = Viewport.TOP;

		var top:Float = h - LOG - STATUS - PAD;

		sidebar.resize(SIDEBAR, top - PAD);
		sidebar.x = PAD;
		sidebar.y = PAD;

		listTitle.x = PAD + 10;
		listTitle.y = PAD + 8;

		list.resize(SIDEBAR - 20, top - PAD - 80);
		list.x = PAD + 10;
		list.y = PAD + 30;

		newButton.x = PAD + 10;
		newButton.y = top - PAD - 38;

		var detailX:Float = PAD + SIDEBAR + PAD;
		var detailW:Float = w - detailX - PAD;

		detail.resize(detailW, top - PAD);
		detail.x = detailX;
		detail.y = PAD;

		heading.x = detailX + 12;
		heading.y = PAD + 12;

		summary.wrapWidth = detailW - 24;
		summary.x = detailX + 12;
		summary.y = PAD + 40;

		toolbar.resize(detailW - 12, BAR);
		toolbar.x = detailX + 6;
		toolbar.y = top - PAD - BAR - 6;

		logPanel.resize(w - PAD * 2, LOG);
		logPanel.x = PAD;
		logPanel.y = top;

		log.resize(w - PAD * 2 - 12, LOG - 12);
		log.x = PAD + 6;
		log.y = top + 6;

		if (surface != null) {
			surface.scaleX = Viewport.scale;
			surface.scaleY = Viewport.scale;
		}
	}

	/**
	 * Gives the shell the system pointer.
	 *
	 * Separate from the mount so it can be called again on the way back from a project. A project that
	 * loaded a cursor of its own left flixel drawing that one, which over the shell's own panels is
	 * both the wrong picture and underneath them.
	 *
	 * A running project keeps whatever it chose. `CURSOR_SYSTEM_OVER_UI` swaps to the system pointer
	 * while the pointer is over a widget and puts the project's back when it leaves, so both are right
	 * in the half of the window they belong to.
	 */
	static function pointer():Void {
		FlxG.mouse.useSystemCursor = true;
		FlxG.mouse.visible = true;
	}

	/** Reads the projects folder again and refills the list. */
	static function rescan():Void {
		projects = Projects.all();

		list.setProvider(projects.length, function(i:Int):String {
			var p:ProjectInfo = projects[i];
			return p.problem == null ? p.toString() : '! ${p.name}';
		});

		if (projects.length == 0) {
			note('no projects found in ' + Projects.root);
			selected = -1;
			describe();
			refreshStatus();
			return;
		}

		var want:Int = (selected >= 0 && selected < projects.length) ? selected : 0;

		selected = -1;
		list.select(want, true);
		pick(want);
	}

	/**
	 * Selects a project and loads it, so its errors show before anything is run.
	 *
	 * Loading on selection rather than on Run is deliberate: parse and type errors are the ones worth
	 * seeing early, and finding out that a project does not load only after pressing Run conflates
	 * "it is broken" with "it ran and did nothing".
	 *
	 * Loading, and not compiling. Reading a project is cheap and tells you something; emitting bytecode
	 * for it is the most expensive thing here and tells you nothing you did not already know. It waits
	 * for `run`.
	 *
	 * Never while something is running, whatever asked. Selecting builds a new world and drops the old one,
	 * and the old one is what the running project is made of, so this is not a selection that can be
	 * honoured and deferred. There is no selection to make until the run ends.
	 *
	 * @param index Which project.
	 */
	static function pick(index:Int):Void {
		if (Launcher.running || index < 0 || index >= projects.length || index == selected)
			return;

		selected = index;

		var project:ProjectInfo = projects[index];

		if (project.problem != null) {
			note('${project.name}: ${project.problem}');
		} else {
			note('loading ${project.name} ...');
			Sandbox.load(project);
		}

		describe();
		refreshStatus();
	}

	/** Fills the detail pane from the selected project. */
	static function describe():Void {
		if (selected < 0 || selected >= projects.length) {
			heading.text = 'no project selected';
			summary.text = 'Put a folder with a scripts/ folder in it beside this application, then Rescan.';
			return;
		}

		var project:ProjectInfo = projects[selected];
		heading.text = project.title;

		var facts:Array<String> = [
			'kind      ${project.kind}',
			'folder    ${project.path}',
			'scripts   ${project.scripts.length} file(s)'
		];

		if (project.problem != null) {
			facts.push('problem   ${project.problem}');
		} else if (Sandbox.current == project) {
			var found = Launcher.resolve(project);

			facts.push(found == null ? 'entry     nothing runnable found' : 'entry     ${found.cls.name}  (${describeKind(found.kind)})');
		}

		if (project.description.length > 0) {
			facts.push('');
			facts.push(project.description);
		}

		summary.text = facts.join('\n');
	}

	/**
	 * @param kind How the launcher would run it.
	 * @return A phrase for the detail pane.
	 */
	static function describeKind(kind:EntryKind):String {
		return switch (kind) {
			case KState: 'a flixel state';
			case KSprite: 'an openfl sprite';
			case KProject: 'a host.Project';
			case KMain: 'a static main()';
		}
	}

	/** Runs the selected project. */
	static function run():Void {
		if (selected < 0 || selected >= projects.length)
			return;

		var project:ProjectInfo = projects[selected];

		if (project.problem != null) {
			note('${project.name} cannot run: ${project.problem}');
			return;
		}

		if (Sandbox.current != project)
			Sandbox.load(project);

		Sandbox.compile();
		note(Sandbox.compiled);

		note('running ${project.name} ...');

		if (Launcher.start(project, surface)) {
			panes.visible = false;
			Overlay.begin(project.name);
			Settings.apply();

			UIFocus.clear();

			refreshStatus();
		} else {
			note('${project.name} did not start');
		}
	}

	/** Reloads the selected project from disk, and restarts it when it was running. */
	static function reload():Void {
		if (selected < 0 || selected >= projects.length)
			return;

		var wasRunning:Bool = Launcher.running;
		var name:String = projects[selected].name;
		var path:String = projects[selected].path;

		Launcher.stop();

		projects[selected] = Projects.read(name, path);

		if (projects[selected].problem == null)
			Sandbox.load(projects[selected], wasRunning);

		note('reloaded $name');
		describe();
		refreshStatus();

		if (wasRunning)
			run();
	}

	/**
	 * Brings the shell back, called by the launcher when a project ends.
	 *
	 * A new `Shell` rather than this one, because flixel destroyed this one on the way out and a
	 * destroyed state cannot be switched back to. It costs nothing: everything the shell shows is
	 * static and stays exactly as it was.
	 */
	public static function show():Void {
		Overlay.end();
		pointer();

		if (panes != null)
			panes.visible = true;

		if (!Std.isOfType(FlxG.state, Shell))
			FlxG.switchState(function():FlxState return new Shell());
		else
			refreshStatus();
	}

	/** Empties the log pane. */
	static function clearLog():Void {
		lines = [];
		log.text = '';
	}

	/**
	 * Opens the settings panel.
	 *
	 * Every row is something the shell would otherwise be doing to a running project without asking:
	 * taking a key, opening a window over it, or letting a library it did not choose do the same.
	 * Changes are written as they are made rather than on a Save button, because there is nothing here
	 * worth a confirmation step and a panel with a Save button is a panel you can lose work in.
	 */
	static function openSettings():Void {
		var rows:Array<UIComponent> = [];
		var y:Float = 16;

		var add = function(child:UIComponent, height:Float):Void {
			child.x = 16;
			child.y = y;
			rows.push(child);
			y += height;
		};

		var bind = function(label:String, code:Int, apply:Int->Void):Void {
			add(new UIKeybind(label, 348, code, function(picked:Int):Void {
				apply(picked);
				Settings.save();
				refreshStatus();
			}), 34);
		};

		add(new UILabel('Keys', 12, SECONDARY), 22);

		bind('Back to shell', Settings.back, function(c:Int):Void Settings.back = c);
		bind('Run selected', Settings.run, function(c:Int):Void Settings.run = c);
		bind('Reload project', Settings.reload, function(c:Int):Void Settings.reload = c);
		bind('Toggle overlay', Settings.overlayKey, function(c:Int):Void Settings.overlayKey = c);

		y += 10;
		add(new UILabel('How scripts run', 12, SECONDARY), 22);

		var modes:Array<String> = [Settings.INTERPRETED, Settings.CPPIA, Settings.JIT];
		var picker:UISegmentedControl = new UISegmentedControl('Run scripts', 348, ['Interpreted', 'Bytecode', 'JIT']);
		picker.select(modes.indexOf(Settings.mode));
		picker.onSelect = function(at:Int):Void {
			var was:String = Settings.mode;
			Settings.mode = modes[at];
			Settings.save();
			Settings.apply();

			var caveat:String = Settings.caveat(was);
			note('scripts will run ' + Settings.mode + (caveat == null ? ', from the next load' : '. ' + caveat));
		};
		add(picker, 34);

		var rates:Array<Int> = [0, 30, 60, 120, 240];
		var rate:UISegmentedControl = new UISegmentedControl('Frame rate', 348, ['Window', '30', '60', '120', '240']);
		rate.select(rates.indexOf(Settings.fps) < 0 ? 0 : rates.indexOf(Settings.fps));
		rate.onSelect = function(at:Int):Void {
			Settings.fps = rates[at];
			Settings.save();

			if (Settings.fps <= 0) {
				FlxG.updateFramerate = 60;
				FlxG.drawFramerate = 60;
			} else {
				Settings.apply();
			}
		};
		add(rate, 34);

		y += 10;
		add(new UILabel('While a project runs', 12, SECONDARY), 22);

		add(new UICheckbox('Show the overlay', 348, Settings.overlay, function(on:Bool):Void {
			Settings.overlay = on;
			Settings.save();

			if (Launcher.running)
				Overlay.show(on);
		}), 28);

		add(new UICheckbox("Allow flixel's debugger", 348, Settings.debugger, function(on:Bool):Void {
			Settings.debugger = on;
			Settings.save();
			Settings.apply();
		}), 28);

		var title:Float = UITheme.px(40) + 8;
		var content:Float = y + 16;
		var room:Float = FlxG.stage.stageHeight - SETTINGS_MARGIN - title;
		var visible:Float = content < room ? content : room;

		var modal:UIModal = new UIModal('Settings', SETTINGS_WIDTH, title + visible);
		var pane:UIScrollPane = new UIScrollPane(SETTINGS_WIDTH, visible);
		pane.y = 0;

		for (row in rows)
			pane.content.addChild(row);

		pane.refreshContent(content);
		modal.body.addChild(pane);
		modal.open();
	}

	/**
	 * Creates a project from the first template, under a name that is free.
	 *
	 * A dialog with a name field and a template picker is the obvious next thing here. A button that
	 * always works is the thing worth having first.
	 */
	static function createOne():Void {
		var kinds:Array<String> = Projects.templates();

		if (kinds.length == 0) {
			note('this build ships no project templates');
			return;
		}

		var kind:String = kinds[0];
		var made:ProjectInfo = null;
		var n:Int = 1;

		while (made == null && n < 100) {
			made = Projects.create(n == 1 ? 'my-$kind' : 'my-$kind-$n', kind);
			n++;
		}

		if (made == null) {
			note('could not create a project folder in ' + Projects.root);
			return;
		}

		note('created ${made.name} from the $kind template');
		rescan();
	}

	/** Refreshes the bottom bar. */
	static function refreshStatus():Void {
		status.setCells([
			{text: Launcher.running ? 'running' : 'idle'},
			{text: '${projects.length} project(s)'},
			{text: Sandbox.current == null ? 'nothing loaded' : Sandbox.compiled},
			{text: '${Settings.name(Settings.run)} run  ·  ${Settings.name(Settings.back)} back', rightAlign: true}
		]);
	}

	/**
	 * Appends to the log, on screen and on disk.
	 *
	 * The file is not a duplicate of the pane. A windowed build has no stdout on any of the three platforms,
	 * so when something goes wrong badly enough that the pane is not on screen, whether that is a project
	 * that has taken the screen, a failure during startup or a crash, the pane is exactly the thing that
	 * cannot be read. `sandbox.log` beside the executable is what is left.
	 *
	 * @param text What to append; may be several lines.
	 */
	static function note(text:String):Void {
		for (line in text.split('\n'))
			lines.push(line);

		while (lines.length > LOG_LINES)
			lines.shift();

		if (log != null)
			log.text = lines.join('\n');

		Panels.print(text);

		write(text);
	}

	/**
	 * Appends to `sandbox.log`, opened on first use and truncated then.
	 *
	 * Failures are swallowed: a read-only install directory is a reason to have no log, not a reason
	 * for the application to stop.
	 *
	 * @param text What to append.
	 */
	static function write(text:String):Void {
		try {
			if (file == null) {
				file = sys.io.File.write(Projects.beside('sandbox.log'), false);
				file.writeString('hxScript sandbox log\n');
			}

			file.writeString(text + '\n');
			file.flush();
		} catch (e:haxe.Exception) {}
	}

	/**
	 * Receives everything hxScript reports.
	 *
	 * @param d The diagnostic.
	 */
	static function onDiagnostic(d:Diagnostic):Void {
		note(d.toString());
	}

	/**
	 * Sends everything a project prints to the console window.
	 *
	 * A script's `trace` went to `haxe.Log.trace`, and `log()` went to `Sys.println`, and in a windowed
	 * build both of those go nowhere at all, because there is no console attached to a double-clicked
	 * application on any of the three platforms. So the most ordinary thing a person does to find out what
	 * their code is doing produced nothing, silently, and looked like the code not running.
	 *
	 * Both are routed here instead. `haxe.Log.trace` keeps its position information, since that is the
	 * difference between a line of output and a line of output you can find.
	 */
	static function capture():Void {
		var previous:(Dynamic, ?haxe.PosInfos) -> Void = haxe.Log.trace;

		haxe.Log.trace = function(value:Dynamic, ?where:haxe.PosInfos):Void {
			var origin:String = where == null ? '' : where.fileName + ':' + where.lineNumber + ': ';
			Panels.print(origin + Std.string(value));
			previous(value, where);
		};

		Api.onLog = Panels.print;

		flixel.FlxG.log.styles.warning.onLog.add(function(value:Dynamic, ?where:haxe.PosInfos):Void {
			Panels.print('[warning] ' + Std.string(value));
		});

		flixel.FlxG.log.styles.error.onLog.add(function(value:Dynamic, ?where:haxe.PosInfos):Void {
			Panels.print('[error] ' + Std.string(value));
		});
	}

	/**
	 * Runs every frame whatever state flixel is in.
	 *
	 * A scripted `FlxState` replaces this one while it runs, so `update` here stops being called. Anything
	 * that has to keep working, meaning the hotkey that ends the project, the loop that drives a
	 * `host.Project` and the file watcher, has to hang off a signal instead.
	 */
	static function tick():Void {
		if (!hooked)
			return;

		if (pressed(Settings.back))
			Launcher.stop();

		if (!Launcher.running && pressed(Settings.run))
			run();

		if (pressed(Settings.reload))
			reload();

		if (pressed(Settings.overlayKey))
			Overlay.toggle();

		Launcher.update(FlxG.elapsed);
		Overlay.tick(FlxG.elapsed);
		Panels.tick(FlxG.elapsed);

		watch(FlxG.elapsed);
	}

	/**
	 * Whether a bound key went down this frame.
	 *
	 * Unbound is zero and never fires, which is what lets a binding exist with no key on it. Reading it
	 * as a key code would make it `FlxKey.NONE`, and flixel answers `justPressed(NONE)` truthfully,
	 * with whether nothing was pressed.
	 *
	 * @param code The bound key code, or 0.
	 * @return Whether it was pressed.
	 */
	static function pressed(code:Int):Bool {
		return code > 0 && FlxG.keys.anyJustPressed([cast code]);
	}

	/**
	 * Reloads the loaded project when its files change on disk.
	 *
	 * Checked a few times a second rather than every frame: it is a directory walk and a stat per
	 * file, and nobody edits faster than that.
	 *
	 * @param elapsed Seconds since the previous frame.
	 */
	static function watch(elapsed:Float):Void {
		if (Sandbox.current == null)
			return;

		sinceCheck += elapsed;

		if (sinceCheck < WATCH)
			return;

		sinceCheck = 0;

		if (Sandbox.stale()) {
			note('${Sandbox.current.name} changed on disk');
			reload();
		}
	}
}
