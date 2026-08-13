package studio;

import h2d.Object;
import host.Api;
import host.Sandbox;
import hxscript.error.Diagnostic;
import hxscript.error.Sink;
import hxscript.types.ScriptedClass;
import sys.FileSystem;
import sys.io.File;
import ui.Button;
import ui.Label;
import ui.List;
import ui.Modal;
import ui.Panel;
import ui.Root;
import ui.SegmentedControl;
import ui.StatusBar;
import ui.TextArea;
import ui.TextInput;
import ui.Theme;
import ui.Toolbar;
import ui.Emphasis;

/**
 * The window: what is on screen when nothing is running.
 *
 * A list of what is on disk, a pane describing the selection, the log, and the bar along the bottom.
 * The top bar stays up while a project runs, because the three panels it toggles are the point of
 * running inside a band rather than over the whole window.
 *
 * Everything is laid out by hand in `layout`, from constants, rather than by a solver. The sandbox
 * for lime does the same, and the two have to agree.
 */
class Shell {
	static inline var SIDEBAR:Float = 250;
	static inline var LOG:Float = 200;
	static inline var PAD:Float = 8;
	static inline var FILTER_LABEL:Float = 44;
	static inline var LOG_LINES:Int = 400;
	static inline var DECLARED_SHOWN:Int = 8;

	/** How often the projects folder is looked at again, in seconds. */
	static inline var WATCH:Float = 0.5;

	static var root:Root;

	/** Everything the shell shows, which is hidden while a project runs. */
	static var panes:Object;

	/** Where a project draws, owned by the app and handed to the launcher. */
	static var surface:Object;

	static var bar:Toolbar;
	static var scriptsButton:Button;
	static var sandboxButton:Button;
	static var consoleButton:Button;

	static var sidebar:Panel;
	static var listTitle:Label;
	static var filter:TextInput;
	static var list:List;
	static var newButton:Button;

	static var detail:Panel;
	static var heading:Label;
	static var summary:Label;
	static var runButton:Button;
	static var reloadButton:Button;
	static var rescanButton:Button;
	static var folderButton:Button;
	static var errorButton:Button;
	static var settingsButton:Button;

	static var log:TextArea;
	static var status:StatusBar;

	static var sheet:Null<Modal>;

	/**
	 * A project to select and run as soon as one is found, or null.
	 *
	 * What `--run <name>` sets. Its reason for existing is that everything else here needs somebody
	 * to click something, so without it neither shipping mode can be checked without a person.
	 */
	public static var autoRun:Null<String> = null;

	static var projects:Array<ProjectInfo> = [];
	static var found:Array<ProjectInfo> = [];
	static var selected:Int = -1;
	static var resolved:{cls:ScriptedClass, kind:EntryKind} = null;

	static var lastError:Null<Diagnostic> = null;
	static var watched:Float = 0;
	static var logFile:Null<sys.io.FileOutput> = null;

	/**
	 * Builds the window.
	 *
	 * @param into Where the interface lives.
	 * @param drawInto Where a project draws, which is on the other scene entirely.
	 */
	public static function mount(into:Root, drawInto:Object):Void {
		root = into;
		surface = drawInto;

		Settings.load();
		Settings.apply();

		Sink.onDiagnostic.push(onDiagnostic);
		Api.onLog = function(text:String):Void note(text);

		Launcher.onStopped = show;

		panes = new Object(into.content);
		build();

		Overlay.mount(into);
		Panels.mount(into);

		rescan();
		refreshStatus();
	}

