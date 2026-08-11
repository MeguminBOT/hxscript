# hxScript Sandbox: Lime HXCPP

A prototyping app for **lime, openfl and flixel**, where your project is a folder of `.hx` files read
at runtime rather than code that has to be compiled in.

Drop a folder into `projects/`, pick it in the list, press Run. Edit a script in whatever editor you
already use, save, and it reloads. No rebuild, no Haxe toolchain, no wiring.

**Folder** opens the selected project where your file manager can see it, and **Open error** opens the
file the last error came from, so the round trip between the log and the editor is two clicks.

```
┌─ projects ────┬─ Flixel playground ────────────────┐
│ ▸ flixel      │ kind      flixel                   │
│ ▸ lime        │ folder    .../projects/flixel      │
│ ▸ openfl      │ scripts   2 file(s)                │
│ ▸ my-thing    │ entry     Playground (a flixel     │
│               │                       state)      │
│ [ New project]│ [ Run  F5 ] [ Reload ] [ Rescan ]  │
├───────────────┴────────────────────────────────────┤
│ Playground.hx:12: character 9                      │
│   spr.loadGrafic('x');                             │
│           ^                                        │
│ Cannot call FlxSprite.loadGrafic                   │
│   `FlxSprite` has no `loadGrafic`. Did you mean    │
│   `loadGraphic`?                                   │
├────────────────────────────────────────────────────┤
│ idle · 4 project(s) · compiled 4 classes in 31ms   │
└────────────────────────────────────────────────────┘
```

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

The build scripts check the toolchain and the haxelibs first and name anything missing, rather than
failing inside lime with a stack trace about a file you have never opened.

| | |
| --- | --- |
| `./build.sh run` | build, then launch |
| `./build.sh --debug` | debug build |
| `./build.sh --clean` | wipe `export/` first |
| `./build.sh linux` | a named target: `windows`, `linux`, `mac` |

