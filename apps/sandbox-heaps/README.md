# hxScript Sandbox: HashLink Heaps

A prototyping app for **heaps on HashLink**, where your project is a folder of `.hx` files read at
runtime rather than code that has to be compiled in.

Drop a folder into `projects/`, pick it in the list, press Run. Edit a script in whatever editor you
already use, save, and it reloads. No rebuild, no Haxe toolchain, no wiring.

**Folder** opens the selected project where your file manager can see it, and **Open error** opens the
file the last error came from, so the round trip between the log and the editor is two clicks.

```
┌─ projects ────┬─ Heaps playground ─────────────────┐
│ ▸ heaps       │ kind      heaps                    │
│ ▸ plain       │ folder    .../projects/heaps       │
│ ▸ my-thing    │ scripts   1 file(s)                │
│               │ entry     Playground (an h2d       │
│               │                       object)     │
│ [ New project]│ [ Run  F5 ] [ Reload ] [ Rescan ]  │
├───────────────┴────────────────────────────────────┤
│ Playground.hx:12: character 9                      │
│   spr.loadGrafic('x');                             │
│           ^                                        │
│ Cannot call Bitmap.loadGrafic                      │
├────────────────────────────────────────────────────┤
│ idle · 2 project(s) · compiled 4 classes in 31ms   │
└────────────────────────────────────────────────────┘
```

This is the same app as [`../sandbox`](../sandbox), for a different target. Where the two differ, the
difference is the target's rather than a decision, and each one is called out below.

## Building it

Once, to install the haxelibs into a repository belonging to this folder, so nothing here disturbs
what the rest of your machine builds against:

```
sh setup/unix.sh    # Linux, macOS, or Git Bash on Windows
setup\windows.bat   # cmd, on Windows
```

Then, as often as you like:

```
./build.sh          # Linux, macOS, or Git Bash on Windows
build.bat           # cmd, on Windows
```

| | |
| --- | --- |
| `./build.sh run` | build, then launch |
| `./build.sh bundle` | build, then assemble a folder that runs on a machine with no HashLink |
| `./build.sh hlc` | build it as an ordinary native binary instead |
| `./build.sh hlc run` `hlc bundle` | the same two, for that binary |
| `./build.sh hlc --no-jit` | without the loader, which is the build an arm64 target gets |
| `./build.sh --debug` | debug build |
| `./build.sh --clean` | wipe the output first |

