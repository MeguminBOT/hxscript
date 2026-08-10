# Embedding hxScript

Putting the library into a Haxe project: running scripts, giving them your API, letting them subclass
your classes, and compiling the hot ones at runtime.

Read [`parity.md`](parity.md) for what a script can and cannot do once it is running, and
[`../examples/battle/`](../examples/battle) for all of this as a runnable program. That example's
whole integration is one short file, [`game/Mods.hx`](../examples/battle/game/Mods.hx).

## Quick start

Add the library to your build:

```
-lib hxscript
```

Then run something:

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

That is a working embed. Everything below is about widening what a script can reach.

## What each step costs you

Each row is independent. Take the ones you need.

| You want | You write | Cost |
| --- | --- | --- |
| Run scripts | nothing beyond `-lib hxscript` | none |
| Scripts reach a game library | nothing, if it is lime, openfl, flixel, flixel-addons, flixel-ui or heaps | none |
| Scripts reach *your* API | `@:scriptAmbient` / `@:scriptStatic`, then `Expose.apply()` | none |
| Scripts `extend` your classes | a bridge per base, kept in the build | one generated override per inherited method, per base |
| Scripts run 20x faster | three build flags and one call | a few ms per module, once |

## 1. Install

```
haxelib install hxscript
```

Or track the repository rather than a release:

```
haxelib git hxscript https://github.com/MeguminBOT/hxscript
```