Setup installs [hxscript](https://github.com/MeguminBOT/hxscript) and
[SmiðrUI](https://github.com/MeguminBOT/SmidrUI) from git rather than from a release, because this app
is written against both as they currently are. If you have either checked out and want to build
against your edits, the build scripts find a checkout of hxscript at this repository and one of
SmiðrUI beside it, and point haxelib at what they find. Say where it is if it is somewhere else:

```
HXSCRIPT_PATH=/path/to/hxscript SMIDR_PATH=/path/to/SmidrUI ./build.sh
set SMIDR_PATH=C:\path\to\SmidrUI && build.bat
```

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
  "kind": "flixel",
  "entry": "Playground",
  "description": "one line, shown in the detail pane"
}
```

### What a project runs

**A project says what it is by what it declares.** There is no interface to implement and no base
every project must extend, because each of the three libraries already has the right base, and making
you extend something of ours instead would be wrapping a library rather than using it.

| declare this | and it runs as |
| --- | --- |
| a class extending `flixel.FlxState` | a flixel state, with the whole of flixel's lifecycle |
| a class extending `openfl.display.Sprite` | a display object, driven by the display list |
| a class extending `host.Project` | your own loop: `start`, `update(dt)`, `stop`, key and mouse callbacks |
| a class with `static function main()` | called once, and it owns whatever happens next |

Whichever it is, **it is the library's own class, not a wrapper.** A scripted `FlxState` gets `add`,
`bgColor`, `update`, `super.update`, cameras and substates; a scripted `FlxSprite` gets `makeGraphic`,
`velocity` and a real override of `update` that flixel's own loop calls.

`host.Project` is the one that needs explaining. A script **cannot** subclass `lime.app.Application`,
because that class is the process entry and anything extending it would have had to exist before the
program started. So the app owns the `Application` and hands the same lifecycle down. `lime.ui`,
`lime.system` and `lime.math` are all reachable by name from inside it.

When more than one class qualifies, the order is: `entry` in `project.json`, then a class marked
`public static var entry:Bool = true`, then flixel state, openfl sprite, `host.Project`, `main`.

### A project with no framework at all

The last row of that table is worth its own paragraph, because it is the one people do not expect to
be there. A class with a `static main()` and nothing else runs here: no window, no display object, no
loop. That suits anything computing an answer rather than drawing one, such as a parser, a solver, a
converter, or a scratch test of an idea you did not want to make a whole project for.

It gets the standard library, `sys`, and the host's own tools. `log()` and `trace` both reach the
**Console** window, which the button in the top bar opens, and `Probe.report(...)` answers whether a
type or member is really reachable from a script rather than leaving you to find out from a null field
later. When `main` returns, the shell comes back on its own unless the project left something running.

### The four that ship

`projects/` is created beside the executable on first run and seeded with these, so a fresh build has
something that runs in it before you have written anything.

| | |
| --- | --- |
| `flixel` | a scripted `FlxState` with two dozen scripted `FlxSprite`s, plus a module declaring a scripted enum, a scripted abstract with an operator, and a class |
| `openfl` | a scripted `openfl.display.Sprite` driving a few dozen more, with `Graphics`, `BlendMode` and a `TextField` |
| `lime` | a `host.Project`: no framework under it, just the frame loop and `lime.ui.KeyCode` |
| `plain` | a `static main()`: no framework at all, printing what a script can reach |

### If a project behaves differently once it is compiled

Scripts run interpreted, as bytecode, or as bytecode with the JIT, chosen in Settings. The three
should agree, and a module the compiler will not take is reported in the log and quietly interpreted,
which costs speed and nothing else. A short list of constructs answers differently instead, and those
say nothing at all: see
[Where compiled code still differs](../../docs/modes.md#where-compiled-code-still-differs) for what
they are and what to do about each.

**The check takes ten seconds**: set the run mode to interpreted. If the behaviour changes back, it is
the compiler rather than your script, and bytecode-without-the-JIT is worth trying next.

To investigate without a window, `--probe` compiles a project headlessly:

```
Sandbox.exe --probe my-thing                    compile it, report what was skipped
Sandbox.exe --probe my-thing --nojit            the same batch without the JIT
Sandbox.exe --probe my-thing --only A,B,C       narrow the batch to those modules
Sandbox.exe --probe my-thing --interp --call Main.go   run a static, interpreted
```

Running the same `--call` in each mode and diffing the output is how the differences above were
found. The line it prints after the call says how much the interpreter did: near zero means the code
really ran compiled, and a large number means a module fell back and the comparison is measuring the
interpreter against itself.

### The window

A project is given a fixed **1366x768** canvas, whatever the window is doing, so `FlxG.width` and
`FlxG.height` mean the same thing on every machine. Taking the stage size instead would hand a project
the display's physical pixels, and the same window at 150% scaling would report 2049 wide.

It runs in a **viewport** between two bars, not over the whole window. It is fitted to the band
uniformly, so nothing is stretched or cut off, and **never magnified**, because a window bigger than the
project is extra room around it, not a reason to blow it up, so the percentage in the readout is only
ever how much was given up to fit. The two bars cost 54 pixels of height, so at the default window the
canvas is drawn at 93%; from 1600x900 up it is 1:1.

The fitting is a flixel **scale mode**, not a transform applied on top of one, and that distinction is
the whole correctness argument. A scale mode owns `FlxG.game`'s position and each camera's scale and
rewrites them on every measure, so a viewport implemented as a second transform is both compounded with
flixel's and undone by it. It looked right at startup, when both agreed on 1, and went to 133% the
moment the window went fullscreen. Expressed as a scale mode, the camera scale, the game's position and
the mouse coordinates all follow from one number. The last of those is the one that would otherwise
have been quietly wrong: flixel derives the pointer from the scale mode, so a hand-rolled transform
means clicks land somewhere other than where they look.

The UI is attached to the stage rather than inside the game, which is what lets the bars keep their
size while the thing between them changes size.

The top bar toggles three windows, and they are draggable, collapsible and closable:

| | |
| --- | --- |
| **Script environment** | what was loaded, what the runtime compiler took, and what the interpreter is still doing |
| **Sandbox** | fps, update and draw milliseconds, draw calls, memory, and the viewport's own size |
| **Console** | everything printed, including `trace` and `log` from the running project |

**Every number in those two is counted, not estimated**, and the split follows from that. `update` and
`draw` are bracketed by flixel's own signals, so while a project is the state, that time is honestly
the project's. Draw calls are flixel's counter, reset per frame by flixel and read after the cameras
render. Memory is not divisible, since there is one heap, one collector and no way to ask which
allocation came from a script, so it is reported once, under **Sandbox**, as the process's. The frame rate goes there too,
for the same reason: there is one frame loop and it belongs to the application.

The interpreted-work counters under **Script environment** need their label read. They count the
interpreter, and a module the runtime compiler took runs as native bytecode and passes through none of
it, so **zero there means compiled, not idle**, which is why the compiled/interpreted split sits
directly above them.

The console is the answer to a real gap rather than a nicety. A script's `trace` went to
`haxe.Log.trace` and `log()` went to standard output, and a double-clicked application has no console
attached on any of the three platforms, so the most ordinary way to find out what your code is doing
produced nothing at all, silently, which looks exactly like the code not running. Both are routed to
the window now, `trace` keeping its file and line.

### Keys

| | | |
| --- | --- | --- |
| Back to shell | `F1` | the only one that competes with a running project |
| Run selected | `F5` | only read while nothing is running |
| Reload project | unbound | |
| Toggle overlay | unbound | |

All four are rebindable in **Settings**, and two of them start with no key at all. That is the rule
the defaults follow: **a key the shell claims is a key the project never sees**, so it claims one.
`Escape` is deliberately not it, because a menu closes on it, a prompt cancels on it, a long job offers to
skip on it, and a shell that took it would end the run instead.

### Settings

Beside the Run buttons, and written to `sandbox.json` beside the executable as you change it.

- **Show the overlay**, described below. Off.
- **Allow flixel's debugger** is off, and this is the one the rest is here for. flixel binds its
  debugger to `F2`, backtick and backslash, in release builds as well as debug ones, so a project
  that binds any of those finds the debugger opening on top of itself from a key it handled, with
  nothing in its own code to explain it.

### The overlay

A strip of UI that stays above a running project, for the things worth watching *while* it runs.
It is SmidrUI, so a project reaches it the same way the shell does:

```haxe
info('speed', player.velocity.x);        // a named line, replaced each time it is set
infoClear();                             // drop them all
overlay();                               // a container, for widgets of your own
overlayShown();                          // whether anyone is looking
```

`info` is the cheap one and is meant to be called every frame: naming a value means the label is
built once and only its text changes afterwards. `overlay()` is where a project that has outgrown a
readout puts a slider that drives a constant or a button that resets what it is testing. Both are
safe to call when the overlay is off, and everything a project adds is dropped when it stops.

## When something goes wrong

Everything hxScript reports lands in the log pane with its position, the source line, a caret and
what usually causes it. The distinctions worth knowing about:

- **`Unknown identifier: FlxG`** tells you whether the name is missing from the build or only from
  the script's scope, and prints the `import` to add if it is the second.
- **`Cannot call FlxSprite.loadGrafic`** tells you whether the member is misspelled, and suggests the
  spelling that exists, or whether it is `inline` and so has no runtime form to call.
- **A construct with no bytecode form** is reported and the module stays interpreted. Normal, not a
  failure.
- **A project that throws** is stopped and you are returned here, rather than the app going down.

## Checking a build without a window

```
haxe console.hxml
```

Seconds rather than minutes, because it is the same host with no lime, openfl, flixel or window under
it. It prints what the build wired, then loads every project and says what each would run. That
answers "is the setup right" separately from "does the app build", which are the two questions that
otherwise get debugged as one.

## What is actually here

The interesting thing about this app is how little of it there is. The four steps that put six
libraries within reach of a script, by force-compiling their packages, generating a bridge per class a
project may extend, giving their abstracts a runtime form, registering the shims for the members that
have none, are hxScript's, driven by the libraries being in the build. `Project.xml` says nothing
about any of it.

| | |
| --- | --- |
| [`studio/Launcher.hx`](studio/Launcher.hx) | works out what a project runs, runs it, and gets out of the way |
| [`studio/Projects.hx`](studio/Projects.hx) | finds projects on disk, and writes the templates out |
| [`studio/Shell.hx`](studio/Shell.hx) | the window |
| [`host/Project.hx`](host/Project.hx) | the base for a project with no framework under it |
| [`host/Sandbox.hx`](host/Sandbox.hx) | one project, one world |
| [`host/Probe.hx`](host/Probe.hx) | asks whether a type or member is really reachable from a script |
| [`Check.hx`](Check.hx) | the headless check |

Versions this was derived against: lime 8.3.2, openfl 9.5.2, flixel 6.2.0, flixel-addons 4.0.1,
flixel-ui 2.6.5, SmiðrUI 0.3.0, on Haxe 4.3.7.

## Where to go next

- [`../../docs/embedding.md`](../../docs/embedding.md) covers putting hxScript in your own application.
- [`../../docs/advanced.md`](../../docs/advanced.md) covers how the setup works, and how to add a library
  it does not already know.
- [`../../examples/battle/`](../../examples/battle) is scripts as content inside a game that exists.
- [`../../examples/workbench/`](../../examples/workbench) is scripts as the whole program.