	/** Makes every widget, once. */
	static function build():Void {
		bar = new Toolbar(root.content);
		bar.addButton('Stop', 60, Launcher.stop);
		bar.addSpacer();
		scriptsButton = bar.addButton('Scripts', 92, function():Void {
			Panels.toggleScript();
			refreshStatus();
		});
		sandboxButton = bar.addButton('Sandbox', 96, function():Void {
			Panels.toggleSandbox();
			refreshStatus();
		});
		consoleButton = bar.addButton('Console', 96, function():Void {
			Panels.toggleConsole();
			refreshStatus();
		});

		sidebar = new Panel(Theme.panel, Theme.border, panes);
		listTitle = new Label('projects', 12, Secondary, panes);

		filter = new TextInput('filter', '', function(_:String):Void applyFilter(), panes);

		list = new List(panes);
		list.onSelect = pick;
		list.onActivate = function(_:Int):Void run();

		newButton = new Button('New project', createOne, Normal, panes);

		detail = new Panel(Theme.panel, Theme.border, panes);
		heading = new Label('', 15, Primary, panes);
		summary = new Label('', 12, Secondary, panes);

		runButton = new Button('Run  ${Settings.name(Settings.run)}', run, Strong, panes);
		reloadButton = new Button('Reload', reload, Normal, panes);
		rescanButton = new Button('Rescan', rescan, Quiet, panes);
		folderButton = new Button('Folder', reveal, Quiet, panes);
		errorButton = new Button('Open error', openError, Quiet, panes);
		settingsButton = new Button('Settings', openSettings, Quiet, panes);

		log = new TextArea(panes);
		status = new StatusBar(root.content);
	}

	/** Places everything for the room there is. */
	public static function layout():Void {
		if (bar == null)
			return;

		var w:Float = root.width;
		var h:Float = root.height;

		bar.place(0, 0, w, Viewport.TOP);
		status.place(0, h - Viewport.BOTTOM, w, Viewport.BOTTOM);

		panes.y = Viewport.TOP;

		var body:Float = h - Viewport.TOP - Viewport.BOTTOM;
		var pad:Float = Theme.px(PAD);
		var side:Float = Theme.px(SIDEBAR);
		var logHeight:Float = Theme.px(LOG);
		var top:Float = body - logHeight - pad;

		sidebar.place(pad, pad, side, top - pad);

		listTitle.rescale();
		listTitle.x = pad + Theme.px(10);
		listTitle.y = pad + Theme.px(8);

		filter.controlWidth = side - Theme.px(20) - Theme.px(FILTER_LABEL);
		filter.place(pad + Theme.px(10), pad + Theme.px(28), side - Theme.px(20), Theme.px(26));

		list.place(pad + Theme.px(10), pad + Theme.px(62), side - Theme.px(20), top - pad - Theme.px(112));
		newButton.place(pad + Theme.px(10), top - pad - Theme.px(38), side - Theme.px(20), Theme.px(28));

		var right:Float = pad + side + pad;
		var wide:Float = w - right - pad;

		detail.place(right, pad, wide, top - pad);

		heading.rescale();
		heading.x = right + Theme.px(14);
		heading.y = pad + Theme.px(10);

		summary.rescale();
		summary.wrapAt = wide - Theme.px(28);
		summary.x = right + Theme.px(14);
		summary.y = pad + Theme.px(38);

		var buttonTop:Float = top - pad - Theme.px(38);
		var each:Float = Theme.px(104);
		var gap:Float = Theme.px(8);
		var at:Float = right + Theme.px(14);

		for (button in [runButton, reloadButton, rescanButton, folderButton, errorButton, settingsButton]) {
			button.place(at, buttonTop, each, Theme.px(28));
			at += each + gap;
		}

		log.place(pad, top + pad, w - pad * 2, logHeight - pad);

		Overlay.layout();
		Panels.layout();

		if (sheet != null)
			sheet.resize(w, h);
	}

	/** Looks at the projects folder again. */
	static function rescan():Void {
		projects = Projects.all();
		applyFilter();

		if (projects.length == 0)
			note('no projects found in ${Projects.root}');

		refreshStatus();
		takeAutoRun();
	}

