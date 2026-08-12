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

---

## Build flags

Everything the library reads. Only the first group is likely to concern you.

### Setup

| Flag | Effect |
| --- | --- |
| `-lib hxscript` | the whole of the setup, including for a game library already in the build |
| `-D hxscript_host=<packages>` | comma-separated packages to scan for `@:scriptable` and `@:scriptAmbient` |
| `-D hxscript_verbose` | print what the setup wired |
| `-dce no` | keep the standard-library members scripts reach by reflection. See [dead code elimination](#dead-code-elimination) |

### Behaviour

| Flag | Effect |
| --- | --- |
| `-D hxscript_dynamic` | turn off runtime type enforcement, leaving everything dynamic |
| `-D hxscript_sandbox` | blacklist `Sys`, `sys.io.File`, `sys.io.Process`, `sys.FileSystem` and `sys.net.Socket` |
| `-D hxscript_profile` | count how often evaluation crosses from one interpreter to another |

### Compiling at runtime

| Flag | Effect |
| --- | --- |
| `-D hxscript_cppia` | hxcpp: compile the cppia emitter into the build |
| `-D scriptable` | hxcpp's own flag, which makes your types reachable from bytecode |
| `-D hxscript_hl` | HashLink: compile the HashLink emitter into the build |

Two targets have a compiler and no others do; everywhere else every script is interpreted. Only one
emitter is ever in a build, so nothing has to choose between them at runtime. Without the flag for
your target every module reports as skipped, which looks exactly like a compiler that refuses
everything.

### Turning parts of the setup off

Each disables one step, for a host that would rather do it itself or is minimising binary size.

| Flag | Effect |
| --- | --- |
| `-D hxscript_no_autowire` | the whole compile-time setup |
| `-D hxscript_no_keep` | keeping the standard-library types scripts reach |
| `-D hxscript_no_bridges` | generating a bridge per scriptable base. The expensive step |
| `-D hxscript_no_abstracts` | giving native abstracts a runtime form |
| `-D hxscript_no_shims` | registering emulations for members with no runtime form |
| `-D hxscript_no_hdll` | building the HashLink extension, and on HL/C writing what to link |

## Metadata

| Mark | Goes on | Effect |
| --- | --- | --- |
| `@:scriptable` | a host class | scripts may `extend` it; the bridge is generated |
| `@:scriptAmbient` | a host type | scripts may name it without importing it |
| `@:scriptStatic('name')` | a host static | a bare name in a script resolves to it. Without an argument the field's own name is used |
| `@:snapshot` | a scripted static | its value survives a reload |

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

Optional, and only on **hxcpp** and **HashLink**. On those a module can be turned into bytecode the
target loads and runs, instead of being walked as a tree; everywhere else scripts are interpreted and
this section does not apply. [`modes.md`](modes.md) covers what that is worth and when it repays the
cost; this section is the wiring.

**Nothing here happens on its own.** The defines make the compiler *available*, and that is all. If
you never ask, every script is interpreted exactly as before. What to compile, when, and what to do
about a module the compiler will not take are decisions only the host can make.

On hxcpp:

```
-D hxscript_cppia
-D scriptable
-dce no
```

On HashLink, whether the program ships as bytecode or as HL/C:

```
-D hxscript_hl
-dce no
```

Check at startup rather than wondering. `Compiler.available` answers for whichever target you built
for, and on HashLink it also answers for the extension below, which on that target is not only a
build-time question:

```haxe
if (!hxscript.compile.Compiler.available)
    trace('no compiler in this build; everything will be interpreted');
```

`Compiler.unavailable()` gives the same answer as a sentence saying which of the several reasons it
is, which is worth reporting on HashLink and never interesting on hxcpp. It is
[covered below](#why-nothing-can-be-compiled).

### The HashLink extension

HashLink needs one thing hxcpp does not: some C of its own. Its bytecode loader is compiled into
`hl.exe` rather than into `libhl`, on every platform, so a host has no way to reach it; the extension
carries hashlink's own `code.c`, `module.c` and `jit.c` and calls them, which keeps the VM stock.

**How that C gets into the process is the only thing that differs between the two ways of shipping
HashLink**, and the same `hxscript.c` does both. On HL/JIT it is `hxscript.hdll` beside what runs,
which is the rest of this section. On HL/C it is linked in, which is [the next one](#shipping-as-hlc).

**On HL/JIT the extension is optional at runtime, not just at build time.** A program built with
`-D hxscript_hl` runs with or without it: missing, corrupt, or built for a different VM, the library
reports itself unusable and every script is interpreted, exactly as if the define had never been set.
Shipping the extension is a decision you can make per release, or leave to whoever is running it,
rather than one baked into the binary. HL/C is the one place that is not true, for the reason given
there.

**You do not normally build it by hand.** `-D hxscript_hl` is taken as asking for the extension too,
so a build produces it next to its own output and says so once:

```
hxscript: built bin/hxscript.hdll
```

What it works out for itself, all from this machine: the VM, from `HLPATH` or `hl` on the path or the
usual install directories; its version, from `hl --version`; a hashlink source tree, from `HL_SRC` or
from beside the VM; and a compiler, from `CC` or mingw-w64, `cc`, `gcc` or `clang`. Nothing is
rebuilt when it is already current, and the version it was built for is recorded beside it so that
upgrading HashLink rebuilds rather than leaving a stale one in place.

**A build downloads nothing.** The one thing it cannot work out is the hashlink sources, because the
binary distributions ship `hl.h` and none of the rest. If the machine has no tree, the build says so
and stops there rather than going and getting one.

That is what the scripts beside `hxscript.c` are for. They do the same work with no Haxe involved,
and they are the only thing here that will fetch anything, after asking:

```sh
sh hdll.sh                     # ask about anything it cannot work out
sh hdll.sh --out bin           # put it somewhere in particular
sh hdll.sh --out bin --yes     # answer yes to everything, for a build machine
```

```bat
hdll.bat --out bin
```

```
No hashlink sources are on this machine, and they cannot be worked out: the binary
distributions ship hl.h and none of code.c, module.c or jit.c, which this is built from.

Fetch the hashlink 1.16.0 sources from https://github.com/HaxeFoundation/hashlink ? [y/N]
```

Answering no ends it with the version to go and get. With nobody there to answer, as on a build
machine, it takes the no and says the same thing, so a script in CI never reaches the network unless
`--yes` said it could. `--hl`, `--src` and `--out` set what it would otherwise look for, and `HLPATH`,
`HL_SRC` and `CC` do the same from the environment.

`haxelib run hxscript hdll [directory]` does the local-only half from wherever the library is
installed, and `-D hxscript_no_hdll` turns the automatic step off.

**Version matching is checked twice, not trusted once.** At build time `hl.h` carries `HL_VERSION`,
so a source tree that does not match the VM is refused before anything is compiled. At runtime the
extension puts values through libhl's own allocators and reads them back at the offsets it was
compiled to expect; if they do not land there, `Compiler.available` is false and scripts are
interpreted rather than run against a layout nobody agrees on.

Both exist because the failure has no symptom where the mistake is. The extension does not merely
call libhl, it shares structures with it: the jit it carries emits machine code holding literal byte
offsets into objects libhl allocated. The compiler only sees the headers it was handed and the linker
matches names rather than layouts, so a mismatched pair builds cleanly and then reads a field from
the wrong place.

The build deliberately does not carry `gc.c` or `allocator.c`. Those are already in the running
`libhl`, and a second copy would give loaded modules their own heap, leaving their objects invisible
to the host's collector.

### Shipping as HL/C

Everything above is HL/JIT: the program is bytecode, `hl` runs it, and the extension is a `.hdll` the
VM loads by name. **HL/C is the other way**, and the one a game with mod support is most likely to
be built as. `haxe -hl out.c` writes C that compiles to an ordinary native binary, with no VM
process and no bytecode file beside it.

Compiled scripts work there. `libhl` exports the executable-memory allocator the jit needs, and the
loader is carried in for the same reason it is carried into the `.hdll`: `hl_code_read` and
`hl_module_init` live in `hl.exe` rather than in `libhl` on every platform, so neither way of
shipping can reach them without them.

**The extension is linked rather than loaded, and the same `hxscript.c` does both.** Haxe writes a
header for the natives a program binds, and it declares exactly the symbols that file already
defines, so nothing about it changes:

```c
HL_API hxs_module* hxscript_load(vbyte*,int);
```

**What does not carry over is the `?`.** On HL/JIT the natives are marked optional, so a missing
extension leaves them as stubs and the program interprets. A linked symbol either resolves or the
link fails, so an **HL/C host decides at build time whether it can compile scripts**, where an
HL/JIT host decides at startup. That is a difference in when, not in what: a build that leaves the
extension out is a build that interprets, and everything else about it is the same.

A build with `-D hxscript_hl` on an HL/C target writes `hxscript.flags` beside the generated C, one
argument per line, and says so once. Hand it to whatever drives your native build:

```
hxscript: HL/C links the extension rather than loading it; what to add is in out/hxscript.flags
```

The same list, printed rather than written, for a build you are configuring by hand:

```sh
haxelib run hxscript hlc --flags
sh hlc.sh --flags                 # the standalone script, no Haxe involved
```

```
-I<hashlink>/src -I<hxscript>/src/hxscript/hl
  <hxscript>/src/hxscript/hl/hxscript.c
  <hashlink>/src/code.c <hashlink>/src/module.c <hashlink>/src/jit.c
  -ldbghelp
```

And for someone with no native build of their own, one command that produces the binary:

```sh
haxelib run hxscript hlc out --out game.exe
sh hlc.sh out --out game.exe
```

It reads `hlc.json`, which Haxe wrote beside the C, for the libraries the program binds and for the
file to compile. **One file, not the list.** Haxe writes a file per type and then a main file that
`#include`s every one of them unless `HL_MAKE` says otherwise, so compiling the list as well defines
everything twice. Separate compilation is faster on a machine with cores to spare and is what a real
build system should do; this is the fallback for someone with none.

Two things a first HL/C build runs into, neither of them to do with hxScript: `hlc_main.c`'s entry
point is `wmain`, so Windows needs `-municode`, and it resolves symbols through dbghelp, so it needs
`-ldbghelp`. You will also see `LNK4217` once per native, because the generated header declares them
as imports and this build defines them in the same binary. The linker resolves them locally and says
so; it is not a problem and the shipped tooling filters it.

**Compiling a script replaces machinery the host was already using.** `hlc_main.c` installs
`hlc_static_call` and `hlc_get_wrapper`, which are how a program generated as C makes a call whose
signature is not known until runtime. The first time anything is jitted, `jit.c` overwrites both,
process-wide and permanently, and from then on every dynamic call in the program goes through the
jit's trampoline instead of the table the C generator wrote. This is checked rather than assumed:
`test/hlc/CallbackProbe.hx` runs fifteen signatures before and after the first compile, and they
agree. Exceptions cross both ways and are checked the same way.

**x86 and x86-64 only.** HashLink's jit emits no other machine code. `jit.c` says so itself but only
tests for 32-bit ARM, and arm64 does not define `__arm__`, so there it would compile cleanly and
write x86 bytes into executable memory; hashlink's own Makefile is the plainer statement, since it
skips building the VM on arm64 entirely. So `hxscript.c` compiles its loader only where it can work.

Everywhere else it still defines every native, which is what lets the same file link into a build for
any architecture. There `Compiler.available` is false, `Loader.why()` says why, and every script is
interpreted, which is the answer the library already gives when the extension is absent. That build
needs no hashlink source tree either, only `hl.h`, which the binary distributions do ship:

```sh
haxelib run hxscript hlc out --no-jit
```

**So an Android build works and interprets.** Making compiled scripts worth something there would
mean an arm64 backend for hashlink's jit, or an interpreter for the bytecode this emits. Neither
exists, and nothing here pretends otherwise.

### Why nothing can be compiled

`Compiler.available` is a boolean, and on HashLink a false has four causes that are fixed four
different ways. `Compiler.unavailable()` gives the sentence, on every target, so a host reporting it
does not have to know which target it is:

```haxe
var why = hxscript.compile.Compiler.unavailable();
if (why != null)
    trace('scripts will be interpreted: ' + why);
```

| | |
| --- | --- |
| `Usable` | it works |
| `NotLinked` | no `hxscript.hdll` beside what is running, which only HL/JIT can be |
| `Disagrees` | the extension was built against a different hashlink than the one running |
| `NoLoader` | the build carries no loader, because the jit is x86 and x86-64 only |

`hxscript.hl.Loader.availability` is the same answer as a value rather than a sentence, for a host
that wants to act on which one it is.

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

> **The two `Compiler` lines are the trap on hxcpp.** Anything you give scripts through `Config` or
> through `@:scriptAmbient` is injected into an *interpreter*, and compiled code does not have one. A
> bare name that resolved fine interpreted refuses to compile unless the compiler is told where it
> really lives. Setting one side only gives a script that works until the day it is compiled, or the
> reverse.

### What differs between the two

The call above is the same on both. What it does underneath is not, and four of the differences are
visible from outside.

**A compiled class on hxcpp, a compiled function on HashLink.** cppia produces a real class and the
world substitutes it wholesale, which is what `env.compiled` and `substituting` are for. The
HashLink backend replaces each function on the `ScriptedClass` that declared it with the compiled
one, so there is nothing to register and nothing to substitute. What comes back from a compiled
module is an ordinary function value; the interpreter never learns which kind it got. A module is
still emitted whole or not at all, for the same reason as on hxcpp.

**`Compiler.ambient` and `Compiler.statics` are read on hxcpp only.** A compiled function on
HashLink reaches a host name by asking the *world* when its module loads, so anything you put in
`env.variables` or that `TypeTools` can resolve is found without being declared to the compiler.
The gap that leaves: `statics`, which maps a bare name onto a host static, has no equivalent, so on
HashLink a script naming one of those is refused and stays interpreted rather than resolving.

**Bytes are not a currency on HashLink.** A loaded module's globals have to be filled from the world
in the moment after it loads, so there is no useful step where you hold the bytes. `Compiler.compile`
is the whole interface; the `Backend.compile(inputs, ...)` route below is cppia's.

**One construct is refused on HashLink that compiles on hxcpp**: `v is C`, where `C` is a class the
same batch declares. A module HashLink loads gets its own type table, so an instance it made is its
own type and the world truthfully answers no to a question the script did not ask. Refusing leaves
that module interpreted and right, which is the rule the whole backend follows: never a wrong
answer. Everything else the cppia backend takes, this one takes too.

Everything below is cppia, for a host that wants to compile a subset, cache the bytes, or decide
something the facade decides for it.

### Driving it yourself (hxcpp)

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

HashLink jits whatever it loads and has nothing to switch, so `Compiler.jit` is read there only on
hxcpp and setting it is harmless.

### Caching the bytes (hxcpp)

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
| `Cannot call null` | dead code elimination removed the member | `-dce no`, or `@:keep` |
| `Cannot call null` on an `inline extern` | it has no runtime form at all | register a closure in `Config.callShims` |
| A native abstract's members do nothing | no runtime form | `@:build(hxscript.macro.Abstract.build())` on it |
| Parse handler never fires | parsing happens in the constructor | construct empty, then `parse()` |
| Compiles "successfully", still interpreted | the classes were never registered against the world | `env.compiled.set(...)` and `env.substituting = true` |
| A bare name compiles interpreted but not compiled | `Compiler.ambient` / `statics` were never set | set both from `Expose` (hxcpp; on HashLink `statics` has no equivalent) |
| Every module reports skipped | built without the define | `-D hxscript_cppia`, or `-D hxscript_hl` |
| `Compiler.available` is false on HashLink | no extension beside what runs, or one that does not match this VM | build it; a mismatched one is refused by the runtime layout check rather than corrupting memory |
| The build warns that no VM was found | `hl` is not on the path | set `HLPATH` to the directory holding `libhl` |
| The build warns that no sources were found | there is no hashlink checkout here | get the hashlink sources at the version it named and set `HL_SRC` |
| The build warns that no C compiler was found | there is none | mingw-w64 on Windows, `xcode-select --install` on macOS, `build-essential` on Linux |
| `is` against a scripted class is refused on HashLink | a loaded module's instances are its own type | expected; the module stays interpreted |
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
`haxe.ds.StringMap`, `EReg`, `haxe.ds.List`, `Date` and `Sys` into the build and marks them and their
fields kept, so those work under `-dce std` with nothing from you. It handles two failures separately
because they are different: **keeping** saves a type already in the build from being stripped
(`Cannot call null`), while **including** puts one in that nothing referenced at all
(`Unknown identifier`), and `@:keep` cannot help with the second. `Keep.types` is a plain array you
can add to.

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
somehow: `StringTools` under `-dce std`, and `Lambda`, `haxe.Json` and `haxe.Timer` in a bare program
under either setting. Every `Math` and `Std` static, and the `Array` and `String` instance methods,
survive either way, because the runtime itself references them.

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
