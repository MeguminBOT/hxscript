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
| `./build.sh --no-jit` | without the loader, which is the build an arm64 target gets |
| `./build.sh --debug` | debug build |
| `./build.sh --clean` | wipe the output first |

There is no lime under this one, so there is no `Project.xml` either: the build is a hxml. You need
[HashLink](https://hashlink.haxe.org) on your path, or `HLPATH` set to the directory holding it: the
binary never runs the VM, and it is compiled against that installation's `hl.h` and links against its
`libhl` and `.hdll` files.

## Why this ships as a native binary

**A HashLink program can be bytecode a VM runs, or an ordinary native binary.** This app is the
second, and only the second, which is a deliberate narrowing: on the VM, a script compiler is a
`.hdll` dropped in beside the program, and an app demonstrating that would be demonstrating something
the VM can already do. A native binary has nothing to drop anything into. The loader, the jit and
hxScript's runtime are compiled into the executable, which is the only way for them to be in the
process at all, and it is also what a game with mod support is most likely to ship as.

`sandbox.hxml` is the whole build, and the line that decides this is one of them:

```
-hl export/hlc/main.c    C, compiled to a native binary
```

`./build.sh bundle` is where the consequences are visible:

| | |
| --- | --- |
| the executable | the program itself, 6.7 MB |
| the program | inside the executable, no bytecode file at all |
| the script compiler | compiled in, nothing to ship beside it |
| also needed | `libhl` and the `.hdll` files it binds, which are dynamic libraries either way |

**The compiler is linked rather than loaded**, and that changes when the decision is made rather than
what it costs. A `.hdll` can be absent at startup and leave everything interpreted, so shipping it is
a choice per release; a linked symbol resolves or the link fails, so this build decides when it is
built. The app says which it is, under **Script environment**:

```
shipped   HL/C, a native binary
compiler  linked into this binary
```

`--no-jit` builds the other case, which is what an architecture HashLink cannot jit for gets:
everything links, `compiler` says why it cannot be used, and every script is interpreted. See
[`../../docs/embedding.md`](../../docs/embedding.md).

**What a bundle needs is read, not remembered.** `hlc.json` is written beside the generated C and
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

### The script compiler in the binary

Running a script *compiled* needs HashLink's own loader and jit, which live in `hl.exe` rather than
in `libhl`, so a program linked against `libhl` has no way to reach them. hxScript carries them and
`./build.sh` compiles them in along with everything else:

```
loader: carried hashlink 1.16
building export/hlc/Sandbox.exe
```

Nothing has to be fetched for that. The three files it needs are in the library, and `HL_SRC` points
the build at a hashlink source tree of your own if you are running a HashLink they do not match.

**Without them nothing breaks.** `--no-jit` leaves them out, every script is interpreted, which is
correct and slower, and the Settings sheet says so.

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

### The examples that ship

**Two lists, and they are kept apart.** The examples below are read where they lie, inside the
application folder, and `projects/` holds only what you put there. So `projects/` starts empty:
**Duplicate to my projects** copies an example into it, and from then on that copy is yours and a
new build cannot write over it.

| | |
| --- | --- |
| `heaps` | a scripted `h2d.Object` with forty drifting squares, plus a scripted enum and a scripted abstract with an operator |
| `base2d` | a ring of additively blended sprites turning around a centre, with text over it, and a tile loaded through `hxd.Res` |
| `base3d` | a textured cube and a plain one above it, lit and circled by the camera: `unindex`, `addNormals` and `addUVs` in one place |
| `pointlight` | white cubes lit entirely by coloured point lights moving through them |
| `helpers` | axes and a floor grid drawn with `h3d.scene.Graphics`, around a turning cube |
| `lights` | a field of cubes and orbiting spheres under a directional light and two point lights, each switchable |
| `shadows` | spheres on a floor under a light that circles, dragging the shadows with it |
| `gpuparticles` | ten thousand particles as one description rather than ten thousand objects, with their bounds drawn |
| `fps` | a first person room with targets that break and crates that take the hit, whose whole simulation is a class with no scene graph in it |

The seven from `base2d` to `gpuparticles` are after the Heaps samples of the same names, adapted to
this app's lifecycle. `heaps` and `fps` are this app's own. Heaps is MIT licensed,
© 2013 Nicolas Cannasse.

### The conformance projects, which do not ship

`conform`, `heaps3d`, `widgets` and `plain` live in `test/projects/` and are fixtures rather than
examples: `conform` has no window to draw in, `plain` prints a report, and each of the first three
declares a `SelfTest` naming cases. `Sandbox.exe --conform <name>` runs those cases interpreted and
again compiled and compares the two, which is what `sh test/all.sh` ends by doing.

An ordinary build leaves them out, so nobody opening the app finds three test harnesses in the
example list. Build with them when you mean to run the suite:

```
./build.sh --with-tests
```

Without that, the host part of `test/all.sh` reports itself skipped and says so.

### If a project behaves differently once it is compiled

Scripts run interpreted or as bytecode, chosen in Settings. The two should agree, and a module the
compiler will not take is reported in the log and quietly interpreted, which costs speed and nothing
else.

> **Two modes here, not the other app's three.** cppia is bytecode that hxcpp interprets unless its
> JIT is turned on, so there the two are worth separating. HashLink jits whatever it loads, so
> bytecode here is already machine code and a third setting would be a control that did nothing.

### Every template compiles, and the log says so

Every shipped template is taken by the compiler in full. That was not always true: HashLink used to
model no `extends` at all, so a class with a base was compiled as if it had none and `super` had
nothing to reach, and `heaps` was refused for it. A scripted class is a real type of the loaded
module now, laid out after whatever it extends, with its methods in the table a virtual call
dispatches through, so `extends`, `super` and `v is C` all mean what they mean interpreted.

If a project of your own is refused, the log names the module, the line and the construct, and the
module is quietly interpreted: it costs speed and nothing else, and every answer stays right.

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
cd export/hlc && ./Sandbox.exe --gallery
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
| [`sandbox.hxml`](sandbox.hxml) | the whole build, and the line that makes it a native binary |

Versions this was derived against: heaps 2.1.0, format 3.8.0, hlsdl 1.15.0, hlopenal 1.5.0, on Haxe
4.3.7 and HashLink 1.16.0.

## Where to go next

- [`../sandbox/`](../sandbox) is this app for lime, openfl and flixel on hxcpp.
- [`../../docs/embedding.md`](../../docs/embedding.md) covers putting hxScript in your own application.
- [`../../docs/modes.md`](../../docs/modes.md) covers what compiling is worth and where it still differs.