	/**
	 * Runs whatever `--run` named, once, as soon as there is a list to find it in.
	 *
	 * Here rather than at startup because the name has to be matched against projects read from disk,
	 * and here rather than in `mount` because a rescan is what produces that list. Cleared before it
	 * acts, so a later rescan does not run the project a second time.
	 */
	static function takeAutoRun():Void {
		if (autoRun == null)
			return;

		var wanted:String = autoRun;
		autoRun = null;

		var at:Int = -1;
		for (i in 0...found.length)
			if (found[i].name == wanted)
				at = i;

		if (at < 0) {
			note('--run $wanted: no project of that name');
			return;
		}

		note('--run $wanted');
		list.index = at;
		pick(at);
		run();
	}

	/** Narrows the list to what the filter matches. */
	static function applyFilter():Void {
		var needle:String = filter == null ? '' : filter.value.toLowerCase();

		found = needle.length == 0 ? projects.copy() : [
			for (project in projects)
				if (project.name.toLowerCase().indexOf(needle) >= 0 || project.title.toLowerCase().indexOf(needle) >= 0) project
		];

		list.setItems([for (project in found) project.title]);

		if (found.length == 0) {
			selected = -1;
			describe();
			return;
		}

		list.index = 0;
		pick(0);
	}

	/**
	 * Takes a row as the selection.
	 *
	 * @param row Which one.
	 */
	static function pick(row:Int):Void {
		if (row < 0 || row >= found.length) {
			selected = -1;
			describe();
			return;
		}

		selected = indexOf(found[row]);
		describe();
		refreshStatus();
	}

	/** @return Where a project sits in the unfiltered list. */
	static function indexOf(project:ProjectInfo):Int {
		for (i in 0...projects.length)
			if (projects[i] == project)
				return i;
		return -1;
	}

