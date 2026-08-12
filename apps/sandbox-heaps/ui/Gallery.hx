package ui;

import h2d.Object;

/**
 * Every widget on one screen, for comparing this against the sandbox built on SmiðrUI.
 *
 * Not part of the app. It exists because "the design matches" is a claim that has to be looked at,
 * and looking at it inside the shell means the shell has to work first. Reached with `--gallery`.
 */
class Gallery {
	var host:Object;
	var root:Root;

	var panel:Panel;
	var heading:Label;
	var secondary:Label;
	var muted:Label;
	var good:Label;
	var bad:Label;
	var warn:Label;

	var strong:Button;
	var normal:Button;
	var quiet:Button;
	var destructive:Button;
	var off:Button;

	var check:Checkbox;
	var checked:Checkbox;
	var segments:SegmentedControl;
	var field:TextInput;
	var bind:Keybind;
	var list:List;
	var log:TextArea;
	var bar:Toolbar;
	var status:StatusBar;
	var floater:Window;
	var sheet:Null<Modal>;

	/**
	 * @param root Where it draws.
	 */
	public function new(root:Root) {
		this.root = root;
		host = new Object(root.content);

		bar = new Toolbar(host);
		bar.addButton('Stop', 60, null);
		bar.addSpacer();
		bar.addButton('Scripts', 92, null);
		bar.addButton('Sandbox', 96, null);
		bar.addButton('Console', 96, null);

		panel = new Panel(Theme.panel, Theme.border, host);

		heading = new Label('Primary, what the eye should go to', 13, Primary, host);
		secondary = new Label('Secondary, worth reading second', 13, Secondary, host);
		muted = new Label('Muted, there but not offered', 13, Muted, host);
		good = new Label('Good, it worked', 13, Good, host);
		bad = new Label('Bad, it did not', 13, Bad, host);
		warn = new Label('Warn, it might not', 13, Warn, host);

		strong = new Button('Run  F5', null, Strong, host);
		normal = new Button('Reload', null, Normal, host);
		quiet = new Button('Rescan', null, Quiet, host);
		destructive = new Button('Delete', null, Destructive, host);
		off = new Button('Disabled', null, Normal, host);
		off.enabled = false;

		check = new Checkbox('Show the overlay', false, null, host);
		checked = new Checkbox("Allow flixel's debugger", true, null, host);

		segments = new SegmentedControl(['interpreted', 'bytecode', 'bytecode + jit'], 1, null, host);

		field = new TextInput('filter', 'bounc', null, host);
		field.controlWidth = 200;

		bind = new Keybind('Back to shell', hxd.Key.F1, null, host);

		list = new List(host);
		list.setItems(['flixel', 'heaps', 'lime', 'openfl', 'plain', 'my-thing']);
		list.index = 1;

		log = new TextArea(host);
		log.add('Playground.hx:12: character 9', Bad);
		log.add("  spr.loadGrafic('x');", Secondary);
		log.add('          ^', Muted);
		log.add('Cannot call FlxSprite.loadGrafic', Bad);
		log.add('  `FlxSprite` has no `loadGrafic`. Did you mean `loadGraphic`?', Secondary);
		log.add('compiled 4 classes in 31ms', Good);

		status = new StatusBar(host);
		status.text = 'idle - 6 project(s) - compiled 4 classes in 31ms';

		floater = new Window('Sandbox', root.above);
		floater.x = 640;
		floater.y = 120;
		floater.bodyHeight = 120;

		var readout:Label = new Label('fps 60\nupdate 0.8 ms\ndraw 1.4 ms\ndraw calls 12\nmemory 84 MB', 12, Secondary, floater.content);
		readout.x = Theme.px(10);
		readout.y = Theme.px(8);

		var ask:Button = new Button('Open a modal', function():Void open(), Normal, host);
		this.asker = ask;
	}

	var asker:Button;

	/** Lays everything out for the room there is. */
	public function layout():Void {
		var w:Float = root.width;
		var h:Float = root.height;
		var pad:Float = Theme.px(12);

		bar.place(0, 0, w, Theme.px(38));
		status.place(0, h - Theme.px(24), w, Theme.px(24));

		var top:Float = Theme.px(38) + pad;

		panel.place(pad, top, Theme.px(300), h - top - Theme.px(24) - pad * 2);

		list.place(pad + Theme.px(10), top + Theme.px(10), Theme.px(280), Theme.px(170));
		field.place(pad + Theme.px(10), top + Theme.px(192), Theme.px(280), Theme.px(28));
		asker.place(pad + Theme.px(10), top + Theme.px(230), Theme.px(280), Theme.px(30));

		var right:Float = pad + Theme.px(300) + pad;
		var at:Float = top;

		for (label in [heading, secondary, muted, good, bad, warn]) {
			label.rescale();
			label.x = right;
			label.y = at;
			at += Theme.px(20);
		}

		at += Theme.px(8);

		var wide:Float = Theme.px(110);
		var tall:Float = Theme.px(30);
		var gap:Float = Theme.px(8);

		strong.place(right, at, wide, tall);
		normal.place(right + (wide + gap), at, wide, tall);
		quiet.place(right + (wide + gap) * 2, at, wide, tall);
		destructive.place(right + (wide + gap) * 3, at, wide, tall);
		off.place(right + (wide + gap) * 4, at, wide, tall);

		at += tall + Theme.px(14);

		check.place(right, at, Theme.px(240), Theme.px(22));
		checked.place(right + Theme.px(250), at, Theme.px(240), Theme.px(22));

		at += Theme.px(32);

		segments.place(right, at, Theme.px(360), Theme.px(30));

		at += Theme.px(42);

		bind.place(right, at, Theme.px(320), Theme.px(28));

		at += Theme.px(40);

		log.place(right, at, w - right - pad, h - at - Theme.px(24) - pad);

		floater.resize(Theme.px(220), Theme.px(140));
		floater.keepInside(w, h);

		if (sheet != null)
			sheet.resize(w, h);
	}

	/** Opens the modal, to show what one looks like over the rest. */
	function open():Void {
		if (sheet != null)
			return;

		sheet = new Modal('New project', root.above);

		var name:TextInput = new TextInput('name', 'my-thing', null, sheet.content);
		name.controlWidth = Theme.px(220);
		name.place(0, 0, sheet.inner().width, Theme.px(28));

		var kind:SegmentedControl = new SegmentedControl(['heaps', 'plain'], 0, null, sheet.content);
		kind.place(0, Theme.px(40), sheet.inner().width, Theme.px(30));

		sheet.addButton('Create', function():Void close(), Strong);
		sheet.addButton('Cancel', function():Void close(), Quiet);
		sheet.resize(root.width, root.height);
	}

	function close():Void {
		if (sheet == null)
			return;
		sheet.remove();
		sheet = null;
	}
}