There is no lime under this one, so there is no `Project.xml` either: the build is a hxml. You need
[HashLink](https://hashlink.haxe.org) on your path, or `HLPATH` set to the directory holding it, for
both ways of building.

## The two ways to ship it

**A HashLink program can be bytecode a VM runs, or an ordinary native binary.** This app builds both,
because being able to compare them is worth more than picking one, and because the second is what a
game with mod support is most likely to be.

They are the same program. `common.hxml` is the entire build and the two target files add one line
each, which is the whole difference:

```
sandbox.hxml       common.hxml + -hl export/sandbox.hl      bytecode, run by the VM
sandbox-hlc.hxml   common.hxml + -hl export/hlc/main.c      C, compiled to a native binary
```

`./build.sh bundle` and `./build.sh hlc bundle` are where they stop looking alike:

| | bytecode | HL/C |
| --- | --- | --- |
| the executable | HashLink's `hl`, renamed | the program itself |
| the program | `hlboot.dat`, 1.9 MB beside it | inside the executable, 6.7 MB |
| the script compiler | `hxscript.hdll` beside it | linked in, nothing to ship |
| also needed | `libhl` and the `.hdll` files it binds | the same |

Nothing is compiled or linked when bundling bytecode: `hl` given no argument opens `hlboot.dat`, so a
renamed VM beside a renamed `.hl` is a double-clickable application. One caveat belongs to that mode
only, and it is worth knowing: `hlboot.dat` is opened relative to the **working** directory rather
than to the executable. Explorer sets that to the folder it launched from, so double-clicking works,
but a shortcut with a different "start in" does not. The native binary has no such file and no such
problem.

**The extension is linked rather than loaded on HL/C**, and that changes when the decision is made
rather than what it costs. A `.hdll` can be absent at startup and leave everything interpreted, so
shipping it is a choice per release; a linked symbol resolves or the link fails, so an HL/C build
decides when it is built. The app says which it is, under **Script environment**:

```
shipped   HL/C, a native binary
compiler  linked into this binary
```

`--no-jit` builds the third case, which is what an architecture HashLink cannot jit for gets:
everything links, `compiler` says why it cannot be used, and every script is interpreted. See
[`../../docs/embedding.md`](../../docs/embedding.md).

**What each bundle needs is read, not remembered.** `hlc.json` is written beside the generated C and
names every library the program binds, so the bundle copies exactly those. The hand-written list this
replaced was wrong: it carried `heaps` and `openal`, which this app does not bind, and omitted `ui`
and `uv`, which it does, so a bundle made from it was missing two libraries.

Setup installs [hxscript](https://github.com/MeguminBOT/hxscript) from git rather than from a
release, because this app is written against the library as it currently is. A checkout of it at
this repository wins over what setup installed, so edits to the library are what gets built. Say
where it is if it is somewhere else:

```
HXSCRIPT_PATH=/path/to/hxscript ./build.sh
```

### The extension

Running a script *compiled* needs `hxscript.hdll` beside the output. The build produces it by itself
and says so once:

```
hxscript: built export/hxscript.hdll
```

It needs a hashlink source tree matching your VM, which is the one thing that cannot be worked out:
the binary distributions ship `hl.h` and none of `code.c`, `module.c` or `jit.c`. If this machine
has none, the build says so and stops there rather than going and getting one. The scripts beside
`hxscript.c` will offer to fetch it, after asking:

```
sh ../../src/hxscript/hl/hdll.sh --out export
```

**Without it nothing breaks.** Every script is interpreted, which is correct and slower, and the
Settings sheet says so. `-D hxscript_no_hdll` turns the automatic step off.

## Writing a project

```
projects/
  my-thing/
    project.json     optional
    scripts/         .hx files; the path under scripts/ becomes the package
    assets/          optional, reachable by path
```

`project.json` overrides what the folder implies; a project without one still works.

```json
{
	"title": "Bouncing things",
	"kind": "heaps",
	"entry": "Playground",
	"description": "one line, shown in the detail pane"
}
```

### What a project runs

**A project says what it is by what it declares.** There is no interface to implement and no base
every project must extend, because heaps already has the right bases and making you extend something
of ours instead would be wrapping a library rather than using it.

| declare this | and it runs as |
| --- | --- |
| a class extending `h2d.Scene` | the app's 2D scene, with heaps driving it |
| a class extending `h2d.Object` | added to the project's layer, drawn by being in it |
| a class extending `host.Project` | your own loop: `start`, `update(dt)`, `stop`, key and mouse callbacks |
| a class with `static function main()` | called once, and it owns whatever happens next |

Whichever it is, **it is heaps' own class, not a wrapper.** A scripted `h2d.Object` gets `addChild`,
`x`, `alpha`, and a real override of `sync` that heaps' own traversal calls.

`host.Project` is the one that needs explaining. A script **cannot** subclass `hxd.App`, because that
class is the process entry and anything extending it would have had to exist before the program
started. So the app owns the `App` and hands the same lifecycle down. `h2d`, `h3d`, `hxd` and
`hxd.Key` are all reachable by name from inside it.

When more than one class qualifies, the order is: `entry` in `project.json`, then a class marked
`public static var entry:Bool = true`, then scene, object, `host.Project`, `main`.

### The two that ship

`projects/` is created beside the executable on first run and seeded with these, so a fresh build has
something that runs in it before you have written anything.

| | |
| --- | --- |
| `heaps` | a scripted `h2d.Object` with forty drifting squares, plus a scripted enum and a scripted abstract with an operator |
| `plain` | a `static main()`: no framework at all, printing what a script can reach |

### If a project behaves differently once it is compiled

Scripts run interpreted or as bytecode, chosen in Settings. The two should agree, and a module the
compiler will not take is reported in the log and quietly interpreted, which costs speed and nothing
else.

> **Two modes here, not the other app's three.** cppia is bytecode that hxcpp interprets unless its
> JIT is turned on, so there the two are worth separating. HashLink jits whatever it loads, so
> bytecode here is already machine code and a third setting would be a control that did nothing.

### Both templates are interpreted today, and the log says why

Worth stating rather than letting somebody discover it. The HashLink backend answers 167 of the 168
shared corpus cases, but the corpus is **self-contained scripts**, and a script in a real application
is not self-contained. Two things it reaches for are not implemented yet, and each makes its module
fall back to the interpreter:

| the log says | what is missing |
| --- | --- |
| `super, which is neither a local nor a field here` | `super.m(...)` and `super(...)`. cppia emits `CALLSUPER`; HashLink has no equivalent yet |
| `log, which is neither a local nor a field here` | bare `@:scriptStatic` names such as `log`, `info` and `overlayShown`. `hl.Backend.statics` is declared and unread |

Both are the same shape of gap: **reaching out of the compiled batch into the host**, which
`hl/Backend.hx` says outright it does not do yet. The refusal is the designed behaviour rather than a
fault, and it costs speed and nothing else, which is why the templates still run correctly on every
build here. It does mean this app currently demonstrates the *shipping* difference rather than a
speed difference, and it is the reason to fix those two before it can demonstrate both.

**The check takes ten seconds**: set the run mode to interpreted. If the behaviour changes back, it
is the compiler rather than your script.

### The window

A project is given a fixed **1366x768** canvas, whatever the window is doing, so a project means the
same thing on every machine.

It runs in a **viewport** between two bars, not over the whole window. It is fitted to the band
uniformly, so nothing is stretched or cut off, and **never magnified**, because a window bigger than
the project is extra room around it rather than a reason to blow it up.

The fitting is the scene's own `scaleMode`, not a transform laid over one, and that distinction is
the correctness argument. Heaps derives an `Interactive`'s coordinates by inverting the scene's
viewport transform, so a viewport implemented as a second transform means every click lands
somewhere other than where it looks.

> **The two bars are the same height, where the other app's are 30 and 24.** `Fixed` centres in the
> window, and the band's centre is the window's centre only when what is taken off the top equals
> what is taken off the bottom. Heaps offers no settable viewport offset, so the alternative was
> rendering the project to a texture and placing it, which takes the pointer back out of heaps'
> hands. Six pixels of status bar is the cheaper price.

The interface is a second scene, rendered over the project's and never scaled, which is what lets the
bars keep their size while the thing between them changes.

The top bar toggles three windows, and they are draggable, collapsible and closable:

| | |
| --- | --- |
| **Script environment** | what was loaded, what the runtime compiler took, and what the interpreter is still doing |
| **Sandbox** | fps, update and draw milliseconds, draw calls, triangles, memory, and the viewport's own size |
| **Console** | everything printed, including `trace` and `log` from the running project |

**Every number in those two is counted, not estimated**, and the split follows from that. The update
and draw halves are this app's own calls, so while a project is what is in them, that time is the
project's. Memory is not divisible, since there is one heap, one collector and no way to ask which
allocation came from a script, so it is reported once, under **Sandbox**, as the process's. The frame
rate goes there too, for the same reason.

The interpreted-work counters under **Script environment** need their label read. They count the
interpreter, and a module the runtime compiler took runs as bytecode and passes through none of it,
so **zero there means compiled, not idle**.

### Keys

| | | |
| --- | --- | --- |
| Back to shell | `F1` | the only one that competes with a running project |
| Run selected | `F5` | only read while nothing is running |
| Reload project | unbound | |
| Toggle overlay | unbound | |

All four are rebindable in **Settings**, and two of them start with no key at all. That is the rule
the defaults follow: **a key the shell claims is a key the project never sees**, so it claims one.
`Escape` is deliberately not it, because a menu closes on it, a prompt cancels on it, and a shell
that took it would end the run instead.

### The overlay

A strip that stays above a running project, for the things worth watching *while* it runs. A project
reaches it the same way the shell does:

```haxe
info('speed', mover.speed);       // a named line, replaced each time it is set
infoClear();                      // drop them all
overlay();                        // an h2d.Object, for controls of your own
overlayShown();                   // whether anyone is looking
```

`info` is the cheap one and is meant to be called every frame: naming a value means the label is
built once and only its text changes afterwards. Both are safe to call when the overlay is off, and
everything a project adds is dropped when it stops.

## Checking a build without a window

```
haxe check.hxml
```

Seconds rather than minutes, because it is the same host with no heaps and no window under it. It
prints what the build wired, then loads every project and says what each would run.

> **Heaps cannot be added to it**, where the other app's check can be asked `-lib flixel`. Heaps does
> not compile under eval: `hxd.fmt.hmd` fails to type, and `hlsdl` reaches the `hl` package, which
> eval refuses. So a project extending an `h2d` class is reported as extending a base this build does
> not carry, which is true and is as far as a windowless check can get. Everything else it still
> answers.

## The widgets

SmiðrUI is flixel and openfl backed and cannot run here, so the fifteen widget types this app uses
are written on `h2d` in [`ui/`](ui). They carry SmiðrUI's own palette and metrics rather than an
approximation of them, so the two apps look the same and stay looking the same.

```
hl export/sandbox.hl --gallery
```

puts every widget on one screen, for comparing the two side by side. It is not part of the app.

## What is actually here

| | |
| --- | --- |
| [`studio/Launcher.hx`](studio/Launcher.hx) | works out what a project runs, runs it, and gets out of the way |
| [`studio/Projects.hx`](studio/Projects.hx) | finds projects on disk, and writes the templates out |
| [`studio/Shell.hx`](studio/Shell.hx) | the window |
| [`studio/Viewport.hx`](studio/Viewport.hx) | the band, and why the bars are the size they are |
| [`host/Project.hx`](host/Project.hx) | the base for a project with no framework under it |
| [`host/Sandbox.hx`](host/Sandbox.hx) | one project, one world, and which way this was shipped |
| [`host/Hud.hx`](host/Hud.hx) | `info`, `overlayShown` and the rest, as bare names a script can call |
| [`ui/`](ui) | the widgets |
| [`Check.hx`](Check.hx) | the headless check |
| [`common.hxml`](common.hxml) | the whole build, minus where it comes out |
| [`sandbox.hxml`](sandbox.hxml) [`sandbox-hlc.hxml`](sandbox-hlc.hxml) | one line each: bytecode, or a native binary |

Versions this was derived against: heaps 2.1.0, format 3.8.0, hlsdl 1.15.0, hlopenal 1.5.0, on Haxe
4.3.7 and HashLink 1.16.0.

## Where to go next

- [`../sandbox/`](../sandbox) is this app for lime, openfl and flixel on hxcpp.
- [`../../docs/embedding.md`](../../docs/embedding.md) covers putting hxScript in your own application.
- [`../../docs/modes.md`](../../docs/modes.md) covers what compiling is worth and where it still differs.