Then add it to your build, as `-lib hxscript` in an hxml or `<haxelib name="hxscript" />` in a
`Project.xml`. That is the whole of the setup, **including for the game library you already use**.
If the build contains lime, openfl, flixel, flixel-addons, flixel-ui or heaps, the same line wires it
for scripting: the packages are force-compiled so scripts can name the types, a bridge is generated
per class scripts may extend, the abstracts are given a runtime form, and the members with no runtime
form get emulations. [`advanced.md`](advanced.md#4-adding-a-game-library) covers adding a library that
has no preset.

Your own classes still need pointing at, because nothing can guess which of them scripts should
touch:

```xml
<haxedef name="hxscript_host" value="game" />
```

`-D hxscript_verbose` prints what the setup did. It is worth reading once.

## 2. Give scripts your API

There are two separate questions here, and they have different answers: which **values** a script can
see, and which **types** it can name.

### Values

A script's `variables` map is its global scope:

```haxe
greeted = 0;        // a script variable, visible in script.variables
var notShared = 0;  // a local of the program, not visible
```

Declared functions are script variables, which is why `call()` finds them.

**`start()` clears `variables` before it runs.** It calls `setDefaults()`, which wipes the map and
re-applies the global tables, so anything you set beforehand is gone. Put your values in one of these
instead:

| Scope | Where | When to use it |
| --- | --- | --- |
| One world | `world.variables.set(...)` on an `Environment` | the usual choice |
| Every script in the process | `Config.globalVariables.set(...)` | constants, version numbers |
| One script, after `start()` | `script.variables.set(...)` | a value that script alone needs |

```haxe
var world = new Environment();
world.variables.set("damage", 21);

new Script("damage * 2", "w", world).start(); // 42
```

A bare `Interp` is the one case that needs a step. `Script`, `Module`, `ImportModule` and every
scripted type call `setDefaults()` for you; the constructor deliberately does not, because all of
them called it again immediately afterwards. If you build one yourself, seed it:

```haxe
var interp = new Interp();
interp.setDefaults();   // globals, the default import, `trace`
interp.execute(program);
```

### Types

Every type compiled into your program is reachable by an explicit `import` in a script, exactly as in
Haxe. To make a name resolve without one, register a global import:

```haxe
import hxscript.syntax.Expr.ImportMode;

Config.globalImports.set("game.Entity", INormal);
```

> **Two sharp edges.**
> Imports resolve *before* variables, so a global import shadows a variable of the same name. If you
> bind `File` to a sandboxed replacement, do not also global-import the real one.
>
> A global import that cannot resolve **throws out of the `Script` constructor, uncaught**. Global
> imports are applied on every interpreter reset, before your error handlers exist, so it escapes into
> your code as `Type not found: X`. It happens when the name is not in this build, and equally when
> the name is blacklisted. Guard the registration:
>
> ```haxe
> for (path in myTypes)
>     if (TypeCollection.main.fromPath(path) != null)
>         Config.globalImports.set(path, INormal);
> ```
>
> A script's own `import` of a missing type is fine by comparison, and is reported through
> `onProgramError` like any other script error.

### Marking instead of listing

Maintaining those registrations by hand gets old, and it gets worse if you ever compile scripts:
compiled code has no interpreter to inject into, so the same names have to be declared a second time
in a second format. `Expose` collects both from the build.

```haxe
@:scriptAmbient
class Entity {
    @:scriptStatic('world')   // a script writing `world` gets this
    public static var current:World;

    @:scriptStatic            // no name given, so the field's own is used
    public static var version:Int;
}
```

```haxe
hxscript.macro.Expose.apply();   // once, at startup
```

`apply()` fills `Config.globalVariables` for interpreted code and the compiler's lists for compiled
code from the same marks, so a name means the same thing whichever way a script runs. **Filling one
side only is the trap this exists to avoid**: a script that works until the day it is compiled, or
the reverse.

A whole package can go in without touching its types, sub-packages included:

```
--macro hxscript.macro.Expose.expose(['game', 'engine.api'])
```

Neither mark changes what a script is *allowed* to touch. `Config` still decides that. This only says
where the things it already allows actually live.

## 3. Let scripts subclass your classes

This is what turns "run some expressions" into "mods extend the game".

**Step 1.** Declare a bridge: an empty class extending your base, implementing `hxscript.IScripted`.

```haxe
package bridges;

import game.Entity;

class ScriptedEntity extends Entity implements hxscript.IScripted {}
```

That is the whole declaration. The `@:autoBuild` on the interface generates an override of every
inherited method that dispatches to the script when it defines one and falls through to `super`
otherwise, and registers `Entity` as extendable.

**Step 2.** Force the bridge into the build. Nothing in your code references it, so the compiler
never types it and the registration never happens:

```
--macro include('bridges')
```

> Without this you get `Class Entity can't be extended for scripting` the moment a script tries,
> which reads like a library limitation and is a missing build flag.

Scripts then write ordinary Haxe, and what comes back is a real instance of your class:

```haxe
class Bandit extends Entity {
    public function new() super('bandit', 34, 8);

    override public function takeTurn(battle:Battle) {
        var target = battle.pickFoe(this);
        target.damage(battle, attack, this);
    }
}
```

```haxe
var bandit:Entity = cast(world.resolve("Bandit"), ScriptedClass).typeCreateInstance([]);

bandit is Entity;         // true: hand it to any native code taking an Entity
bandit.damage(battle, 5); // inherited methods work
bandit.takeTurn(battle);  // your own turn loop runs the script's override
```

A script can also call `super`, subclass its own scripted classes, and construct native classes the
host never exposed by name.

Two constraints:

- **One generated override per inherited method** that is not `inline` or `final`. Bridging a class
  with a large method surface is not free in code size, so bridge what people actually subclass.
- **`final` classes cannot be bridged.** That is a useful lever rather than only a limit: keeping a
  hot-path class `final` lets the compiler devirtualise it and keeps it off the scriptable list on
  purpose.

Past a handful of bases, generate the bridges instead of writing them.
[`advanced.md`](advanced.md#1-generating-bridges) has the macro.

## 4. Load a folder of scripts

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

The example filters those by whether the class descends from a native base and by a static the script
declares about itself, which is enough for content to announce what it is. Dropping a file into the
folder becomes the whole installation step. See `Mods.roster`.

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
Abstracts carry their operators, `from`/`to` and `@:forward`, at the cost of a wrapper at runtime, so
they are worth it for meaning rather than for speed.

Two things to know:

- **Types from another module need importing**, exactly as in Haxe. One environment is still not one
  scope: `import Combat;` is what brings `Element` in, and a constructor from another module is
  written `Element.Fire(6)`.
- **A script cannot redeclare a field its native base already has.** The error names it, and it is
  usually a collision with something ordinary like `name`.

## 5. Handle errors

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
gone to the sink. If you print from one as well, either use `Sink.listen` instead or set
`Sink.printing` to false.

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

## 6. Reload

Snapshot the world, drop it, and build a new one from freshly read sources:

```haxe
env.snapshot();   // preserves statics marked @:snapshot across the reload
env = null;
```

Track file modification times to decide when. A path-to-timestamp map and a `stale()` check is the
whole of it.

## 7. Lock scripts down

```haxe
Config.blacklist.get(ByType).push("sys.io.File");   // also ByModule and ByPackage
Config.strictAccess = true;                          // enforce script-declared `private`
```

Blacklisting is by name, so use fully-qualified ones. Prefer packaged names: blacklisting a top-level
type such as `Sys` works, but the default root wildcard import tries to resolve it on every
interpreter reset and logs a warning each time. **A blacklisted type must never also be a global
import**, since the import cannot resolve and that failure escapes the constructor uncaught.

## 8. Typed mode

Type annotations are enforced at runtime by default: a wrong-typed assignment, argument or return
throws rather than silently proceeding. `Config.typedMode = false`, or `-D hxscript_dynamic`, turns
that off. Numeric correctness, meaning `Int` staying `Int`, is unconditional either way.

A class or static field declared with a type is bound exactly as the identical local is, so an
abstract-typed field boxes and a later write is checked against the declared type. See
[`parity.md`](parity.md#1-typed-by-default-with-a-dynamic-escape-hatch).

## 9. Compile scripts at runtime

Optional, and worth about 20x on a script's own work. A module can be translated to cppia bytecode and
loaded as a real class instead of being walked as a tree. [`modes.md`](modes.md) is the whole picture;
this section is the wiring.

**Nothing here happens on its own.** There is no setting that turns compiling on. The defines below
make the compiler *available*, and that is all. If you never ask, every script is interpreted exactly
as before. What to compile, when, and what to do about a module the compiler will not take are
decisions only the host can make.

**Build flags.** All three, and all three are about the host rather than any script:

```
-D scriptable       # hxcpp: makes your own types reachable from bytecode
-D hxscript_cppia   # this library: compiles the emitter in at all
-dce no             # see Troubleshooting
```

Without `-D hxscript_cppia` every module is reported skipped, which looks exactly like a compiler that
refuses everything. Check it at startup rather than wondering:

```haxe
if (!hxscript.compile.Cppia.available)
    trace('built without -D hxscript_cppia; everything will be interpreted');
```

**The whole integration**, in two calls:

```haxe
import hxscript.compile.Compiler;
import hxscript.macro.Expose;

Expose.apply();                         // once at startup: see section 2
var report = Compiler.compile(env);     // once per world, whenever you want it compiled

trace('${report.compiled.length} classes compiled in ${report.ms}ms');
for (skip in report.skipped)
    trace('interpreting ${skip.name}: ${skip.reason}');
```

`Compiler.compile` offers every module in the world, loads what compiled, registers the classes
against the world and turns substitution on. A module it cannot take is reported and left to the
interpreter, so the call is safe on any world and safe to repeat. Calling it again after a reload
binds what it built last time rather than compiling twice.

Both paths produce the same class, so nothing downstream needs to know which one it got.

Everything below is the same work spelled out, for a host that wants to compile a subset, cache the
bytes, or decide something the facade decides for it.

### Driving it yourself

```haxe
var decls = new Parser().parseModule(source, 'Goblin', 0, ['mods']);
var result = hxscript.compile.Cppia.compile([{name: 'mods.Goblin', decls: decls}]);

if (result.bytes != null) {
    var module = cpp.cppia.Module.fromData(result.bytes.getData());
    module.boot();
    var goblin = Type.createInstance(module.resolveClass('mods.Goblin'), []);
}
```

`bytes` is null when nothing in the batch compiled. `skipped` always says why, per module, in words
meant to be read.

**Hand over what you inject.** Anything you give scripts through `Config` goes into an *interpreter*,
and compiled code does not have one, so a bare name that resolved fine interpreted will refuse to
compile unless you say where it lives:

```haxe
Cppia.compile(inputs,
    ['game.Player', 'game.World'],       // ambient: types usable without an import
    ['mods.Shared'],                     // external: scripted classes NOT in this batch
    ['player=game.Player::current',      // statics: bare name -> a real host static
     'world=game.World::active']);
```

`external` names scripted classes in another module or world. A module naming one is left interpreted
on purpose: cppia resolves a class either inside the module being loaded or as a host class, and a
scripted class elsewhere is neither, so the reference would fail to link and take the whole load down.

**Tell the world what you compiled.** `Compiler.compile` does this for you, and skipping it is the
one mistake here that reports success:

```haxe
for (input in inputs) {
    if (result.compiled.indexOf(input.name) < 0)
        continue;   // skipped; it stays interpreted

    for (path in Cppia.declaredPaths(input.decls)) {
        var cls = module.resolveClass(path);
        if (cls != null)
            env.compiled.set(path, cls);
    }
}

env.substituting = true;   // as soon as ANY class compiled, not once all of them have
```

> Resolving the class yourself is not enough. Every other route to it, whether another script naming
> it, `new` from interpreted code or a static read through it, goes through the world, and the world
> knows nothing about what you just built. Skip the registration and everything runs interpreted while
> your logging reports it as compiled, because nothing errors: the compile succeeded, the module
> loaded, and the class you resolved is real. It is simply not the one anything else reaches. Check it
> the first time on the actual class an instance came from.

`substituting` is what makes it safe. A compiled class carries its own statics and its own identity,
so the hazard is a class existing both ways at once with the two halves disagreeing about its state.
What prevents that is not compiling everything, it is every reference going the same way, which is
why the flag goes on as soon as one class is compiled.

`result.compiled` holds the *module* names you passed in rather than class paths, and one module can
declare several classes, which is what `declaredPaths` is for.

### Several modules at once

Pass them in one call. Every module is declared before any is emitted, so they may refer to each other
in any order:

```haxe
var result = Cppia.compile([
    {name: 'mods.Goblin', decls: goblinDecls},
    {name: 'mods.Boss', decls: bossDecls}
]);
```

**Skips cascade.** If `Loot` is refused and `Boss` names it, `Boss` is skipped too, reported as
`uses mods.Loot, which is interpreted`. A reference that cannot link rejects the whole loaded module,
so a batch is only as compilable as what it depends on. Group what belongs together rather than
throwing everything in at once.

### The JIT

Once at startup, before any module loads. It is a process-wide switch in hxcpp rather than a
per-module one, and costs nothing measurable at load time:

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
**rebuilt** host. That second property holds because names are resolved when the module loads rather
than baked in when it was compiled.

What that defers rather than removes: if a later build drops or renames something a cached module
used, the failure appears when those bytes load. Key the cache on the source's own hash, and treat a
load failure as "recompile from source", which is cheap and always correct.

### When not to bother

Compiling costs a few milliseconds against a saving paid per operation, so a module of short handlers
called a handful of times each will never repay it. [`modes.md`](modes.md) has the break-even.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `Type not found: X` thrown out of `new Script(...)`, uncaught | a global import that cannot resolve | guard the registration; check the type is in the build and not blacklisted |
| `Unknown identifier: X` | the type was never compiled in | force the package in, or add it to a `Library` record |
| `Class X can't be extended for scripting` | the bridge is not in the build | `--macro include('bridges')`, or reference it from real code |
| `Cannot call null` | dead code elimination removed the member | `-dce no`, or `@:keep` on what scripts need |
| `Cannot call null` on an `inline extern` | it has no runtime form at all | register a closure in `Config.callShims` |
| A native abstract's members do nothing | no runtime form | `@:build(hxscript.macro.Abstract.build())` on it |
| Parse handler never fires | parsing happens in the constructor | construct empty, then `parse()` |
| Compiles "successfully", still interpreted | the classes were never registered against the world | `env.compiled.set(...)` and `env.substituting = true` |
| Every module reports skipped | built without the define | `-D hxscript_cppia` |
| A field errors as already inherited | the script redeclares a base field | rename it, or `override` |

### Things that bite people

- **`inline` is not the reason a member is missing.** An `inline` method still has a runtime form.
  What removes it is DCE noticing every call site inlined it, so nothing references it. The two get
  confused constantly and the fixes differ: `-dce no` or `@:keep` for this, a `callShim` for a genuine
  `inline extern`.
- **Build macros hold type paths as strings**, which the compiler cannot check. Rename a bridged base
  or move a package and nothing fails at compile time. It fails when a script asks.
- **Abstracts declared in scripts need no setup.** Only native ones need the build macro.

### What `-dce std` actually removes

Probed over 83 commonly-scripted standard-library members on hxcpp, asking only whether
`Reflect.field` finds them, which is how an interpreter reaches them:

| build | reachable | unreachable |
| --- | --- | --- |
| `-dce std` (hxcpp's default) | 41 | **42** |
| `-dce no` | 92 | 3 |

**This is a bare program.** A member survives when something in the build references it statically, so
a large host keeps far more alive by accident. Take the shape of the result, not the exact set.

The library covers the worst of it. `extraParams.hxml` runs
[`Keep`](../src/hxscript/macro/Keep.hx), which pulls `IntIterator`, `Reflect`, `Type`,
`haxe.ds.StringMap`, `EReg`, `haxe.ds.List`, `Date` and `Sys` into the build and marks them and their
fields kept, so those work under `-dce std` with nothing from you. It handles two failures separately
because they are different: **keeping** saves a type already in the build from being stripped
(`Cannot call null`), while **including** puts one in that nothing referenced at all
(`Unknown identifier`), and `@:keep` cannot help with the second. `Keep.types` is a plain array you
can add to, and `-D hxscript_no_keep` turns it off.

Members stripped from a class that is otherwise present, fixed by `-dce no` or `@:keep`:

| type | members reflection could not reach |
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

Whole classes never compiled in, where `-dce no` does not help because the type has to be reached
somehow: `StringTools` under `-dce std`, and `Lambda`, `haxe.Json` and `haxe.Timer` in a bare program
under either setting.

Survived untouched in the same probe: every `Math` and `Std` static, and the `Array` and `String`
instance methods. The runtime itself references those, so they are never candidates.

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
- [`modes.md`](modes.md) covers interpreting versus compiling: what compiling buys, what it costs, and
  how it differs from Haxe's own cppia.
- [`parity.md`](parity.md) covers what scripts can do compared to real Haxe.
- [`performance.md`](performance.md) covers what is fast, what is not, and how to measure without
  fooling yourself.
- [`../examples/battle/`](../examples/battle) is this guide as a runnable program.
- [`../examples/workbench/`](../examples/workbench) is the other use of the library, where the program
  itself is written in script.
- [`../apps/sandbox/`](../apps/sandbox) is an application rather than an example. Its headless check
  reports what a script can actually reach, which is the practical form of the table above.