	/** Rewrites the detail pane for the selection. */
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
			facts.push(resolved == null ? 'entry     nothing runnable found' : 'entry     ${resolved.cls.name}  (${EntryKindTools.describe(resolved.kind)})');
			facts.push('declares  ' + declared());
		}

		if (project.description.length > 0) {
			facts.push('');
			facts.push(project.description);
		}

		summary.text = facts.join('\n');
	}

	/**
	 * What the loaded project's scripts came out as.
	 *
	 * The question a scripting sandbox exists to answer: the file count says what went in, and this
	 * says what came out of it, which is the difference between a project that loaded and a project
	 * that loaded and produced nothing.
	 *
	 * @return The class names, or a count when there are more than fit on a line.
	 */
	static function declared():String {
		var classes:Array<ScriptedClass> = Sandbox.classes();

		if (classes.length == 0)
			return 'no classes';

		var names:Array<String> = [for (cls in classes) cls.name];

		if (names.length > DECLARED_SHOWN)
			return '${names.length} classes: ' + names.slice(0, DECLARED_SHOWN).join(', ') + ', ...';

		return names.join(', ');
	}

	/** Runs the selection. */
	static function run():Void {
		if (selected < 0 || selected >= projects.length)
			return;

		var project:ProjectInfo = projects[selected];

		if (project.problem != null) {
			note('${project.name} cannot run: ${project.problem}');
			return;
		}

		if (Sandbox.current != project) {
			Sandbox.load(project);
			resolved = Launcher.resolve(project);
		}

		Sandbox.compile();
		note(Sandbox.compiled);
		note('running ${project.name} ...');

		if (Launcher.start(project, surface)) {
			panes.visible = false;
			Overlay.begin(project.name);
			Settings.apply();
			refreshStatus();
		} else {
			note('${project.name} did not start');
		}
	}

	/** Reloads the selection from disk, and restarts it when it was running. */
	static function reload():Void {
		if (selected < 0 || selected >= projects.length)
			return;

		var wasRunning:Bool = Launcher.running;
		var name:String = projects[selected].name;
		var path:String = projects[selected].path;

		Launcher.stop();

		var fresh:ProjectInfo = Projects.read(name, path);
		projects[selected] = fresh;
		resolved = null;

		for (i in 0...found.length)
			if (found[i].name == name)
				found[i] = fresh;

		if (fresh.problem == null) {
			Sandbox.load(fresh, wasRunning);
			resolved = Launcher.resolve(fresh);
		}

		note('reloaded $name');
		describe();
		refreshStatus();

		if (wasRunning)
			run();
	}

	/** Brings the shell back, called by the launcher when a project ends. */
	public static function show():Void {
		Overlay.end();

		if (panes != null)
			panes.visible = true;

		refreshStatus();
	}

	/** Empties both places output goes. */
	static function clearLog():Void {
		if (log != null)
			log.clear();
		Panels.clear();
	}

	/** Opens the settings sheet. */
	static function openSettings():Void {
		if (sheet != null)
			return;

		var made:Modal = new Modal('Settings', root.above);
		made.panelWidth = 396;
		made.panelHeight = 300;
		sheet = made;

		var room = made.inner();
		var at:Float = 0;

		if (Settings.selectable()) {
			var modes:SegmentedControl = new SegmentedControl([Settings.INTERPRETED, Settings.BYTECODE],
				Settings.mode == Settings.INTERPRETED ? 0 : 1, function(i:Int):Void {
					Settings.mode = i == 0 ? Settings.INTERPRETED : Settings.BYTECODE;
					Settings.save();
					Settings.apply();
				}, made.content);
			modes.place(0, at, room.width, Theme.px(30));
			at += Theme.px(42);
		} else {
			var reason:Label = new Label('Scripts are interpreted: ' + Settings.why(), 13, Secondary, made.content);
			reason.wrapAt = room.width;
			reason.place(0, at, room.width, Theme.px(44));
			at += Theme.px(52);
		}

		var overlay:ui.Checkbox = new ui.Checkbox('Show the overlay', Settings.overlay, function(on:Bool):Void {
			Overlay.show(on);
			Settings.save();
		}, made.content);
		overlay.place(0, at, room.width, Theme.px(22));
		at += Theme.px(32);

		for (entry in [
			{label: 'Back to shell', get: function():Int return Settings.back, set: function(v:Int):Void Settings.back = v},
			{label: 'Run selected', get: function():Int return Settings.run, set: function(v:Int):Void Settings.run = v},
			{label: 'Reload project', get: function():Int return Settings.reload, set: function(v:Int):Void Settings.reload = v},
			{label: 'Toggle overlay', get: function():Int return Settings.overlayKey, set: function(v:Int):Void Settings.overlayKey = v}
		]) {
			var bind:ui.Keybind = new ui.Keybind(entry.label, entry.get(), function(code:Int):Void {
				entry.set(code);
				Settings.save();
				runButton.text = 'Run  ${Settings.name(Settings.run)}';
				refreshStatus();
			}, made.content);
			bind.place(0, at, room.width, Theme.px(26));
			at += Theme.px(32);
		}

		made.addButton('Close', closeSheet, Strong);
		made.resize(root.width, root.height);
	}

	/** Opens the new-project sheet. */
	static function createOne():Void {
		if (sheet != null)
			return;

		var made:Modal = new Modal('New project', root.above);
		made.panelWidth = 360;
		made.panelHeight = 210;
		sheet = made;

		var room = made.inner();

		var name:TextInput = new TextInput('name', 'my-thing', null, made.content);
		name.controlWidth = room.width - Theme.px(60);
		name.place(0, 0, room.width, Theme.px(28));

		var templates:Array<String> = Projects.templates();
		if (templates.length == 0)
			templates = ['plain'];

		var kind:SegmentedControl = new SegmentedControl(templates, 0, null, made.content);
		kind.place(0, Theme.px(44), room.width, Theme.px(30));

		made.addButton('Create', function():Void {
			var wanted:String = name.value;
			var born:ProjectInfo = Projects.create(wanted, templates[kind.index]);
			closeSheet();

			if (born == null)
				note('could not create $wanted; a folder of that name may already be there');
			else
				note('created ${born.path}');

			rescan();
		}, Strong);

		made.addButton('Cancel', closeSheet, Quiet);
		made.resize(root.width, root.height);
	}

	static function closeSheet():Void {
		if (sheet == null)
			return;

		sheet.remove();
		sheet = null;
	}

	/** Opens the selected project where the file manager can see it. */
	static function reveal():Void {
		if (selected < 0 || selected >= projects.length)
			return;

		open(projects[selected].path);
	}

	/** Opens the file the last error came from. */
	static function openError():Void {
		if (lastError == null || lastError.origin == null) {
			note('no error to open');
			return;
		}

		open(lastError.origin);
	}

	/**
	 * Hands a path to whatever the desktop opens it with.
	 *
	 * @param path What to open.
	 */
	static function open(path:String):Void {
		if (path == null || !FileSystem.exists(path)) {
			note('nothing at $path');
			return;
		}

		try {
			switch (Sys.systemName()) {
				case 'Windows': Sys.command('cmd', ['/c', 'start', '', path]);
				case 'Mac': Sys.command('open', [path]);
				case _: Sys.command('xdg-open', [path]);
			}
		} catch (e:haxe.Exception) {
			note('could not open $path');
		}
	}

	/** Rewrites the bar labels and the status line. */
	static function refreshStatus():Void {
		var up = Panels.shown();

		if (scriptsButton != null) {
			scriptsButton.text = (up.script ? '- ' : '+ ') + 'Scripts';
			sandboxButton.text = (up.sandbox ? '- ' : '+ ') + 'Sandbox';
			consoleButton.text = (up.console ? '- ' : '+ ') + 'Console';
		}

		var parts:Array<String> = [
			Launcher.running ? 'running' : 'idle',
			'${projects.length} project(s)',
			Sandbox.current == null ? 'nothing loaded' : Sandbox.compiled,
			'${Settings.name(Settings.run)} run  -  ${Settings.name(Settings.back)} back'
		];

		status.text = parts.join('   -   ');
	}

	/**
	 * Appends to the log, on screen and on disk.
	 *
	 * The file is not a duplicate of the pane. A windowed build has no stdout on any of the three
	 * platforms, so when something goes wrong badly enough that the pane is not on screen, the pane
	 * is exactly the thing that cannot be read. `sandbox.log` beside the executable is what is left.
	 *
	 * @param text What to append; may be several lines.
	 */
	static function note(text:String, emphasis:Emphasis = Secondary):Void {
		if (log != null) {
			for (line in text.split('\n'))
				log.add(line, emphasis);

			log.keep(LOG_LINES);
		}

		Panels.print(text);
		write(text);
	}

	/**
	 * Appends to `sandbox.log`, opened on first use and truncated then.
	 *
	 * Failures are swallowed: a read-only install directory is a reason to have no log, not a reason
	 * for the application to stop.
	 */
	static function write(text:String):Void {
		try {
			if (logFile == null)
				logFile = File.write(Projects.beside('sandbox.log'), false);

			logFile.writeString(text + '\n');
			logFile.flush();
		} catch (e:haxe.Exception) {
			logFile = null;
		}
	}

	/**
	 * Everything hxScript reports, with its position, the source line, a caret and a likely cause.
	 *
	 * @param d What was reported.
	 */
	static function onDiagnostic(d:Diagnostic):Void {
		lastError = d;
		note(d.toString(), d.fatal ? Bad : Warn);
	}

	/**
	 * One frame of the shell.
	 *
	 * @param dt Seconds since the previous frame.
	 */
	public static function tick(dt:Float):Void {
		Panels.tick(dt);
		Overlay.tick(dt);

		if (Launcher.running)
			return;

		watched += dt;

		if (watched >= WATCH) {
			watched = 0;

			if (Sandbox.stale())
				note('scripts changed on disk; press Reload');
		}
	}

	/**
	 * A key went down while the shell owns the keyboard.
	 *
	 * @param code The key.
	 */
	public static function pressed(code:Int):Void {
		if (code == 0)
			return;

		if (code == Settings.back && Launcher.running) {
			Launcher.stop();
			return;
		}

		if (code == Settings.overlayKey) {
			Overlay.toggle();
			return;
		}

		if (Launcher.running)
			return;

		if (code == Settings.run)
			run();
		else if (code == Settings.reload)
			reload();
	}
}
