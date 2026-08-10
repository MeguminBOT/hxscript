# Embedding the library in your game

How to put hxscript into a Haxe project: running scripts, giving them access to your game,
letting them subclass your classes, compiling the hot ones at runtime, and the things that will
bite you.

[`example/`](../examples/battle) is a complete worked version of everything below: a small turn-based RPG
whose creatures, bosses and status effects are all loaded from scripts. Run it, then read
`examples/battle/game/Mods.hx`, which is the entire integration in one short file.

```
haxe -cp src -cp examples/battle -main Main \
  --macro include('bridges') --macro macros.BridgeMacro.generate() \
  --macro macros.AbstractsMacro.generate() --macro include('game') --interp
```

For what a script can and cannot do once it is running, see [`parity.md`](parity.md).

## 1. Install

```
haxelib install hxscript
```

or, to track the repository rather than a release:

```
haxelib git hxscript https://github.com/MeguminBOT/hxscript
```

Then add the library to your build (`-lib hxscript` in an hxml, or
`<haxelib name="hxscript" />` in a Project.xml). Nothing else is required: the table of compiled
types that scripts resolve names against builds itself the first time it is used, and if the build
also has a game library in it (lime, openfl, flixel, flixel-addons, flixel-ui or heaps) then that
library is wired for scripting by the same line. See
[advanced.md §4](advanced.md#4-adding-a-game-library) for what that means and how to add a library
that has no preset.

In a Lime or OpenFL project it is one line:

```xml
<haxelib name="hxscript" />
```

Your *own* classes still need saying, because nothing can guess which of them scripts are meant to
touch: `@:scriptAmbient` on a class means scripts may name it without importing it (section 4), and
`@:scriptable` means they may `extend` it (section 6). Point the setup at the packages holding them
with one define:

```xml
<haxedef name="hxscript_host" value="game" />
```

[`examples/battle/Project.xml`](../examples/battle/Project.xml) is a complete one, including shipping the scripts as
assets so they sit beside the executable.

## 2. Run a script

```haxe
var script = new Script("
	greeted = 0;
	function greet(who) { greeted++; return 'hello, ' + who; }
", "hello");

script.start();                          // runs the program top to bottom
script.call("greet", ["world"]);         // "hello, world"
```

`start()` returns the value of the program's last expression, so a one-line script is a usable
expression evaluator:

```haxe
new Script("1 + 2;", "v").start(); // 3
```

## 3. What a script shares with you

A script's `variables` map is its global scope, and the distinction that catches people is this:

```haxe
greeted = 0;      // a script variable: visible in script.variables
var notShared = 0; // a local of the program: NOT visible
```

Declared functions are script variables, which is why `call()` finds them.

**`start()` clears `variables` before it runs.** It calls `setDefaults()`, which wipes the map and
re-applies the global tables, so anything you set beforehand is gone. There are three places to put
your API, depending on how widely it should apply.

**One script world** (the usual choice). An `Environment`'s variables are copied in after the reset:

```haxe
var world = new Environment();
world.variables.set("damage", 21);

new Script("damage * 2", "w", world).start(); // 42
```

**Every script in the process**, via the global table, which `setDefaults()` re-applies:

```haxe
Config.globalVariables.set("VERSION", "1.4.0");
```

**A bare `Interp`** is the one case that needs a step. `Script`, `Module`, `ImportModule` and every
scripted type call `setDefaults()` for you, and the constructor deliberately does not, because all of them
called it again immediately afterwards, so seeding twice was most of what building an interpreter
cost. If you construct one yourself and run it directly, seed it first:

```haxe
var interp = new Interp();
interp.setDefaults();   // globals, the default import, `trace`
interp.execute(program);
```

**One script, after it has started**, then call in:

```haxe
var s = new Script("function hit() return damage * 2;", "expose");
s.start();
s.variables.set("damage", 21);
s.call("hit"); // 42
```

## 4. Exposing your types

Every type compiled into your program is reachable by an explicit `import` in a script, the way real
Haxe behaves. To make a name resolve bare, register it as a global import:

```haxe
import hxscript.syntax.Expr.ImportMode;

Config.globalImports.set("game.Entity", INormal);
```

```haxe
class Slime extends Entity { ... } // no import needed in the script
```

Two things to know, the second of which is sharp:

- **Imports resolve before variables.** A global import shadows a variable of the same name, so if
  you bind `File` to a sandboxed replacement, do not also global-import the real one.
- **A global import that cannot resolve throws out of the `Script` constructor, uncaught.** Global
  imports are applied on every interpreter reset, before your error handlers exist, so this is not
  routed anywhere: it escapes into your code as `Type not found: X`. It happens when the name is not
  compiled into this build, and equally when the name is blacklisted. Guard the registration:

```haxe
for (path in myTypes)
	if (TypeCollection.main.fromPath(path) != null)
		Config.globalImports.set(path, INormal);
```

A script's own `import` of a missing or blacklisted type is fine by comparison: it is reported
through `onProgramError` like any other script error.

### Marking things instead of listing them

Maintaining those registrations by hand gets old, and it gets worse if you ever compile scripts:
compiled code has no interpreter to be injected into, so the same names have to be declared a second
time in a second format. `Expose` collects both from the build.

```haxe
@:scriptAmbient
class Entity {
	@:scriptStatic('world')          // a script writing `world` gets this
	public static var current:World;

	@:scriptStatic                   // no name given, so the field's own is used
	public static var version:Int;
}
```

```haxe
hxscript.macro.Expose.apply();   // once, at startup
```

`@:scriptAmbient` marks a type scripts may name; `@:scriptStatic` marks a static they may reach by a
bare name. `apply()` fills `Config.globalVariables` for interpreted code and the compiler's lists for
compiled code, from the same marks, so a name means the same thing whichever way a script ends up
running. Marking one side only is the trap it exists to avoid: a script that works until the day it
is compiled, or the reverse.

For an API that is already grouped, a whole package can go in without touching its types, and
sub-packages come with it:

```
--macro hxscript.macro.Expose.expose(['game', 'engine.api'])
```

Neither mark changes what a script is *allowed* to touch. `Config` still decides that, for
interpreted and compiled code alike; this only says where the things it already allows actually
live. The lists are readable on their own if you want to add to them by hand:

```haxe
Compiler.ambient = Expose.ambient().concat(['extra.Type']);
Compiler.statics = Expose.statics();
```

## 5. Errors

Everything that goes wrong, whether parsing, building a type, running, or the runtime compiler, arrives
at one place, [`hxscript.error.Sink`](../src/hxscript/error/Sink.hx), as a
[`Diagnostic`](../src/hxscript/error/Diagnostic.hx) carrying the origin, line, column, the source
line it happened on, and what usually causes it. Until a host asks for them, they are printed:

```
Playground.hx:42: character 17
  var x = foo(;
              ^
Unexpected token ';'
```

`Sink.listen` takes them over, which is what a host with a window rather than a terminal wants:

```haxe
hxscript.error.Sink.listen(function(d) {
    myConsole.log(d.toString());     // or read d.origin, d.line, d.hint yourself
});
```

Listening also stops the default printing. `Sink.history` holds the last few for a backend with
nowhere to print at all, and `Diagnostic.phase` says which part of the pipeline produced it, which is
worth branching on: `PRun` is caused by what a script did, and `PEmit`, `PLoad` and `PSetup` are
caused by how the host was built.

**The hint is the part that saves the afternoon.** A message names the symptom, and the cause is
usually somewhere the message does not mention, so `Unknown identifier: FlxG` is a message about a
script and a problem in a build file. So the diagnostic distinguishes them:

- a name that is in the build but not in scope quotes the `import` to add;
- a name that is in no build at all says the package was never force-compiled;
- a misspelling suggests the spelling that exists;
- a call that resolved to nothing says whether the member is missing or `inline`, and names the
  `Config.callShims` key to register.

### The per-object hooks

The older routing still works, unchanged, and is the right thing when a host wants to handle one
script's errors differently from the rest:

```haxe
var s = new Script("null.explode();", "boom");
s.onProgramError = function(e) log(e.message);
s.start();   // returns null, sets s.failed
```

`e.message` is the message alone. For the **call stack** with it, across script boundaries and into
your own code, use `haxe.Exception.details()` or `hxscript.types.ScriptedClass.describeError(e)`,
which does that and passes a non-exception value through unchanged:

```haxe
s.onProgramError = function(e) log(ScriptedClass.describeError(e));
```

A scripted class's own hooks (`onExpressionError`, `onInstanceError`, `onStaticError`) render
through that same function, so an error in a field initializer or a method arrives with its frames
rather than as a bare value.

These hooks are empty by default rather than tracing, because everything reaching them has already
gone to the sink. Overriding one is purely additive; if you print from it as well, either use
`Sink.listen` instead or set `Sink.printing` to false.

One gap: a method declared in a `Module` runs on that module's interpreter, and each interpreter
owns its own stack with no link to its caller, so that frame does not appear in the calling
script's trace.

**Parse errors are different, and this is a sharp edge.** Parsing happens inside the constructor, so
a handler assigned afterwards is already too late. The program is left null:

```haxe
var bad = new Script("this is not haxe", "bad");
bad.program == null; // true. `failed` is still false: only start() sets that
```

To have the handler fire, construct empty and parse explicitly:

```haxe
var s = new Script("", "deferred");
s.onParsingError = function(e) log(e.message);
s.parse(source);
```

## 6. Letting scripts subclass your classes

This is the part worth understanding, because it is what turns "run some expressions" into
"mods extend the game".

Declare a bridge: an empty class extending the base you want scriptable, implementing
`hxscript.IScripted`.

```haxe
package bridges;

import game.Entity;

class ScriptedEntity extends Entity implements hxscript.IScripted {}
```

That is the whole declaration. The `@:autoBuild` on the interface generates an override of every
inherited method that dispatches to the script when it defines one and falls through to `super`
otherwise, and it registers `Entity` as extendable.

**The bridge must be compiled into your build.** Nothing in your code references it, so the compiler
never types it and the registration never happens. Force it in:

```
--macro include('bridges')
```

Without this you get `Class Entity can't be extended for scripting` at the moment a script tries to
extend it, which reads like a library limitation and is actually a missing build flag.

Scripts then write ordinary Haxe, and what comes back is a real instance of your class:

```haxe
class Bandit extends Entity {
	public function new() {
		super('bandit', 34, 8);
	}

	override public function takeTurn(battle:Battle) {
		var target = battle.pickFoe(this);
		battle.log('$name lunges at ${target.name}');
		target.damage(battle, attack, this);
	}
}
```

```haxe
var bandit:Entity = cast(world.resolve("Bandit"), ScriptedClass).typeCreateInstance([]);

bandit is Entity;         // true: hand it to any native code that takes an Entity
bandit.damage(battle, 5); // inherited methods work
bandit.takeTurn(battle);  // your own turn loop runs the script's override
```

A script can also call `super`, build more of its own class (the example's slime splits into two
slimes), and construct native classes the host never exposed to it by name.

Two constraints:

- **Cost is one generated override per inherited method** that is not `inline` or `final`. Bridging a
  class with a large method surface is not free in code size, so bridge the classes people actually
  subclass rather than everything.
- **`final` classes cannot be bridged**, which is a useful lever: keeping a hot-path class `final`
  both lets the compiler devirtualize it and keeps it off the scriptable list deliberately.

### Generating bridges instead of writing them

A bridge is boilerplate, so past a handful of bases it is better generated. An init macro can define
them from a list, and emit an array that references them, which replaces the `include` above: what
keeps a bridge in the build is something referring to it.

```haxe
for (base in BASES) {
	var parts = base.split('.');
	var superPath = {name: parts.pop(), pack: parts};

	Context.defineModule('bridges.Scripted' + superPath.name, [{
		pack: ['bridges'],
		name: 'Scripted' + superPath.name,
		pos: pos,
		meta: [{name: ':keep', pos: pos}],
		kind: TDClass(superPath, [{pack: ['hxscript'], name: 'IScripted'}], false, false, false),
		fields: []
	}]);
}
```

Give each bridge its own module: defined as a sub-type of a shared module, it could only ever be
named through that module. `examples/battle/macros/BridgeMacro.hx` is the whole thing, and the example runs
both forms side by side (`Entity` by hand, `Component` generated) so the difference is visible.

Adding a scriptable base then costs one line. Keep the list to what scripts actually subclass: the
cost is one generated override per inherited method, per base.

## 7. Scripted classes, modules, and worlds

A `Module` is one source file's worth of declarations. An `Environment` is the world they live in,
and what scripts resolve against.

```haxe
var world = new Environment();

for (file in FileSystem.readDirectory(dir))
	world.addModule(new Module(File.getContent('$dir/$file'), name, [], '$dir/$file'));

world.variables.set("roll", function(sides:Int) return 1 + Std.random(sides));
world.start();
```

Give the environment your API through `world.variables` (section 3) and every module and script in
it sees the same thing.

### Do not name scripts from the host

It is tempting to write `spawn("HiveQueen")` in your game code, and it undoes most of the benefit:
every new piece of content then needs a host change. Ask the world what it has instead.

```haxe
for (module in world.modules)
	for (name => type in module.types)
		if (type is ScriptedClass) { ... }
```

The example filters those by two things: whether the class descends from a native base
(`cls.instanceClass`, walked up with `Type.getSuperClass`), and a static the script declares about
itself (`cls.reflectGetField("side")`). That is enough for content to announce what it is, so
dropping a file into the scripts folder is the whole installation step. See `Mods.roster`.

## 8. What scripts can declare

Scripts are not limited to classes. A module can hold the same mix of types a Haxe module can, and
they behave the way you would expect:

```haxe
enum Element {
	Physical;
	Fire(intensity:Int);
}

typedef Loot = {
	var gold:Int;
	@:optional var charm:String;
}

interface Lootable {
	public function loot():Loot;
}

abstract Damage(Int) from Int to Int {
	public function new(v:Int) this = v;

	@:op(A + B) public function add(rhs:Damage):Damage return new Damage(this + rhs);
}
```

- **Enums** carry parameters, destructure in `switch`, and support guards.
- **Typedefs** are checked structurally, by field *and* by field type, and `?x:Int` fields may be
  absent. A value with extra fields still satisfies one.
- **Interfaces** work between scripted classes.
- **Abstracts** box their underlying value and carry their operators, `from`/`to` conversions and
  `@:forward`. They cost a wrapper at runtime, so they are worth it for meaning, not for speed.

Two things to know:

- **Types from another module need importing**, exactly as in Haxe. Everything shares one
  environment, but `import Combat;` is still what brings `Element` into scope, and an enum
  constructor from another module is written `Element.Fire(6)`.
- **A script cannot declare a field that its native base already has.** The error names it
  (`Field name should be declared with 'override' since it is inherited`), which is usually a
  collision with something ordinary like `name`.

`examples/battle/scripts/Combat.hx` declares all four in one module, and `Elementalist.hx` uses them
together.

## 9. Reloading

Rebuild the world: snapshot it, drop it, and construct a new `Environment` from freshly-read sources.

```haxe
env.snapshot(); // preserves statics marked @:snapshot across the reload
env = null;
```

Track file modification times to decide when to do it. A registry
integration is a worked example: a path-to-timestamp map, a `stale()` check, and a rebuild.

## 10. Locking scripts down

```haxe
Config.blacklist.get(ByType).push("sys.io.File"); // also ByModule and ByPackage
Config.strictAccess = true;                       // enforce script-declared `private`
```

Blacklisting is by name, so use fully-qualified ones. Prefer packaged names: blacklisting a
top-level type such as `Sys` also works, but the default root wildcard import tries to resolve it on
every interpreter reset and logs a warning each time. A blacklisted type must never also be a global
import: the import cannot resolve, and that failure escapes the `Script` constructor uncaught (see
section 4).

## 11. Typed mode

Type annotations are enforced at runtime by default: a wrong-typed assignment, argument or return
throws rather than silently proceeding. `Config.typedMode = false` (or `-D hxscript_dynamic`) turns
that off and leaves everything dynamic. Numeric correctness (`Int` staying `Int`) is unconditional.

A class or static field declared with a type is bound exactly as the identical local is, so an
abstract-typed field boxes and a later write to it is checked against the declared type.
See [`parity.md`](parity.md#1-typed-by-default-with-a-dynamic-escape-hatch).

## 12. Printing scripts back to source

`hxscript.syntax.Printer` turns a parsed AST back into source, for both expressions and
**module declarations** (classes, interfaces, enums, typedefs, abstracts, imports, `using`,
module-level fields). That makes it usable for a formatter, a migration tool that rewrites
scripts, or for showing a user what their script parsed as.

```haxe
import hxscript.syntax.Expr;   // for the EDecl constructor

var parser = new hxscript.syntax.Parser();
parser.allowTypes = parser.allowJSON = parser.allowMetadata = true;

var printer = new hxscript.syntax.Printer();
for (d in parser.parseModule(source, 'MyScript.hx', 0, ['my', 'pack']))
	trace(printer.exprToString({e: EDecl(d), pos: d.pos}));
```

The bar it is held to is **round-trip**, not readability: printing, reparsing and printing
again produces the same text. Output is not formatted to any house style, and comments are not
preserved, since the parser does not keep them.

## 13. Compiling scripts instead of interpreting them

Optional, and worth about 20x on a script's own work. A module can be translated to cppia bytecode
and loaded as a real class instead of being walked as a tree. [`modes.md`](modes.md) is the whole
picture, covering what it buys, what it costs, and how it differs from Haxe's own cppia; this section is
just the wiring.

Decide per module. Both paths produce the same class, so nothing downstream needs to know which one
it got, and a module the compiler refuses can simply be interpreted.

**Nothing here happens on its own.** There is no setting that turns compiling on, and no point at
which the library decides to compile something for you: adding the defines below makes the compiler
*available*, and that is all. If you never ask, every script is interpreted exactly as before.

That is deliberate. What to compile, when to compile it, and what to do about a module the compiler
will not take are decisions only the host can make, whether at startup, on demand, per mod folder, or from
a flag in a pack's manifest.

Asking is one call:

```haxe
var report = hxscript.compile.Compiler.compile(env);
```

That compiles what it can of a world and makes the result the thing that runs. The rest of this
section is what that call does, in case you want to do it yourself.

### What your build needs

```
-D scriptable       # hxcpp: makes your own types reachable from bytecode
-D hxscript_cppia   # this library: compiles the emitter in at all
-dce no             # see section 14
```

All three, and all three are about the host rather than any script. Without `-D hxscript_cppia`
`Cppia.compile` reports every module skipped, which looks exactly like a compiler that refuses
everything, so check it at startup rather than wondering:

```haxe
if (!hxscript.compile.Cppia.available)
    trace('built without -D hxscript_cppia; everything will be interpreted');
```

### The whole of it, in one call

```haxe
import hxscript.compile.Compiler;
import hxscript.macro.Expose;

// once, at startup: tells both the interpreter and the compiler where your API lives
Expose.apply();

// once per world, whenever you want it compiled
var report = Compiler.compile(env);

trace('${report.compiled.length} classes compiled in ${report.ms}ms');
for (skip in report.skipped)
    trace('interpreting ${skip.name}: ${skip.reason}');
```

`Compiler.compile` offers every module in the world, loads what compiled, registers the classes
against the world, and turns substitution on. A module it cannot take is reported and left to the
interpreter, so the call is safe on any world and safe to repeat. Calling it again after a reload
binds the classes it built last time rather than compiling them a second time.

`Expose.apply()` is the other half, and section [4](#4-exposing-your-types) is where the
annotations live. In short: mark a type `@:scriptAmbient` and a static `@:scriptStatic`, and the
macro fills in `Config.globalVariables` for interpreted code and the compiler's lists for compiled
code, from the same marks. Doing only one of those gives you a script that works until the day it is
compiled, or the reverse.

That is the whole integration. Everything below is the same work spelled out, for a host that wants
to compile a subset, cache the bytes, or decide something the facade decides for it.

### Doing it yourself: the smallest version that works

```haxe
import hxscript.compile.Cppia;
import hxscript.syntax.Parser;

var decls = new Parser().parseModule(source, 'Goblin', 0, ['mods']);
var result = Cppia.compile([{name: 'mods.Goblin', decls: decls}]);

if (result.bytes != null) {
    var module = cpp.cppia.Module.fromData(result.bytes.getData());
    module.boot();

    var cls = module.resolveClass('mods.Goblin');
    var goblin = Type.createInstance(cls, []);
}

for (skip in result.skipped)
    trace('interpreting ${skip.name}: ${skip.reason}');
```

`bytes` is null when nothing in the batch compiled. `skipped` always says why, per module, in words
meant to be read.

### Handing over what you inject

This is the part that catches people, and it follows from what compiled code is. Anything you give
scripts through `Config`, meaning preset variables and preset imports, is injected into an *interpreter*.
Compiled code does not have one. A bare name that resolved fine interpreted will refuse to compile
unless you say where it really lives:

```haxe
Cppia.compile(inputs,
    ['game.Player', 'game.World'],              // ambient: types usable without an import
    ['mods.Shared'],                            // external: scripted classes NOT in this batch
    ['player=game.Player::current',             // statics: bare name -> a real host static
     'world=game.World::active']);
```

- **`ambient`** are types a script may name without importing them.
- **`statics`** are bare names your host answers with a static of its own, written
  `name=owner.path::field`. This is the direct replacement for a preset variable.
- **`external`** are scripted classes that live in another module or another world. A module naming
  one is left interpreted on purpose: cppia resolves a class either inside the module being loaded
  or as a host class, and a scripted class elsewhere is neither, so the reference would fail to link
  and take the whole load down with it.

### Telling the world what you compiled

`Compiler.compile` does this for you; this is what it does.

Resolving the class yourself is not enough. Everything else, from other scripts naming that class to
`new` on it from interpreted code to a static read through it, still goes through the world, and the world
knows nothing about what you just built. Register it:

```haxe
for (input in inputs) {
    if (result.compiled.indexOf(input.name) < 0)
        continue;   // this one was skipped; it stays interpreted

    for (path in Cppia.declaredPaths(input.decls)) {
        var cls = module.resolveClass(path);
        if (cls != null)
            env.compiled.set(path, cls);
    }
}

// on whenever ANY class in this world is compiled, not only when all of them are
env.substituting = true;
```

`result.compiled` holds the *module* names you passed in, not class paths, and one module can declare
several classes, which is what `declaredPaths` is for.

Skip this and everything runs interpreted while your own logging cheerfully reports it as compiled,
because nothing errors: `Cppia.compile` succeeded, the module loaded, and the class you resolved is
real. It is simply not the one anything else reaches. Worth a hard check the first time you wire it
up, on the actual class an instance came from, rather than trusting that the compile step ran.

`substituting` is the flag that makes it safe. A compiled class carries its own statics and its own
identity, so the hazard is a class existing both ways at once with the two halves disagreeing about
its state. What prevents that is not compiling everything. It is every reference going the same
way. With the flag on, a scripted class that has a compiled form is reached through the compiled
form from everywhere, including from code that is still interpreted, so there is only ever one of
it. Which is why it goes on as soon as one class is compiled, not once they all are.

### Compiling several modules together

Pass them in one call. Every module is declared before any is emitted, so they may refer to each
other in any order and mutual references are fine:

```haxe
var result = Cppia.compile([
    {name: 'mods.Goblin', decls: goblinDecls},
    {name: 'mods.Boss', decls: bossDecls},
    {name: 'mods.Loot', decls: lootDecls}
]);
```

One thing to expect: skips cascade. If `Loot` is refused and `Boss` names it, `Boss` is skipped too,
reported as `uses mods.Loot, which is interpreted`. That is not a defect, since a reference that cannot
link rejects the whole loaded module, but it does mean a batch is only as compilable as the
modules it depends on, so group what belongs together rather than throwing everything in at once.

### Turning on the JIT

Once, at startup, before any module loads. It is a process-wide switch in hxcpp, not a per-module
one, and it costs nothing measurable at load time:

```haxe
cpp.cppia.Host.enableJit(true);
```

### Caching the bytes

One reason to drive `Cppia.compile` yourself rather than through the facade: `Compiler` holds the
compiled classes in memory for the life of the process, which is what makes a reload free, but it
does not write anything to disk.

`result.bytes` is ordinary `haxe.io.Bytes`. You can write it out and load it next launch without
parsing or compiling anything:

```haxe
sys.io.File.saveBytes('cache/Goblin.cppia', result.bytes);

// next launch
var module = cpp.cppia.Module.fromData(sys.io.File.getBytes('cache/Goblin.cppia').getData());
module.boot();
```

Tested both ways it matters: bytes written by one process load in another, and bytes written by one
build of the host load in a **rebuilt** host. That second one is the useful property, and it holds
because names are resolved when the module loads rather than baked in when it was compiled, so there
is no snapshot of your classes inside the file to go stale.

The thing to know is what that defers rather than removes. If a later build of your host drops or
renames something a cached module used, the failure appears when those bytes load, not when they
were compiled. Key the cache on the source's own hash so an edited script is recompiled, and treat a
load failure as "recompile from source", which is a cheap and always-correct fallback.

### When not to bother

Compiling a module costs a few milliseconds against a saving paid per operation, so a module of
short handlers called a handful of times each will never repay it. [`modes.md`](modes.md) has the
break-even and the figures behind it.

## 14. Things that will bite you

- **Dead code elimination.** With `-dce std`, methods your own code never calls statically are
  stripped from the build, and a script reaching one by reflection gets `Cannot call null`. It looks
  like a library bug and is not. `-dce no`, or `@:keep` on what scripts need. Measured below, because
  it removes more than people expect.

  The library covers the worst of it for you. `extraParams.hxml` runs
  [`Keep`](../src/hxscript/macro/Keep.hx), which pulls `IntIterator`, `Reflect`, `Type`,
  `haxe.ds.StringMap`, `EReg`, `haxe.ds.List`, `Date` and `Sys` into the build and marks them and
  their fields kept, so those work under `-dce std` without you doing anything. It handles the two
  failures separately, because they are different: keeping saves a type already in the build from
  being stripped (`Cannot call null`), while including puts one in that nothing referenced at all
  (`Unknown identifier`), and `@:keep` cannot help with the second. `Keep.types` is a plain
  array you can add to; `-D hxscript_no_keep` turns the whole thing off for a host minimising binary
  size. Everything else in the catalogue below is still yours to keep.
- **`inline` is not the reason a member is missing.** An `inline` method still has a runtime form;
  what removes it is DCE noticing that every call site inlined it, so nothing references it. The two
  get confused constantly, and the fix is different: `-dce no`/`@:keep` for this, a `callShim` for a
  genuine `inline extern`.
- **`inline extern` methods have no runtime form.** Reflection finds nothing, so the call fails.
  Register a real closure that performs the call in `Config.callShims`, keyed
  `<fully.qualified.Owner>.<method>`; the interpreter walks the receiver's superclasses looking for
  one before giving up. Flixel 6.2 turning `FlxG.sound.playMusic` into this form is the case that
  motivated it.
- **Native abstracts need a build macro** to have any runtime form:
  `@:build(hxscript.macro.Abstract.build())`. Without it, scripts see nothing usable. Abstracts
  declared *in scripts* need no setup. An abstract-typed **field** boxes the same way a local does,
  so `public var dist:Meters = 5.0` on a scripted class reaches the abstract's methods and
  operators.
- **Build macros hold type paths as strings**, which the compiler cannot check for you. If you rename
  a bridged base or move a package, nothing fails at compile time; it fails when a script asks.

### What `-dce std` actually removes

Probed over 83 commonly-scripted standard-library members on hxcpp, asking only whether
`Reflect.field` finds them, which is how an interpreter reaches them:

| build | reachable | unreachable |
| --- | --- | --- |
| `-dce std` (hxcpp's default) | 41 | **42** |
| `-dce no` | 92 | 3 |

**This list is for a bare program.** A member survives when something in the build references it
statically, so a large host keeps far more of it alive by accident, and your own numbers will differ.
Take the shape of the result, not the exact set.

Two causes, and they need different fixes.

**Members stripped from a class that is otherwise in the build.** `-dce no`, or `@:keep` on what
scripts need:

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

`IntIterator` is the one worth knowing by name: it is why `for (i in 0...n)` fails on hxcpp in
several hscript-family libraries, and it is a property of how the host was built rather than of the
library. See [`benchmarks.md`](benchmarks.md).

**Whole classes that were never compiled in**, because nothing in the host referenced them.
`-dce no` does not help, because the type has to be reached somehow, by a real reference or by forcing it
into the build:

- `StringTools` (unresolvable entirely under `-dce std`)
- `Lambda`, `haxe.Json`, `haxe.Timer` (unresolvable in a bare program under either setting)

**Survived untouched** in the same probe: every `Math` and `Std` static, and the `Array` and `String`
instance methods. The runtime itself references those, so they are never candidates.

## Where to go next

- [`advanced.md`](advanced.md) is the next step up: generating bridges with a macro, making native
  abstracts visible to scripts, subclassing the interpreter, and every surface for binding your
  API.
- [`modes.md`](modes.md) covers interpreting versus compiling at runtime: what compiling buys, what
  it costs, and how it differs from Haxe's own cppia.
- [`parity.md`](parity.md) covers what scripts can do compared to real Haxe, and the deliberate
  divergences.
- [`performance.md`](performance.md) covers what is fast, what is not, and how to measure a change
  without fooling yourself.
- [`../examples/battle/`](../examples/battle) is the worked version of this guide, and is runnable.
- [`../examples/workbench/`](../examples/workbench) is the other use of the library: a coding
  environment where the program itself is written in script, with list/test/run/watch over it.
- [`../apps/sandbox/`](../apps/sandbox) is an application rather than an example: a prototyping tool
  for lime, openfl and flixel, whose projects are folders of `.hx` files read at runtime. Its
  headless check reports what a script can actually reach, which is the practical form of the
  dead-code elimination table above.
- [`checker.md`](checker.md) is the design for a pre-run static checker, and the reasons it is not
  built.
- [`../test/`](../test) holds the suites, which double as executable documentation of behaviour.
