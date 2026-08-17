# Embedding hxScript

Putting the library into a Haxe project: running scripts, giving them your API, letting them subclass
your classes, and compiling them at runtime.

- [`parity.md`](parity.md) covers what a script can and cannot do once it is running.
- [`modes.md`](modes.md) covers interpreting versus compiling, and what compiling is worth.
- [`../examples/battle/`](../examples/battle) is all of this as a runnable program.

---

## Quick start

```
-lib hxscript
```

```haxe
import hxscript.Script;

var script = new Script("
    greeted = 0;
    function greet(who) { greeted++; return 'hello, ' + who; }
", "hello");

script.start();                    // runs the program top to bottom
script.call("greet", ["world"]);   // "hello, world"
script.variables.get("greeted");   // 1
```

That is a working embed. If the build also has lime, openfl, flixel, flixel-addons, flixel-ui or
heaps in it, that same line wires the library for scripting as well.

The build says so, once, in one block:

```
      _                             _         _
     | |__  __  __ ___   ___  _ __ (_) _ __  | |_
     | '_ \ \ \/ // __| / __|| '__|| || '_ \ | __|
     | | | | >  < \__ \| (__ | |   | || |_) || |_
     |_| |_|/_/\_\|___/ \___||_|   |_|| .__/  \__|
                                      |_|
     hxscript 2.0.0   hashlink   HashLink bytecode compiler
     wired    heaps
     reach    52 type(s), 4 abstract(s), 14 global(s), 3 bridge(s)
     native   built export/hlc/Sandbox.exe
```

The counts are one real build's and yours will differ; what to read them for is whether each is
non-zero. The line that matters most is the `hxscript 2.0.0 ...` one, which names the backend.
**A compiled backend is opt-in on both targets that have one**, and a build meaning to have one and
not having it is a program running scripts at a fraction of the speed it was measured at, with
nothing anywhere saying so. That line says which of the two you got.

`-D hxscript_no_banner`, or `HXSCRIPT_NO_BANNER=1` in the environment, prints nothing. `NO_COLOR`
keeps the block and drops the escapes. `-D hxscript_verbose` is separate and still prints the
per-item detail underneath.

## Giving scripts your own code

Two defines and two pieces of metadata cover most of it.

```xml
<haxedef name="hxscript_host" value="game" />
```

That names the packages holding your own classes. The setup reads their source for two marks:

```haxe
package game;

@:scriptable                     // scripts may `extend` this
class Entity {
    public function new(name:String) { ... }
    public function greet():String { ... }
}
```

```haxe
package game;

@:scriptAmbient                  // scripts may name this without importing it
class Api {
    @:scriptStatic('build')      // a script writing `build` gets this static
    public static var version:String;
}
```

A script then writes ordinary Haxe:

```haxe
class Bandit extends game.Entity {
    public function new() super('bandit');
    override public function greet():String return 'I ambush you, says ' + name;
}
```

and what comes back is a real instance of your class:

```haxe
var cls:ScriptedClass = cast world.resolve('Bandit');
var made:game.Entity = cls.typeCreateInstance([]);

made is game.Entity;   // true: hand it to any native code taking an Entity
made.greet();          // your own call site runs the script's override
```

No bridge to write, no `include` to add, and no `Expose.apply()` to call. `@:scriptable` is what
generates the bridge, and the runtime half is installed by the first `Script`, `Module` or
`Environment` you construct.

> **`@:scriptAmbient` and `@:scriptStatic` are read from source text**, so they only take effect for
> packages `hxscript_host` names. A type outside those packages is still reachable by an explicit
> `import` in the script, exactly as in Haxe.

Add `-D hxscript_verbose` once and read what it prints. It lists every library detected, every bridge
generated and every shim registered, which is the fastest way to confirm the setup did what you think.

[how-it-works.md](how-it-works.md#part-zero-how-the-library-reaches-your-game) draws the whole of
that setup as one diagram, compile-time half and runtime half, which is worth a look if any of it
surprises you.

---

## Build flags

Everything the library reads. Only the first group is likely to concern you.

### Setup

| Flag | Effect |
| --- | --- |
| `-lib hxscript` | the whole of the setup, including for a game library already in the build |
| `-D hxscript_host=<packages>` | comma-separated packages to scan for `@:scriptable` and `@:scriptAmbient` |
| `-D hxscript_verbose` | print every type, bridge and abstract the setup touched, under the block it already prints |
| `-D hxscript_no_banner` | print nothing at all. `HXSCRIPT_NO_BANNER=1` does the same from the environment |
| `-D hxscript_keep=<types>` | comma-separated standard-library types to keep beyond the default set. See [dead code elimination](#dead-code-elimination) |
| `-dce no` | keep the standard-library members scripts reach by reflection. See [dead code elimination](#dead-code-elimination) |

### Behaviour

| Flag | Effect |
| --- | --- |
| `-D hxscript_dynamic` | turn off runtime type enforcement, leaving everything dynamic |
| `-D hxscript_sandbox` | blacklist `Sys`, `sys.io.File`, `sys.io.Process`, `sys.FileSystem` and `sys.net.Socket` |
| `-D hxscript_profile` | count how often evaluation crosses from one interpreter to another |

### Compiling at runtime

Two targets can run a script as their own bytecode, and each takes one flag.

| Flag | Effect |
| --- | --- |
| `-D hxscript_cppia` | on hxcpp, compile the emitter into the build. Without it every module reports as skipped |
| `-D scriptable` | hxcpp's own flag, which makes your types reachable from bytecode |
| `-D hxscript_hl` | on HashLink, the same, and build the native module the loader needs |
| `-D hxscript_cppia_bool_compat` | declare a `Bool` field with no type, for a stock hxcpp. See [`HXCPP-ISSUES.md`](../HXCPP-ISSUES.md), issue 1: right interpreted, still wrong jitted |

On any other target the compiler does not exist and every script is interpreted.

HashLink needs one thing hxcpp does not: a native module, because the VM's bytecode loader is
compiled into `hl.exe` rather than into `libhl` and a program has no way to reach it. **`-lib
hxscript -D hxscript_hl` builds it for you**, from the sources the library carries, against whatever
HashLink your `HLPATH` or your path points at. Where it goes depends on which HashLink output you
write:

| Output | What happens |
| --- | --- |
| `-hl game.hl` | `hxscript.hdll` is built beside it, which is where the VM looks |
| `-hl out/game.c` | the module is compiled in and `out/game` is linked, since HL/C has nowhere to put a library |

Either way the flag is the whole of it, the way `-D hxscript_cppia` is on hxcpp.

It is skipped when it is already there and was built for the same HashLink, which is recorded beside
it rather than guessed from timestamps: an upgraded VM leaves a module whose struct offsets are
silently wrong, and that is the one failure this is all arranged to avoid.

**Nothing here can fail your build.** No HashLink, no compiler, or a version the carried loader does
not match, and you get one warning naming the thing to install. The natives are declared optional to
HashLink, so the program starts exactly as it would have and interprets every script.

| Flag | Effect |
| --- | --- |
| `-D hxscript_native_out=<path>` | link the HL/C binary somewhere other than beside its C |
| `-D hxscript_no_native` | never build it; you are producing it yourself |
| `-D hxscript_no_jit` | build the runtime without the loader, so every script is interpreted |

`src/hxscript/hl/native/build.sh` does the same by hand, and takes `--src <hashlink tree>` for
building against a HashLink the carried loader does not match.

### Turning parts of the setup off

Each disables one step, for a host that would rather do it itself or is minimising binary size.

| Flag | Effect |
| --- | --- |
| `-D hxscript_no_autowire` | the whole compile-time setup |
| `-D hxscript_no_keep` | keeping the standard-library types scripts reach |
| `-D hxscript_no_bridges` | generating a bridge per scriptable base. The expensive step |
| `-D hxscript_no_abstracts` | giving native abstracts a runtime form |
| `-D hxscript_no_shims` | registering emulations for members with no runtime form |
| `-D hxscript_no_native` | building HashLink's native module, which only a `-D hxscript_hl` build does |

Those are all or nothing per step. **`-D hxscript_setup_skip=<name>` is the finer instrument**, and
drops one library's wiring while leaving the rest: `-D hxscript_setup_skip=flixel-ui` for a build
that has the library but no scripted UI.

heaps ships as two records so this reaches half of it. `-D hxscript_setup_skip=heaps3d` keeps every
`h2d` type, `h3d.Vector`, `h3d.Matrix` and `h3d.mat.Texture`, and drops the 3D scene graph: **eleven
bridges become two, and the sandbox binary goes from 8.68 MB to 7.56 MB.** Worth having for a 2D
project, and nothing to do for a 3D one, which is why it is off by default rather than on.

## Metadata

| Mark | Goes on | Effect |
| --- | --- | --- |
| `@:scriptable` | a host class | scripts may `extend` it; the bridge is generated |
| `@:scriptAmbient` | a host type | scripts may name it without importing it |
| `@:scriptStatic('name')` | a host static | a bare name in a script resolves to it. Without an argument the field's own name is used |
| `@:snapshot` | a scripted static, or its class | its value survives a reload. On the class, every static does |

## Runtime configuration

`hxscript.Config` is read at every interpreter reset, so set these before the first script runs.

| Field | Effect |
| --- | --- |
| `globalVariables` | bare names bound to values, for every script in the process |
| `globalImports` | types that resolve without an `import`. See the warning below |
| `globalStatics` | bare names answered by a host static, as `owner.path::field` |
| `blacklist` | types scripts may not touch, by `ByType`, `ByModule` or `ByPackage` |
| `strictAccess` | enforce `private` on script-declared members |
| `typedMode` | runtime type enforcement, on unless `-D hxscript_dynamic` |
| `callShims` | a closure standing in for a member with no runtime form, keyed `Owner.method` |
| `preprocessorValues` | values a script's `#if` can test |
| `typeProxy` | a stand-in class for a native type the target cannot reflect on |
| `interpClass` | your own `Interp` subclass |

---

## Values a script can see

A script's `variables` map is its global scope:

```haxe
greeted = 0;        // a script variable, visible in script.variables
var notShared = 0;  // a local of the program, not visible
```

Declared functions are script variables, which is why `call()` finds them.

**`start()` clears `variables` before it runs.** It calls `setDefaults()`, which wipes the map and
re-applies the global tables, so anything you set beforehand is gone. Put values in one of these:

| Scope | Where | When |
| --- | --- | --- |
| One world | `world.variables.set(...)` on an `Environment` | the usual choice |
| Every script in the process | `Config.globalVariables.set(...)` | constants, version numbers |
| One script, after `start()` | `script.variables.set(...)` | a value that script alone needs |

```haxe
var world = new Environment();
world.variables.set("damage", 21);

new Script("damage * 2", "w", world).start(); // 42
```

A bare `Interp` is the one case needing a step. `Script`, `Module`, `ImportModule` and every scripted
type call `setDefaults()` for you; the constructor deliberately does not, because all of them called
it again immediately afterwards. If you build one yourself, seed it:

```haxe
var interp = new Interp();
interp.setDefaults();   // globals, the default import, `trace`
interp.execute(program);
```

### Types a script can name

`@:scriptAmbient` covers your own packages. For anything else, register a global import:

```haxe
import hxscript.syntax.Expr.ImportMode;

Config.globalImports.set("game.Entity", INormal);
```

> **Two sharp edges.**
> Imports resolve *before* variables, so a global import shadows a variable of the same name. If you
> bind `File` to a sandboxed replacement, do not also global-import the real one.
>
> A global import that cannot resolve **throws out of the `Script` constructor, uncaught**. Global
> imports are applied on every interpreter reset, before your error handlers exist, so it escapes as
> `Type not found: X`. It happens when the name is not in this build, and equally when it is
> blacklisted. Guard the registration:
>
> ```haxe
> for (path in myTypes)
>     if (TypeCollection.main.fromPath(path) != null)
>         Config.globalImports.set(path, INormal);
> ```
>
> A script's own `import` of a missing type is fine by comparison, and is reported through
> `onProgramError` like any other script error.

---

## Subclassing, without `hxscript_host`

`@:scriptable` is the short way and needs the package scanned. Where that does not fit, because the
base is in a library you do not own or you want the list somewhere explicit, declare the bridge by
hand: an empty class extending the base, implementing `hxscript.IScripted`.

```haxe
package bridges;

class ScriptedEntity extends game.Entity implements hxscript.IScripted {}
```

The `@:autoBuild` on the interface generates an override of every inherited method that dispatches to
the script when it defines one and falls through to `super` otherwise.

Then force it into the build, since nothing in your code references it:

```
--macro include('bridges')
```

> Without that you get `Class Entity can't be extended for scripting` the moment a script tries,
> which reads like a library limitation and is a missing build flag.

Two constraints either way:

- **One generated override per inherited method** that is not `inline` or `final`, per base. Bridging
  a class with a large method surface is not free in code size, so bridge what people actually
  subclass. `-D hxscript_verbose` lists what was generated.
- **`final` classes cannot be bridged.** That is a useful lever rather than only a limit: keeping a
  hot-path class `final` lets the compiler devirtualise it and keeps it off the scriptable list on
  purpose.

[`advanced.md`](advanced.md#1-generating-bridges) generates bridges from a list with a macro, for a
host that wants neither the scan nor the hand-written files.

---

## Loading a folder of scripts

A `Module` is one source file's worth of declarations. An `Environment` is the world they live in and
what scripts resolve names against.

```haxe
var world = new Environment();

for (file in FileSystem.readDirectory(dir))
    world.addModule(new Module(File.getContent('$dir/$file'), name, [], '$dir/$file'));

world.variables.set("roll", function(sides:Int) return 1 + Std.random(sides));
world.start();
```

Every module and script in that world sees the same `world.variables`.

**Do not name scripts from the host.** Writing `spawn("HiveQueen")` in game code undoes most of the
benefit, because every new piece of content then needs a host change. Ask the world what it has:

```haxe
for (module in world.modules)
    for (name => type in module.types)
        if (type is ScriptedClass) { ... }
```

Filter those by whether the class descends from a native base, and by a static the script declares
about itself. That is enough for content to announce what it is, so dropping a file into the folder
becomes the whole installation step.

### What a script can declare

Not just classes. A module holds the same mix a Haxe module does:

```haxe
enum Element { Physical; Fire(intensity:Int); }

typedef Loot = { var gold:Int; @:optional var charm:String; }

interface Lootable { public function loot():Loot; }

abstract Damage(Int) from Int to Int {
    public function new(v:Int) this = v;
    @:op(A + B) public function add(rhs:Damage):Damage return new Damage(this + rhs);
}
```

Enums carry parameters and destructure in `switch` with guards. Typedefs are checked structurally, by
field and by field type, and `?x:Int` may be absent. Interfaces work between scripted classes.
Abstracts carry their operators, `from`/`to` and `@:forward`, at the cost of a wrapper at runtime.

- **Types from another module need importing**, exactly as in Haxe. One environment is still not one
  scope: `import Combat;` is what brings `Element` in, and a constructor from another module is
  written `Element.Fire(6)`.
- **A script cannot redeclare a field its native base already has.** The error names it, and it is
  usually a collision with something ordinary like `name`.

### Reloading

Snapshot the world, drop it, and build a new one from freshly read sources:

```haxe
env.snapshot();   // preserves statics marked @:snapshot
env = null;
```

Track file modification times to decide when. A path-to-timestamp map and a `stale()` check is the
whole of it.

---

## Errors

Everything that goes wrong, whether parsing, building a type, running or compiling, arrives at
[`Sink`](../src/hxscript/error/Sink.hx) as a
[`Diagnostic`](../src/hxscript/error/Diagnostic.hx) carrying the origin, line, column, the source line
it happened on and what usually causes it. Until you ask for them, they are printed:

```
Playground.hx:42: character 17
  var x = foo(;
              ^
Unexpected token ';'
```

Take them over, which is what a host with a window rather than a terminal wants:

```haxe
hxscript.error.Sink.listen(function(d) {
    myConsole.log(d.toString());   // or read d.origin, d.line, d.hint yourself
});
```

Listening also stops the default printing. `Sink.history` holds the last few for a backend with
nowhere to print at all. `Diagnostic.phase` is worth branching on: `PRun` is caused by what a script
did, while `PEmit`, `PLoad` and `PSetup` are caused by how the host was built.

**The hint is the part that saves the afternoon**, because the message names the symptom and the
cause is usually somewhere it does not mention. `Unknown identifier: FlxG` is a message about a script
and a problem in a build file, so the diagnostic tells them apart: a name in the build but not in
scope quotes the `import` to add; a name in no build at all says the package was never force-compiled;
a misspelling suggests the spelling that exists; and a call that resolved to nothing says whether the
member is missing or `inline`, and names the `Config.callShims` key to register.

### Per-script hooks

Use these when one script's errors should be handled differently from the rest:

```haxe
var s = new Script("null.explode();", "boom");
s.onProgramError = function(e) log(ScriptedClass.describeError(e));
s.start();   // returns null, sets s.failed
```

`e.message` is the message alone. `describeError` adds the **call stack** across script boundaries and
into your own code, and passes a non-exception value through unchanged. A scripted class's own hooks
(`onExpressionError`, `onInstanceError`, `onStaticError`) render through the same function.

These hooks are empty by default rather than tracing, because everything reaching them has already
gone to the sink. If you print from one as well, either use `Sink.listen` or set `Sink.printing` to
false.

> **Parse errors are different.** Parsing happens inside the constructor, so a handler assigned
> afterwards is already too late, and the program is left null:
>
> ```haxe
> var bad = new Script("this is not haxe", "bad");
> bad.program == null;   // true. `failed` is still false: only start() sets that
> ```
>
> To have the handler fire, construct empty and parse explicitly:
>
> ```haxe
> var s = new Script("", "deferred");
> s.onParsingError = function(e) log(e.message);
> s.parse(source);
> ```

One gap: a method declared in a `Module` runs on that module's interpreter, and each interpreter owns
its own stack with no link to its caller, so that frame does not appear in the calling script's trace.

---

## Compiling at runtime

Optional, and only where the target has bytecode of its own: **hxcpp**, through cppia, and
**HashLink**, through its own loader. On either a module can be translated and loaded as a real class
instead of being walked as a tree; everywhere else scripts are interpreted and this section does not
apply. [`modes.md`](modes.md) covers what that is worth and when it repays the cost; this section is
the wiring.

The defines below are hxcpp's. HashLink wants `-D hxscript_hl` instead, and nothing else: the native
module its loader needs is built by the same macro, which
[the build flags](#build-flags) covers.

**Nothing here happens on its own.** The defines make the compiler *available*, and that is all. If
you never ask, every script is interpreted exactly as before. What to compile, when, and what to do
about a module the compiler will not take are decisions only the host can make.

```
-D hxscript_cppia
-D scriptable
-dce no
```

Check the first one at startup rather than wondering, because without it every module reports as
skipped, which looks exactly like a compiler that refuses everything:

```haxe
if (!hxscript.compile.Compiler.available)
    trace(hxscript.compile.Compiler.unavailable());
```

**The whole integration:**

```haxe
import hxscript.compile.Compiler;
import hxscript.macro.Expose;

// once at startup: the interpreted side is automatic, the compiled side is not
Compiler.ambient = Expose.ambient();
Compiler.statics = Expose.statics();

// once per world, whenever you want it compiled
var report = Compiler.compile(env);

for (skip in report.skipped)
    trace('interpreting ${skip.name}: ${skip.reason}');
```

`Compiler.compile` offers every module in the world, loads what compiled, registers the classes
against the world and turns substitution on. A module it cannot take is reported and left to the
interpreter, so the call is safe on any world and safe to repeat. Calling it again after a reload
binds what it built last time rather than compiling twice. Both paths produce the same class, so
nothing downstream needs to know which one it got.

> **The two `Compiler` lines are the trap.** Anything you give scripts through `Config` or through
> `@:scriptAmbient` is injected into an *interpreter*, and compiled code does not have one. A bare
> name that resolved fine interpreted refuses to compile unless the compiler is told where it really
> lives. Setting one side only gives a script that works until the day it is compiled, or the
> reverse.

Everything below is the same work spelled out, for a host that wants to compile a subset, cache the
bytes, or decide something the facade decides for it.

### Driving it yourself

**This part is hxcpp's alone.** `Compiler` is the cross-target facade and names whichever backend the
build carries; the layer under it is a class per target, and only `hxscript.cppia.Backend` hands back
bytes for a host to do as it likes with. `hxscript.hl.Backend` emits into the running process through
the loader it carries and has no equivalent, so a HashLink host drives `Compiler` and nothing lower.

```haxe
var decls = new Parser().parseModule(source, 'Goblin', 0, ['mods']);
var result = hxscript.cppia.Backend.compile([{name: 'mods.Goblin', decls: decls}]);

if (result.bytes != null) {
    var module = cpp.cppia.Module.fromData(result.bytes.getData());
    module.boot();
    var goblin = Type.createInstance(module.resolveClass('mods.Goblin'), []);
}
```

`bytes` is null when nothing in the batch compiled. `skipped` always says why, per module, in words
meant to be read.

The three optional arguments are what the facade fills in for you:

```haxe
Backend.compile(inputs,
    ['game.Player', 'game.World'],       // ambient: types usable without an import
    ['mods.Shared'],                     // external: scripted classes NOT in this batch
    ['player=game.Player::current']);    // statics: bare name -> a real host static
```

`external` names scripted classes in another module or world. A module naming one is left interpreted
on purpose: cppia resolves a class either inside the module being loaded or as a host class, and a
scripted class elsewhere is neither, so the reference would fail to link and take the whole load down.

### Registering what you compiled

`Compiler.compile` does this for you, and skipping it is the one mistake here that reports success:

```haxe
for (input in inputs) {
    if (result.compiled.indexOf(input.name) < 0)
        continue;   // skipped; it stays interpreted

    for (path in Backend.declaredPaths(input.decls)) {
        var cls = module.resolveClass(path);
        if (cls != null)
            env.compiled.set(path, cls);
    }
}

env.substituting = true;   // as soon as ANY class compiled, not once all of them have
```

> Resolving the class yourself is not enough. Every other route to it, whether another script naming
> it, `new` from interpreted code or a static read through it, goes through the world, and the world
> knows nothing about what you just built. Skip the registration and everything runs interpreted
> while your logging reports it as compiled, because nothing errors: the compile succeeded, the
> module loaded, and the class you resolved is real. It is simply not the one anything else reaches.

`substituting` is what makes it safe. A compiled class carries its own statics and its own identity,
so the hazard is a class existing both ways at once with the two halves disagreeing about its state.
What prevents that is not compiling everything, it is every reference going the same way, which is
why the flag goes on as soon as one class is compiled.

`result.compiled` holds the *module* names you passed in rather than class paths, and one module can
declare several classes, which is what `declaredPaths` is for.

### Several modules at once

Pass them in one call. Every module is declared before any is emitted, so they may refer to each other
in any order.

**Skips cascade.** If `Loot` is refused and `Boss` names it, `Boss` is skipped too, reported as
`uses mods.Loot, which is interpreted`. A reference that cannot link rejects the whole loaded module,
so a batch is only as compilable as what it depends on. Group what belongs together rather than
throwing everything in at once.

### The JIT

Once at startup, before any module loads. It is a process-wide switch in hxcpp rather than a
per-module one:

```haxe
cpp.cppia.Host.enableJit(true);
```

### Caching the bytes

`Compiler` holds compiled classes in memory for the life of the process, which is what makes a reload
free, but writes nothing to disk. `result.bytes` is ordinary `haxe.io.Bytes`:

```haxe
sys.io.File.saveBytes('cache/Goblin.cppia', result.bytes);

// next launch
var module = cpp.cppia.Module.fromData(sys.io.File.getBytes('cache/Goblin.cppia').getData());
module.boot();
```

Bytes written by one process load in another, and bytes written by one build of the host load in a
**rebuilt** host, because names are resolved when the module loads rather than baked in when it was
compiled.

What that defers rather than removes: if a later build drops or renames something a cached module
used, the failure appears when those bytes load. Key the cache on the source's own hash, and treat a
load failure as "recompile from source", which is cheap and always correct.

---

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `Type not found: X` thrown out of `new Script(...)`, uncaught | a global import that cannot resolve | guard the registration; check the type is in the build and not blacklisted |
| `Unknown identifier: X` | the type was never compiled in | name its package in `hxscript_host`, or force it in |
| `Class X can't be extended for scripting` | no bridge | `@:scriptable` on it, or a hand-written bridge kept in the build |
| `not bridged: X (final)` under `-D hxscript_verbose` | a scanned `@:scriptable` class is `final`, `extern`, an interface, or `private` | those four cannot be bases. Scripts still import and construct it, so reach it by holding one rather than by being one |
| `bridge name ScriptedX already taken` | two bases share a simple name | nothing to do since 2.0.0; the second takes its path flattened. Older versions dropped it |
| `Cannot call null` | dead code elimination removed the member | `-dce no`, or `@:keep` |
| `Cannot call null` on an `inline extern` | it has no runtime form at all | register a closure in `Config.callShims` |
| A native abstract's members do nothing | no runtime form | `@:build(hxscript.macro.Abstract.build())` on it |
| Parse handler never fires | parsing happens in the constructor | construct empty, then `parse()` |
| Compiles "successfully", still interpreted | the classes were never registered against the world | `env.compiled.set(...)` and `env.substituting = true` |
| A bare name compiles interpreted but not compiled | `Compiler.ambient` / `statics` were never set | set both from `Expose` |
| Every module reports skipped | built without the define | `-D hxscript_cppia` |
| A field errors as already inherited | the script redeclares a base field | rename it, or `override` |
| The setup did not do what you expected | | `-D hxscript_verbose` prints what it wired |

### Things that bite people

- **`inline` is not the reason a member is missing.** An `inline` method still has a runtime form.
  What removes it is DCE noticing every call site inlined it, so nothing references it. The two get
  confused constantly and the fixes differ: `-dce no` or `@:keep` for this, a `callShim` for a genuine
  `inline extern`.
- **Build macros hold type paths as strings**, which the compiler cannot check. Rename a bridged base
  or move a package and nothing fails at compile time. It fails when a script asks.
- **Abstracts declared in scripts need no setup.** Only native ones need the build macro.

### Dead code elimination

Under `-dce std`, which is hxcpp's default, a method your own code never calls statically is stripped
from the build, and a script reaching it by reflection gets `Cannot call null`. It looks like a
library bug and is not.

The library covers the worst of it. `extraParams.hxml` runs
[`Keep`](../src/hxscript/macro/Keep.hx), which pulls `IntIterator`, `Reflect`, `Type`,
`haxe.ds.StringMap`, `EReg`, `List`, `haxe.ds.List`, `Lambda`, `Date` and `Sys` into the build and
marks them and their fields kept, so those work under `-dce std` with nothing from you. It handles two
failures separately because they are different: **keeping** saves a type already in the build from
being stripped (`Cannot call null`), while **including** puts one in that nothing referenced at all
(`Unknown identifier`), and `@:keep` cannot help with the second.

`Keep.types` is a plain array you can add to, and
**`-D hxscript_keep=StringTools,haxe.Json` adds to it without editing the library**. The neighbours
worth knowing about, left out by default because each costs binary size for a program that does not
use them: `haxe.ds.IntMap`, `haxe.ds.ObjectMap`, `haxe.ds.EnumValueMap`, `StringTools`, `haxe.Json`
and `haxe.Timer`.

`Lambda` is in the default list rather than among those neighbours, and the reason is worth knowing
because it is not about size. Leaving it out was not neutral: on hxcpp something else in an ordinary
build referenced it and a script could call it, while on eval and HashLink nothing did and the same
script could not. A default that changes what a script can reach depending on which target the host
was built for is worse than either answer.

Members commonly reached from scripts that a bare program strips, and that `-dce no` or `@:keep`
restores:

| type | members |
| --- | --- |
| `IntIterator` | `hasNext`, `next` |
| `Reflect` | `setField`, `getProperty`, `setProperty`, `fields`, `callMethod`, `isFunction`, `compare`, `copy`, `makeVarArgs` |
| `Type` | `getClass`, `getClassName`, `createInstance`, `getInstanceFields`, `typeof`, `enumEq` |
| `haxe.ds.StringMap` | `set`, `get`, `exists`, `remove`, `keys`, `iterator` |
| `EReg` | `match`, `matched`, `replace`, `split` |
| `List` | `add`, `push`, `pop`, `remove`, `iterator` |
| `Date` | `getTime`, `getFullYear`, `getHours`, `toString` |
| `Sys` | `time`, `getEnv` |

`IntIterator` is the one worth knowing by name: it is why `for (i in 0...n)` fails on hxcpp in several
hscript-family libraries, and it is a property of how the host was built rather than of the library.

Whole classes are a separate case, where `-dce no` does not help because the type has to be reached
somehow: `StringTools` under `-dce std`, and `haxe.Json` and `haxe.Timer` in a bare program under
either setting. `-D hxscript_keep` is the answer to all three. `Lambda` used to be on that list and is
now kept by default, for the portability reason above. Every `Math` and `Std` static, and the `Array`
and `String` instance methods, survive either way, because the runtime itself references them.

**What survives depends on your build**, since a member lives when anything references it statically,
so a large host keeps far more alive by accident than a bare one.
[`../apps/sandbox/`](../apps/sandbox) reports what a script can actually reach in a given build, which
is the answer that matters rather than a general figure.

---

## Printing scripts back to source

`hxscript.syntax.Printer` turns a parsed AST back into source, for expressions and for module
declarations, which makes it usable for a formatter, a migration tool, or showing a user what their
script parsed as:

```haxe
var parser = new hxscript.syntax.Parser();
parser.allowTypes = parser.allowJSON = parser.allowMetadata = true;

var printer = new hxscript.syntax.Printer();
for (d in parser.parseModule(source, 'MyScript.hx', 0, ['my', 'pack']))
    trace(printer.exprToString({e: EDecl(d), pos: d.pos}));
```

The bar it is held to is **round-trip** rather than readability: printing, reparsing and printing
again produces the same text. Comments are not preserved, since the parser does not keep them.

## Where to go next

- [`advanced.md`](advanced.md) generates bridges with a macro, makes native abstracts visible,
  subclasses the interpreter, and covers every surface for binding your API.
- [`modes.md`](modes.md) covers interpreting versus compiling, and what each costs.
- [`parity.md`](parity.md) covers what scripts can do compared to real Haxe.
- [`performance.md`](performance.md) covers how to measure a change without fooling yourself.
- [`../examples/battle/`](../examples/battle) is this guide as a runnable program.
- [`../examples/workbench/`](../examples/workbench) is the other use of the library, where the program
  itself is written in script.
- [`../apps/sandbox/`](../apps/sandbox) is an application rather than an example, and its headless
  check reports what a script can reach in a real build.
