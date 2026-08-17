# hxScript internals

Design rationale lifted out of the source, so the docstrings there stay to a summary plus
`@param`/`@return`. Each heading names the file and the symbol the note belongs to.

**`src/hxscript/hl/` is not covered here.** The HashLink backend is the larger of the two and its
rationale is written as a narrative instead, in
[how-it-works.md, part three](how-it-works.md#part-three-compiling-to-hashlink), because almost
every decision in it follows from two facts about the target rather than standing on its own.

## src/hxscript/openfl/SoundTools.hx

### class SoundTools

The companion to [`TriangleTools`](../src/hxscript/flixel/TriangleTools.hx), for the same two reasons
and in the same shape. A script
that synthesises audio has no way to hand it over: `lime.utils.UInt8Array` is an abstract whose
only constructor is inline and generic, and `AudioBuffer.data` wants one. Inline members of an
abstract have no runtime symbol for the interpreter to call and nothing for the runtime compiler
to link against, so the crossing is not slow, it is closed.

Even if it were open it would be the wrong shape. A minute of stereo audio is five million
samples, and moving them one interpreted call at a time costs far more than generating them did.

Samples are interleaved signed 16-bit, left then right, which is what a software synth naturally
produces and what the audio system wants.

`@:keep` because nothing in a host calls this. Only scripts do, and dead code elimination cannot
see that.

## src/hxscript/flixel/TriangleTools.hx

### class TriangleTools

A script that builds its own geometry has no cheap way to hand it over. `openfl.Vector` is an
abstract, so there is no runtime class for the interpreter to construct; assigning by index does
not reach the abstract's accessor either. That leaves `push`, one interpreted call per float, and
a frame of custom geometry is tens of thousands of floats. The crossing ends up costing more than
building the geometry did.

These do the identical work in compiled code, one call per buffer rather than one per element.
Nothing here is specific to any one program: it is the missing bulk path for any script driving
an `FlxStrip`.

`@:keep` because nothing in a host calls this. Only scripts do, and dead code elimination cannot
see that.

## src/hxscript/compile/Compiler.hx

### class Compiler

A backend turns declarations into bytecode and stops there, which leaves an embedder holding
several steps that all have to be right: load the module, resolve every class it declared, record
each against the world it came from, and turn substitution on. Miss the recording and nothing
errors: the compile succeeded, the module loaded, the class is real, and every script still runs
interpreted while the host reports otherwise. This does those steps.

It is also what makes there be one of these rather than one per target. `hxscript.cppia.Backend` and
`hxscript.hl.Backend` are reached through the same `Backend` name, chosen by which define the build
carries, so the shape of compiling a world is written once and what differs per target is one call in
the middle. A host writes `Compiler` and never learns which target it is on.

One call per world:

```haxe
Compiler.ambient = ['game.Player', 'game.World'];
Compiler.statics = ['player=game.Player::current'];

var report = Compiler.compile(env);
trace('${report.compiled.length} compiled, ${report.skipped.length} interpreted');
```

Safe to call on a world with nothing left to do, and safe to call again after a reload: classes
compiled for an earlier world are handed to the new one rather than compiled a second time, which
they could not be anyway, because offered again in a batch of their own they can no longer see the
classes they were compiled beside, so they would be refused and reported as interpreted while
their compiled form sat right there.

**A module the loader rejects does not take the host with it.** The bytecode loader can refuse a
module the emitter was perfectly happy with, reporting `Bad move target`, `Bad link` or `Bad Set expr`,
and it does so for the module as a whole, naming nothing inside it. That is caught by the backend, the
batch is narrowed to find what can still be compiled, and whatever cannot is reported and left
interpreted. See `batch` below for how, and why it is a split rather than a search.

Nothing here happens on its own. The library never decides to compile something; a host calls
this when it wants it, on the worlds it wants it for.

## src/hxscript/cppia/Backend.hx

### static function batch(group:Array<Module>, env:Environment, report:Report, whole:Bool):Void

The split is a growing of what works rather than a search for what does not, and the difference
matters for a reason that is not obvious: booting a module registers its classes with the
runtime, so a subset that loads is live from that moment. A search that shrank a failing set
would boot subsets it then meant to discard, and the classes of every successful trial would
still be there when the real batch arrived, which is the class-existing-twice hazard `anyBound` exists
to avoid, arrived at by the recovery path itself.

So each half is compiled and loaded independently and whatever loads is kept, never revisited.
The cost is that halves can no longer see each other: a class referring to one in the other
half is refused by the emitter and reported as skipped. That is a real loss of coverage and
still far better than the whole world staying interpreted because of one module.

### static function outside(group:Array<Module>, env:Environment):Array<String>

Anything scripted that this batch does not itself declare is outside it, and a module naming one
has to stay interpreted: cppia links a class either inside the module being loaded or as a host
class, and a scripted class elsewhere is neither.

Two sources, and the second is easy to miss. Classes already compiled for another world are
obviously outside. So is every other module of *this* world when only a subset was offered,
which is the normal case: a state re-entered later brings its own batch, and the classes it was
written beside are not in it. Leaving those out does not make them reachable, it only stops the
compiler knowing they are not, so instead of refusing the module it emits a direct link that
resolves to nothing and rejects the whole batch at load with a bad link naming a class that
plainly exists.

### static function anyBound(env:Environment):Bool

The hazard is a class existing both ways at once, the two halves disagreeing about statics and
identity. What rules that out is not every class being compiled, it is every reference going
the same way, including from the classes still interpreted. So this asks whether there is
anything to substitute at all, and a module left interpreted has nothing to substitute to,
since the emitter refuses whatever names it.

Read from the world's own map rather than from `built`. The two differ exactly when a world was
handed nothing because the work was done for a previous one, and answering from `built` there
announces a substitution that cannot happen.

### public static function booleans(decls:Array<ModuleDecl>):Map<String, Map<String, Bool>>

cppia has no boolean in its type system. Its expression types are void, null, object, string,
float and int, and the loader folds `Bool` into the int one, which is exactly right inside
compiled code, where a boolean is a machine word and nobody can tell, and wrong the moment a
value leaves it. A `Bool` handed back through reflection arrives as `0` or `1`, so the
interpreter's `== true` is false, its typed mode rejects the assignment, and the same source
answers differently depending on whether it happened to compile.

The declaration is the only place that knowledge still exists, so it is taken from there and
carried to the boundary.

### static function dropDanglingUsers(accepted:Array<Unit>, skipped:Array<Skip>,

A reference to a refused class cannot link, and the loader rejects the WHOLE module over it, so
one refusal would otherwise cost every class in the batch. Dropping the modules that lean on it
keeps them interpreted together, which is where their dependency already is. Repeats until
nothing more falls out, since dropping one module can strand another.

Presence is keyed by the CLASSES on offer rather than by module name, since a reference names a
class and a module may declare several under a name of its own.

### public static function compile(inputs:Array<Unit>, ?ambient:Array<String>, ?external:Array<String>, ?statics:Array<String>):Result

All modules are declared before any is emitted, so they may refer to each other in any order.
Emission runs against a throwaway writer first, since a module that failed part-way through
would otherwise leave a corrupt record behind.

## src/hxscript/cppia/Emitter.hx

### function implementationOf(a:AbstractDecl, pack:String):ClassDecl

An abstract has no runtime form of its own, in Haxe or here. What exists is a class of
statics, each taking the boxed value as a leading `this`, and a box that carries which abstract
it belongs to. The box, the operators and the `from`/`to` conversions stay with the
interpreter, which is where the type information they need lives; the methods are an ordinary
class and compile like one.

Built through `ScriptedAbstract.staticForm` rather than a copy of it, so the compiled methods
cannot drift from the interpreted ones.

### function forAsWhile(v:String, it:Expr, body:Expr, pos:Position):Expr

cppia's own loop expression has no JIT implementation: the base code generator traces the
node's name and emits nothing, so with the JIT on the loop silently does not run at all. The
Haxe compiler lowers `for` the same way and never produces one, which is why the gap goes
unnoticed.

The loop variable is declared inside the body so every pass rebinds it, which is what the loop
expression did and what a closure made in the body expects.

A range needs no iterator test; anything else is bound to a temporary and asked once whether it
is already an iterator, since only a static type could answer that and there is none here.

### function inheritedMember(name:String):Bool

Extending a host class puts members in scope that no declaration here mentions, so a name that
resolves to nothing is not necessarily an error, since it may be `x` on a `FlxSprite`. Reading it
off `this` by name is right for those and wrong for everything else, and this used to be
decided by whether the class extended anything at all, which meant a genuine typo, or a call a
script inherited from a DIFFERENT host, compiled to a lookup that finds nothing and returns
null. Silently: the interpreter would have said `Unknown identifier` and stopped.

That is the worst shape a bug can have here, because it only appears once a module compiles.
The same source runs correctly interpreted and does nothing at all compiled, and the thing that
changed is not in the script.

An empty field list means reflection could not enumerate the class rather than that it has no
members, because some builds carry no field tables, so it is read as "cannot tell" and the name is
allowed through, which is where this started.

### function shapeOf(c:{values:Array<Expr>, expr:Expr, ?guard:Expr}, ref:Expr,

`case {n: v}` and `case [a, b]` describe a shape, which cppia's switch cannot express: it
compares values. So they are lowered here into an ordinary condition and some declarations,
and the chain the caller builds does the rest. A field is reached through `Reflect` because
nothing about the matched value's type is known at this point.

Nested patterns recurse, so `case {pos: [x, y]}` works; a name in a leaf position binds, and
`_` matches without binding.

### function comprehension(loop:Expr, want:Null<String>, pos:Position):Expr

Emitted as written, a comprehension becomes a one-element array whose element is a loop, which
is why `[for (k in 0...5) k]` came out as `[0]`. What it means is an accumulator, so that is
what it becomes:

    { var tmp = []; for (k in 0...5) tmp.push(k); tmp; }

The push goes at every position whose value the comprehension keeps, which is what makes a
filtering `if` work without needing a value meaning "produced nothing": an `if` with no `else`
simply has no push on the branch it does not take. The interpreter reaches the same answer by
a different route, returning a void marker that its accumulator skips.

The temporary is what the block yields, so it has to be the same kind of array the target
asked for, which is what `temporaryArray` carries: it has no declaration of its own to take
the type from.

## src/hxscript/error/Printer.hx

### class Format

The shape is deliberate rather than decorative. `origin:line: character n` is what every editor
and terminal already knows how to turn into a click, and the quoted line with a caret under it is
what turns "somewhere on line 42" into "there".

```
Playground.hx:42: character 17
  var x = foo(;
              ^
Unexpected token ';'
  this usually means ...
```

Every part is optional and drops out cleanly when unknown, because half the phases have no source
position at all and a renderer that needs one is a renderer that cannot be used everywhere.

## src/hxscript/error/Hint.hx

### class Hint

The distinction is the whole point. Almost every failure an embedder hits reports its symptom
accurately and says nothing about its cause, and the cause is nearly always somewhere the message
does not mention:

| the message | the actual cause |
| --- | --- |
| `Unknown identifier: FlxG` | the package was never included, or the name is not ambient |
| `Unknown identifier: ADD` | the abstract holding `ADD` has no runtime form |
| `Cannot call null` | the method is `inline`, so there is no method to call |
| `Type not found` | dead code elimination removed it, or it was never in the build |

Each of those took a page of documentation to explain and a support conversation to diagnose. The
information needed to tell them apart is available at the moment of failure, namely whether the name
exists in the type index and whether the field exists under a different spelling, so it is cheaper
to answer than to document.

Nothing here runs on a successful path. A hint is built when an error is already being reported.

## src/hxscript/error/Sink.hx

### class Sink

The library's error surface used to be three unrelated things: exceptions thrown at the caller,
per-module callbacks a host had to remember to set, and strings inside a compile report. Each was
reasonable on its own and together they meant a host wanting one place to look had to build it,
and a host that had not thought about it yet got nothing at all, which is the worst outcome, because
silence during setup is exactly the failure mode all four setup steps have.

So: everything routes through here, `onDiagnostic` is how a host takes over, and until one does
there is a default that prints. The per-module callbacks still work exactly as before, and now
also arrive here, so nothing that already handles errors has to change.

```haxe
hxscript.error.Sink.onDiagnostic.push(function(d) {
    if (d.phase == PRun) myConsole.log(d.toString());
});
```

## src/hxscript/error/Sources.hx

### class Sources

A position is a byte offset and a line number. Turning that into the two lines a reader actually
wants, the source line and a caret under the column, needs the source, and the source is a
long way from where the error is rendered. Threading it through every exception, every callback
and every report entry would touch most of the library to carry a string that is already sitting
in memory.

So it is kept here, keyed by origin, and written by `Module` and `Script` as they parse. Nothing
else has to know.

The cost is one reference per loaded script for as long as the process lives, which is the same
text a host almost always still holds anyway. `forget` and `clear` are there for a host that
reloads scripts often enough to care.

## src/hxscript/macro/Expose.hx

### class Expose

The interpreter needs none of this: it resolves a name against the global `TypeCollection`, which
`Index` fills with everything in the build, and it reads whatever `Config` injected
into it. Compiled code has neither. It has no interpreter to be injected into, and it links
against real classes and real statics, so every bare name a script may use has to be written down
as a full path before a module is emitted.

Written down by hand that is two lists to maintain, one of which, the `name=owner::field` form
for host statics, is easy to get subtly wrong and fails at compile time with a message about an
identifier rather than about the list. This collects both from the build instead, the same way the
interpreter's table is collected.

Mark what scripts may reach:

```haxe
@:scriptAmbient
class Player {
    @:scriptStatic('player')       // a script writing `player` gets this
    public static var current:Player;
}
```

Then hand it all over once, at startup:

```haxe
Expose.apply();
```

That fills both sides from the same marks: `Config.globalStatics` so an interpreted script can
write `player`, and `Compiler.ambient`/`Compiler.statics` so a compiled one resolves the same name
to the same static. Marking a thing once and having it work either way is the point, since filling
only one side gives a script that runs until the day it is compiled, or the reverse.

The two lists are also readable on their own, for a host that wants to add to them:

```haxe
Compiler.ambient = Expose.ambient().concat(['extra.Type']);
Compiler.statics = Expose.statics();
```

Whole packages can be exposed without touching their types, for a host whose API is already
grouped:

```
--macro hxscript.macro.Expose.expose(['game', 'engine.api'])
```

Neither list changes what a script is *allowed* to touch. `Config` still decides that, and still
decides it for interpreted and compiled code alike. This only tells the emitter where the things
it already accepts actually live.

### public static macro function apply():haxe.macro.Expr

Sets `Compiler.ambient` and `Compiler.statics` for compiled code, and adds every
`@:scriptStatic` to `Config.globalStatics` for interpreted code, so a bare name means the same
thing whichever way a script ends up running.

The interpreted side records where the value lives rather than the value, which is what makes
the two sides agree over time as well as at startup: the emitter turns a bare name into a real
static access, so compiled code always saw a host reassigning one, while a copied value never
would. Each interpreter follows the binding as it is set up.

A name the host bound by hand still wins. Nothing is overwritten here; `Interp.setDefaults` applies
`globalVariables` first and skips any `globalStatics` entry whose name is already taken.

## src/hxscript/macro/Keep.hx

### class Keep

Dead code elimination decides what to strip from a build by what the *compiled* code references.
A script references nothing at compile time, so under hxcpp's default `-dce std` a member no
compiled call site happens to use is removed, and a script reaching it gets a null field. The
failure looks exactly like a defect in this library and is not: it is a property of how the host
was built, and it took a page of documentation to stop people reporting it as a bug.

`IntIterator` is the one that catches everyone. `for (i in 0...n)` compiles to a direct loop and
every call site inlines `hasNext`/`next`, so nothing in a finished program references them
statically and DCE takes them, leaving the most ordinary loop in the language broken in scripts
while working perfectly in the host beside them.

This runs from `extraParams.hxml`, so it applies to anyone who adds the library and needs no
setting. It marks whole types rather than individual members on purpose: which member a script
will want is not knowable, and the cost of keeping a handful of standard types is small next to
the cost of the failure.

`-D hxscript_no_keep` turns it off, for a host minimising binary size that would rather choose for
itself. `-dce no` makes it moot, and is what the benchmark suites use.

## src/hxscript/macro/Scripted.hx

### function requalify(typed:TypedExpr, e:Expr):Expr

Re-emitting a native constructor means taking a body the typer has already lowered and
asking the typer to accept it again somewhere else. Three constructs do not survive
that, and each one reports from inside the original library's source, naming neither
the bridge nor the base that asked for it:

- a **sub-module type** loses its qualifier, so `new FlxButtonEvent()` re-emits
  unqualified and fails with `Type not found: FlxButtonEvent`;
- a **compiler temporary** from inlined code is named with a backtick, which is not a
  variable name (`"`" is not a valid variable name`);
- an **abstract's implementation class** is named directly, so reading an enum
  abstract's constant comes back as `FlxButtonState_Impl_.NORMAL`
  (`has no field FlxButtonState_Impl_`).

The typed form still knows the qualifiers, so it is walked first to collect them and
the emitted syntax is rewritten against that.

The last one is only repairable for a genuine static. An abstract's *instance* members
are compiled to statics on the same class and marked `@:impl`, and those have no
spelling that works from outside; `reemittableConstructor` reports those rather than
guessing, and the bridge takes the other route.

### function reemittableConstructor(e:TypedExpr):Null<String>

Rebuilding a base's constructor means re-typing a body the typer has already lowered, and some
lowered bodies can never be re-typed anywhere else: one naming a `private` type, which the
bridge is not allowed to name, one naming an abstract's implementation class, whose members do
not exist under any spelling reachable from outside, and one assigning to `this`, which an
inlined abstract constructor does.

Without this the build fails anyway, with a handful of errors reported inside the
library's own source, naming neither the bridge nor the base that pulled it in.

**The answer is no longer a refusal.** This used to end the build with that reason turned into a
sentence, and a base of that shape simply could not be extended, which cost the whole heaps 3D
scene graph. What it decides now is only *which way* the base is constructed: with a reason in
hand the bridge stops rebuilding and either calls a `hxscript.shim.<flattened path>` static
`init` where one exists, or gets a real constructor calling a real `super` and lets Haxe build
the base. So this is a routing question, and the reason string is diagnostic rather than fatal.
`Presets.HEAPS_3D` is the note on what that bought.

## src/hxscript/runtime/Interp.hx

### static var trackAccess:Bool = false;

`accessingInterp` exists for one purpose: `readLocal` and `writeLocal` compare it against the
slot's owning interpreter to reject reads and writes of `(null, _)` and `(_, null)` properties
from outside their class. Those two comparisons are its only readers.

Keeping it current is not free. Every scripted class builds its own interpreter, so a call
into another class rewrites this static going in and again coming back, which is two writes per
call, each with hxcpp's write barrier, measured at about 205ns apiece and accounting for the
whole 19% gap between a same-class and a cross-class call.

Almost no script declares a `null` accessor, so almost no script needs any of it. Tracking
stays off until one is actually declared, at which point the guarded write resumes and the
checks behave exactly as before. A slot can only be read after the class declaring it has
been initialised, and initialisation evaluates expressions, so the static is always current
by the time either reader can run.

### inline function numAdd(a:Dynamic, b:Dynamic):Dynamic

The sum is worked out both ways and the narrow one is only handed back if it agrees, which is
how a running total declared `Float` survives passing two billion. On hxcpp a `Dynamic` cannot
tell a whole `Float` from an `Int`, since `3.0` answers true to `is Int`, reports `TInt` from
`Type.typeof`, and carries the same internal tag as `3`, so a value the script declared
`Float` arrives here indistinguishable from an `Int`, and adding it as one wraps into a negative
number with nothing to say it happened.

Comparing the two results is used rather than the usual sign trick because the operands are not
always numbers: a boxed abstract can satisfy `is Int` while having no bitwise operators at all,
and it must come out of here exactly as it went in.

### function createEnum(t:Dynamic, i:Int, ?args:Array<Dynamic>):Dynamic

`t` and the return are typed `Dynamic`, not `Enum<Dynamic>`/`EnumValue`: a scripted enum is an
`ScriptedEnum` class instance and its values are `ScriptedEnumValue` instances. Neither is a native
enum, so an `Enum<Dynamic>`/`EnumValue`-typed boundary makes hxcpp coerce the
argument (and result) with a native-enum cast that yields null, breaking bare enum constructors on
the C++ target. `Type` is the `TypeProxy` proxy, which dispatches scripted and native enums
alike from a `Dynamic`.

### function boolean(o:Dynamic, f:String, v:Dynamic):Dynamic

cppia's type system has no boolean. Its expression types are void, null, object, string, float
and int, and `Bool` folds into the last, which is correct and fast inside compiled code, where a
boolean is a machine word and nothing can tell the difference, and wrong the instant a value
crosses back out through reflection. It arrives as `0` or `1`, so `== true` is false, typed
mode rejects the assignment, and `Type.typeof` says `TInt`. The same script would then answer
differently depending on whether its module happened to compile, which is the one thing a
partly-compiled world must never do.

The declaration is where that knowledge survives, and the world can still read it, so it is
asked. Ordered so the common path is one `Std.isOfType`: nothing that is not an integer can be
a boolean that lost its type, and in a world with nothing compiled there is no boundary to
cross at all.

## src/hxscript/setup/Abstracts.hx

### class Abstracts

An abstract has none of its own. A script handed one sees nothing at all: no methods, no operators, no
`from`/`to`, and for an `enum abstract` none of its constants, which is why
`sprite.blend = BlendMode.ADD` fails with `Unknown identifier: ADD` rather than with anything
about abstracts. [`hxscript.macro.Abstract`](../src/hxscript/macro/Abstract.hx) emits a reflectable wrapper
that gives it one, and `Compiler.addMetadata` applies that from outside, which is the only option
for a library nobody here owns.

Two ways to say which, because the right answer differs by library size:

- **`abstractPackages`** scans and wraps everything found. Right for flixel, where `FlxColor`,
  `FlxAxes` and `FlxTextAlign` are exactly what scripts hold, and a hand-written list is
  discovered the hard way, as a runtime `Unknown identifier` from somebody's script, then a
  rebuild to add one line.
- **`abstracts`** names them one at a time. Right for openfl and lime, which hold roughly four
  hundred abstracts between them, nearly all platform plumbing no script will ever hold, and every
  generated wrapper is a `@:keep` class in the binary.

A scan makes the exposed set implicit, so `-D hxscript_verbose` prints it.
`-D hxscript_no_abstracts` turns the step off.

## src/hxscript/setup/Autowire.hx

### class Autowire

Three steps, in the order [docs/advanced.md](advanced.md#4-adding-a-game-library)
puts them. Each is driven by the [`Library`](../src/hxscript/setup/Library.hx) records for whichever libraries this
build has, so adding `-lib heaps` to a build is the whole of turning heaps on.

1. **get the types into the build**, so they exist to be found at all, by including a package,
   by referencing individual modules, or both. `Library.types` is why there are two.
2. **bridge** the bases scripts may extend. [`Bridges`](../src/hxscript/setup/Bridges.hx).
3. **wrap** the abstracts scripts hold as values. [`Abstracts`](../src/hxscript/setup/Abstracts.hx).

The fourth step, shimming members with no runtime form, is a closure rather than a name and
happens at startup in [`Shims`](../src/hxscript/setup/Shims.hx), reached from [`Boot`](../src/hxscript/setup/Boot.hx).

The steps run at two different moments, and which one each belongs to is decided by the API it
uses rather than by preference. `Compiler.include` and `Compiler.addMetadata` are initialization
APIs and warn if called later, so they run here directly, which is safe, because every argument
has already been read by the time an init macro runs and `-lib flixel` is visible whether it came
before or after `-lib hxscript`. Anything that asks the typer waits for `onAfterInitMacros`, since
another init macro may still add a class path and a type resolved before that resolves against an
incomplete one.

| define | effect |
| --- | --- |
| `hxscript_no_autowire` | none of this runs |
| `hxscript_no_bridges` | step 2 off; scripts can name library types but not extend them |
| `hxscript_no_abstracts` | step 3 off |
| `hxscript_no_shims` | step 4 off |
| `hxscript_setup_only=a,b` | only these libraries |
| `hxscript_setup_skip=a,b` | everything except these |
| `hxscript_setup_skip=heaps3d` | heaps without its 3D half, which is nine of the ten bridges its presets generate |
| `hxscript_host=pack` | also bridge the host's own `@:scriptable` classes |
| `hxscript_verbose` | print what each step did |

All four steps fail silently in the sense that matters: the build succeeds, and a script finds a
null field months later. `-D hxscript_verbose` is worth reaching for the moment anything is
surprising.

### static function manifest(bridges:Array<Expr>, forced:{refs:Array<Expr>, args:Array<FunctionArg>, named:Array<String>}, globals:Array<String>,

Two jobs in one type, and both need it to exist. Bridges and forced modules are only ever
reached reflectively, so nothing in the program refers to them and dead code elimination takes
them; the arrays below are real references and stop that. And [`Boot`](../src/hxscript/setup/Boot.hx) reads the
string lists rather than re-deriving them from `Presets`, so a `custom` record the build acted
on cannot be one the startup forgot, because the two halves read the same answer instead of asking
the same question twice.

### static function hostLibrary():Library

Presets describe somebody else's library. This is the same work applied to code the host owns,
driven by metadata on the classes themselves rather than by a list somewhere else, and it deals
in the two marks that already exist:

- `@:scriptable` means scripts may extend the class, which needs a bridge generated for it.
- `@:scriptAmbient` means they may name it without importing it, which
  [`hxscript.macro.Expose`](../src/hxscript/macro/Expose.hx) already arranges, but only for a type the
  build actually has. Nothing in a host references a class that only scripts use, so it is
  never typed, so `Expose` never sees the mark and the name silently does not resolve. Both
  marks therefore go into `types`, which is what forces them in.

Read from source text rather than from the typer, because being in the build is the very thing
being arranged: asking the typer for a type in order to decide whether to put it in the build
has the question the wrong way round.

## src/hxscript/setup/Boot.hx

### class Boot

[`Autowire`](../src/hxscript/setup/Autowire.hx) put the library's types in the build, generated the bridges and gave the
abstracts a runtime form. None of that is visible to a script yet: the names still have to be made
resolvable, the shims registered, and the compiler told which names are ambient. That is this.

**Nothing calls it.** `Environment`, `Module` and `Script` each call `ensure()` before they do
anything else, and it is idempotent, so the setup is in place before the first interpreter exists
no matter which of the three a host reaches for first. That ordering is not decorative:
[docs/advanced.md](advanced.md#order-of-operations) is a page about it, because a
module builds its interpreter in its constructor and an interpreter reads `Config` when it resets.
Anything registered afterwards is registered too late for the modules already made.

A host that wants to add to `Config` still can, and should do it before its first `Module` for the
same reason. Calling `ensure()` first, explicitly, is a fine way to be sure of the order.

The two halves do not re-derive the same answer independently. `Autowire` bakes what it actually
wired into `hxscript.wired.Manifest`, and this reads that, so a `Presets.custom` record the build
acted on cannot be one the startup forgot about.

## src/hxscript/setup/Bridges.hx

### class Bridges

A bridge is an empty class extending the base and implementing `hxscript.IScripted`, whose
`@:autoBuild` generates an override of every inherited method that dispatches to the script when
it defines one and falls through to `super` otherwise. Without one, a script gets
`Class <base> can't be extended for scripting`.

Written by hand that is one file per base, which is clearer for one or two and unreadable for
twenty; [`examples/battle/bridges/ScriptedEntity.hx`](../examples/battle/bridges/ScriptedEntity.hx)
is the hand form if you want to see it. Everything here is generated instead, because the list is
data: a [`Library`](../src/hxscript/setup/Library.hx) record names its bases and this turns them into classes.

Two details are load-bearing and neither is obvious:

**One module per bridge.** A type defined as a sub-type of another module can only ever be named
through that module, which would make every reference read `hxscript.wired.Manifest.ScriptedFlxSprite`.

**Something has to reference them.** Bridges are only ever instantiated reflectively, so nothing
in the program refers to one and dead code elimination removes them. `@:keep` alone does not save
a module nothing pulled in. `Manifest.bridges` is a real reference, and it doubles as what the
setup report reads to say which bridges this build actually has.

`-D hxscript_no_bridges` turns the step off. It is the expensive one, costing a generated
override per inherited non-`inline`, non-`final` method, per base, so a host minimising binary
size and willing to give up `extends` gets to say so.

## src/hxscript/setup/Library.hx

### typedef Library =

[docs/advanced.md](advanced.md#4-adding-a-game-library) says a script writing
`class Boss extends FlxSprite` needs four separate things to be true, and that each one fails
differently. This is those four, written down per library instead of scattered across a build
file, a macro and a startup function:

| field | the step it answers | symptom when it is wrong |
| --- | --- | --- |
| `roots` / `ignore` | the types are in the build | `Type not found` |
| `bases` | a bridge exists per scriptable base | `Class <base> can't be extended for scripting` |
| `abstractPackages` / `abstracts` | its abstracts are wrapped | `Unknown identifier: ADD` |
| `globals` | names resolve without an import | `Unknown identifier: FlxG` |

The fifth thing, shimming members with no runtime form, is a real closure rather than a name, so
it lives in [`Shims`](../src/hxscript/setup/Shims.hx) instead.

Nothing here imports the library it describes, which is the point: these are strings, so the
record is readable from a macro *and* from the running program, and the compile-time half and the
runtime half cannot drift apart. [`Presets`](../src/hxscript/setup/Presets.hx) holds one of these per library the
library knows, and `Presets.custom` is where a host adds its own.

## src/hxscript/setup/Presets.hx

### class Presets

A library switches itself on by being in the build: `-lib flixel` defines `flixel`, which is what
`active()` tests. There is no list of enabled libraries to keep in step with the haxelibs, and
nothing to add to a build file, since `-lib hxscript` beside `-lib flixel` is the whole of it.

The lists were derived the way [docs/advanced.md](advanced.md#a-library-not-covered-here)
says to derive them by including the package root with an empty ignore list, building, and adding
whatever the failure names, against these versions:

| library | version |
| --- | --- |
| lime | 8.3.2 |
| openfl | 9.5.2 |
| flixel | 6.2.0 |
| flixel-addons | 4.0.1 |
| flixel-ui | 2.6.5 |
| heaps | 2.1.0 |

They are version-sensitive by nature: a module that stops compiling as runtime code, a class that
is renamed, an ordinary method that becomes `inline`. Build with `-D hxscript_verbose` to see
exactly what was wired.

`custom` is the escape hatch, and the supported way to describe a library that is not here or to
describe the host's own classes. Append to it from an init macro, before `Autowire` runs:

```
--macro hxscript.setup.Presets.custom.push({define: 'mygame', title: 'my game', ...})
```

### public static final CORE:Library =

The per-library `Tools` classes are the set of paths a script cannot walk at speed, or at all. Every
accessor on `haxe.io.Bytes` is `inline` and so has no runtime form to call; `openfl.Vector` is
an abstract, so filling a vertex buffer from a script is one interpreted `push` per float; and
`lime.utils.UInt8Array`'s only constructor is inline and generic, which closes the audio
crossing outright. The rest of these records describe somebody else's library. This one
describes the holes in the ones underneath.

The two that need a display library are listed by the record for the library they need, so this
one holds only what is always available.

`haxe.io.Bytes` and its two streams are here for the same reason and are easy to miss: a host
that never touches them itself does not compile them in, so a script reading or writing binary
data gets `Type not found` for a standard-library class that is plainly standard. `BytesTools`
already names `Bytes` in a signature; the streams are what a script needs to produce them.

### public static final LIME:Library =

`lime.tools` is the command-line tool, not runtime code, and `lime._backend` is
platform-specific plumbing that only compiles under the backend it belongs to.

`lime.ui.KeyModifier` is deliberately not in `abstracts`, and is the one abstract here the
wrapper generator cannot take. Its setters combine the abstract's own constants into the
underlying value (`this |= ALT`), and a constant referred to unqualified from inside the
abstract emits as the boxed wrapper, so the operation asks for an `Int` operator on a class:
`AbstractValue_lime_ui_KeyModifier should be Int`, reported inside lime's source. Compound
assignment alone is fine, and `flixel.util.FlxColor` does it throughout and wraps, so the
shape to watch for is the unqualified constant, not the `|=`.

No bases: `lime.app.Application` is the process entry, and a script that wanted to subclass it
would have had to exist before the program started. Scripts subclass the display library's
classes instead.

### public static final FLIXEL:Library =

One recursive include of `flixel` covers flixel-addons and flixel-ui too: all three declare
types under the same package root, across three classpaths, and `include` scans them all. That
is why `FLIXEL_ADDONS` and `FLIXEL_UI` carry no roots of their own. They contribute the
modules to skip and the bases to bridge, and nothing else.

The abstract scan is worth it here. `FlxColor`, `FlxAxes`, `FlxTextAlign`, `FlxDirectionFlags`
are exactly the values a script holds, and a hand-written list of them gets discovered the hard
way, as a runtime `Unknown identifier` from somebody's script, then a rebuild to add one line.
Forty-one come out of it, and `-D hxscript_verbose` lists them.

**`flixel.ui.FlxButton` is not on the bridge list, and it was not left off by choice.** Nothing
about it looks unbridgeable, since it is an `FlxSprite` with callbacks, and `FlxSprite` bridges.
The callbacks are what stop it: flixel wraps each in `private class FlxButtonEvent` and the
constructor does `onUp = new FlxButtonEvent(...)`, so the rebuilt constructor would have to
name a type it is not allowed to name. The build says so by name. Scripts still construct
`FlxButton`, which is in `globals`. They just cannot subclass it.

### public static final HEAPS:Library =

It does, but not by the same route, and that is the useful part. **heaps 2.1.0 cannot be
included wholesale.** `h2d.Flow` does not compile without domkit, and `new h2d.Flow()` fails in
a bare project, so this is a defect in the release rather than anything scripting did. And
enough of `h2d` refers to `Flow` that no ignore list saves the include, because `ignore` only
removes a module from the include and not from what other modules reference. The domkit on
haxelib (0.3.0) is older than the one heaps 2.1.0 expects, so adding it does not help either.

So heaps uses the other mechanism: `types` names the modules scripts should be able to reach,
and `Autowire` emits a reference to each. Explicit instead of wholesale, which is a fair trade
for a library where wholesale is not on the table, and a smaller binary besides.

**`h2d.Object` bridges; `h2d.Drawable` and everything under it does not.** Drawable's surface
mentions `h3d.Vector4`, and a generated override of it fails to compile inside Vector4's own
constructor. That rules out `Bitmap`, `Graphics`, `Text` and `Anim` as bases, which is the same shape
of limit openfl's display list has, one level lower down the tree. Scripts still construct all
of them freely.

### public static final SMIDR:Library =

A script that can draw needs no help to draw a readout. What it cannot easily do is draw one
that looks like the application it is running inside, and a host with a UI already has that
problem solved for itself and not for its scripts. So the widgets come along.

`smidr.types` is **almost** nothing but abstracts, and the scan is pointed at it for that reason:
ten of its twelve modules are an `enum abstract` (`UITone`, `UIFill`, `UIEase`, `UIAlign`,
`UICursor`, `UICursorMode`, `UIDockZone`, `UIEdge`, `UIGlyph`, `UIAnimationPreset`), which is the
exact shape a script cannot see the constants of without a wrapper, and they are ordinary
constructor arguments, so a script writes them constantly. The other two, `UIMenuItem` and
`UIRailTabDef`, are typedefs, which the scan passes over. Wrapping the package wholesale rather
than naming them is right here for the same reason it is right for flixel: the alternative is
finding out one at a time, from somebody else's `Unknown identifier`.

`smidr.flixel` is left out of the include. It is the bridge to a framework this build may not
have, and including it would make the UI toolkit depend on flixel being present.

**Nothing here bridges, and that is now a choice rather than a limit.** `UIComponent` is the
obvious base, and the reason it was not one has gone: it is an openfl `Sprite`, whose constructor
writes `mouseChildren` and `mouseEnabled`, which a rebuilt constructor could not write from outside
the class, and a base of that shape is constructed by Haxe now rather than refused. Openfl's own
display list bridges for the same reason. So this record is a place to add `bases` when somebody
wants scripted widgets; until then scripts build and drive every widget freely and declare none.

## src/hxscript/setup/Shims.hx

### class Shims

An `inline extern` method is substituted at every compiled call site and never becomes a method,
so reflection finds nothing and a script calling it gets `Cannot call null` against code that
looks perfectly ordinary in the library source. `Config.callShims` takes a compiled closure that
performs the call, keyed `<fully.qualified.Owner>.<method>`; the interpreter walks the receiver's
superclasses looking for one before giving up.

This is the step that changes under you between library versions, which is why it is worth
knowing rather than assuming. flixel 6.2 turned `FlxG.sound.playMusic` into this form and every
script calling it started failing, against script code that had not changed and library code that
still read like a normal method.

**Overloads collapse.** A shim is one closure per name, so the several `inline extern` overloads
a library declares all arrive here as one entry that has to sort out which was meant from the
arguments it got. `clipToWorldRect` below is the shape that takes.

Unlike the three compile-time steps this cannot be driven from [`Library`](../src/hxscript/setup/Library.hx) records,
because it is code rather than names, and code that references the library's own types. A host
with one of its own adds it to `Config.callShims` directly; nothing here is in the way.

`-D hxscript_no_shims` turns the step off.


## Further notes

Moved out when docstrings were capped at five lines of prose. Each heading names the file
and the symbol the note belongs to.

### src/hxscript/compile/Capture.hx :: class Capture

cppia captures by value, copying the outer variable into the closure's frame, so later writes on
either side are invisible to the other. A local that is both captured and assigned therefore
becomes a one-element array and every mention of it becomes an element access, letting the closure
share the cell.

Selection is by name rather than by binding, so sibling scopes reusing a name are all boxed.

### src/hxscript/cppia/Backend.hx :: public static var jit:Bool = true;

It is a process-wide switch rather than a per-module one, so it is set once and never unset by
ordinary running. Leaving it on is the usual choice: it costs nothing measurable at load time
and is worth several times again on a script's own logic.

One thing does unset it. A batch that the loader refuses with the JIT on and accepts with it
off has met a JIT fault rather than a bad module, and since that fault is cumulative rather
than caused by any one construct, the only useful response is to stop jitting for the rest of
the process. That happens automatically and is reported.

### src/hxscript/cppia/Backend.hx :: static function retryWithoutJit(result:Result, group:Array<Module>, env:Environment, report:Report):Bool

A module that the loader refuses with the JIT on and accepts with it off has met a JIT fault,
and a JIT fault is cumulative: it belongs to how much has been jitted rather than to any one
construct, so narrowing would blame whichever module happened to tip it over. Giving up on the
JIT for the rest of the process is the only answer that stays true, and it is a good trade, since
compiled without the JIT is still far ahead of interpreted.

### src/hxscript/cppia/Backend.hx :: static function load(result:Result, offered:Array<Module>, env:Environment, report:Report):Null<String>

Guarded, and that is the point of it. The loader reports a fault by throwing, and what it
throws is a bare string that names the fault and nothing inside the module, so an unguarded
load turns one unemittable construct in one script into the host process ending. Caught, the
worst case is that everything stays interpreted, which is the same degradation every other
refusal already has.

### src/hxscript/cppia/Backend.hx :: static function bind(module:Module, env:Environment):Bool

Skipping the work is not the same as skipping the binding. `built` outlives any one world, so a
world made after a reload would otherwise find everything already compiled and be handed
nothing: the classes exist, every report says so, and none of them is what runs, because the
interpreter reads the world's own map and that map is empty.

### src/hxscript/cppia/Backend.hx :: class Backend

Optional in two senses: nothing here is built unless `-D hxscript_cppia` is set, and any module
the emitter cannot express is reported in `skipped` and left to the interpreter rather than
failing the batch.

Loading the result needs a host built with `-D scriptable`, via `cpp.cppia.Module.fromData`.

### src/hxscript/cppia/Emitter.hx :: class Emitter

cppia resolves names when the module links, so `emitIdent` must place each one as a local, a field
of the enclosing class, or a type; anything else throws `Unsupported` rather than being
guessed at. An unknown TYPE is not a refusal. It is emitted as `Dynamic`, costing dispatch speed
for that expression alone.

### src/hxscript/cppia/Emitter.hx :: var classVars:StringMap<StringMap<String>>;

Only fields that are plain variables are here. A field with a `get` or `set` accessor is left
out on purpose: reaching it directly would read the storage behind the property and skip the
accessor that gives it its meaning.

### src/hxscript/cppia/Emitter.hx :: var expectedArray:Null<String> = null;

An array literal has nothing in it to say what it holds, so it was always built as the loose
kind. That is fine until something reads it back through an annotation promising a specific
kind, because the read trusts the annotation and reinterprets the memory, which crashes rather
than misbehaves. Carrying the target's type to the literal keeps the two descriptions of the
same array in agreement.

### src/hxscript/cppia/Emitter.hx :: var moduleAbstracts:StringMap<String> = new StringMap();

An abstract has no runtime form, so a value of one is its underlying value and a method on it
is a static taking that value as a leading `this`. Knowing which paths those are is what lets
a call be routed there, and what each one boxes is what lets a slot holding one be typed as
the thing it really holds.

### src/hxscript/cppia/Emitter.hx :: var temporaryArray:Null<String> = null;

A local's array type comes from what it was declared as, and a temporary is declared with no
type at all, so it would be built untyped however specific its contents are. That matters when
the temporary is then read into a slot the loader believes holds a typed array: it reads the
wrong shape and yields nothing useful. This carries the type across the one step where there is
no declaration to take it from.

### src/hxscript/cppia/Emitter.hx :: function ownView(decls:Array<ModuleDecl>):Void

Every module in the batch is declared into one table, so a name declared in one is visible from
all of them, and a name the host also offers is decided by whichever was written last. Neither
is how Haxe reads a module: its own declarations and its own imports come first, and another
file's types are reachable only through an import.

A fresh emitter is built for each module and declares the batch before emitting one of them, so
applying that module's own view last is enough to get the precedence right. Without it a
script declaring `Damage` beside a host `Damage` silently linked the wrong one.

### src/hxscript/cppia/Emitter.hx :: function emitFun(args:Array<Argument>, body:Expr, ret:Null<CType>, pos:Position):Void

Captures are left to the loader, which walks the enclosing stack layout; this only has to nest
and to keep variable ids unique. Default argument values become null-checks prepended to the
body, since cppia accepts only constants in the signature.

### src/hxscript/cppia/Emitter.hx :: function accumulate(e:Expr, target:Expr):Expr

Only the positions whose value the comprehension keeps are rewritten. In a block that is the
last expression and nothing before it; in a loop it is the body, so nesting accumulates into
the same container; in an `if` it is each branch that exists.

A `key => value` becomes a `set` rather than a `push`, which is what makes the map form work:
the caller has already built `target` as a map when that is what the body yields.

### src/hxscript/cppia/Emitter.hx :: function accessCode(mode:Null<String>, pos:Position):String

Accessors are written as `V` rather than `C`. Both make the loader resolve `get_<name>` or
`set_<name>` at link time, but only `V` also registers the field as a native property, and a
by-name access, which is how this emitter reads fields, consults the accessor only for
those. With `C` the read would silently return the storage slot instead.

### src/hxscript/cppia/Emitter.hx :: function storableType(path:String):Void

A slot is only ever stored as bool, int, float, string or object, and everything that is not
one of the first four is an object, so naming the exact class buys nothing, while naming one
the loader cannot resolve leaves the slot with no store type at all and drops it to untyped
access. Only the types that change the storage are written; the rest are `Dynamic`.

### src/hxscript/cppia/Emitter.hx :: function hostField(e:Expr):Bool

Only a field access qualifies, and only when its object cannot be shown to be a class from this
batch: those have a known layout and are reached by offset. Everything else may be a property,
and there is no way to tell from here which, so both are handled the one way that works for
either.

`this` is excluded because a scripted class's own fields are its own, whatever it extends.

### src/hxscript/cppia/Emitter.hx :: function nativeAbstract(path:String):Null<Class<Dynamic>>

A host abstract has no runtime class, so `BlendMode.ADD` cannot be emitted as a static access:
the loader finds no `openfl.display.BlendMode` to link against and refuses the whole module with
`Bad link`, which names neither the class nor the field. What the interpreter reaches instead is
the `AbstractValue_*` wrapper the setup generates, and the same wrapper is what tells this
whether a path is an abstract at all.

Cached including the misses: nearly every path asked about is an ordinary class, and the answer
is a type resolution.

### src/hxscript/cppia/Emitter.hx :: function abstractConstant(wrapper:Class<Dynamic>, name:String):Null<Dynamic>

This is not an optimisation, it is the only honest spelling. An enum abstract's constants are
compile-time values, and compiled Haxe writes the underlying `1` or `"add"` at the call site, so
there is nothing at runtime for `BlendMode.ADD` to be. The wrapper holds each constant behind a
getter returning a boxed value, which is right for the interpreter and wrong for anything handing
it to a host API, so the box is opened here and the contents emitted.

### src/hxscript/cppia/Emitter.hx :: function declaredClass(path:String):Null<String>

Worth resolving because the alternative is `Dynamic`, and `Dynamic` decides how every later
access to the value is performed: a field read becomes a lookup by name at runtime rather than
a known offset, and so does every method call. For a value touched once that is nothing; for
one touched per column or per frame it is the difference between a renderer that keeps up and
one that does not.

Only classes declared here qualify. A host class would have to be resolved through the glue,
and one that turned out not to be there would fail to link and take the whole module with it.

### src/hxscript/compile/Report.hx :: class Report

The three outcome lists are separate because they are three different problems with three
different fixes, and folding them together loses the distinction exactly when it matters:
`compiled` worked, `skipped` is the emitter declining to emit something, and `failed` is the
loader declining to accept what was emitted.

### src/hxscript/compile/Report.hx :: public var failed:Array<Skip>;

Kept apart from `skipped` because they are a different problem with a different fix. A skip is
a construct with no bytecode spelling, is expected, and is answered by writing the script
differently or by leaving it alone. A failure here means what was emitted was not acceptable,
which is a defect somewhere below the script, and the loader names the fault without naming
anything inside the module.

### src/hxscript/compile/Report.hx :: public var bytes:Int;

The one number here that describes the result rather than the run. A host showing what its
scripting costs has nothing else to point at: the classes are counted, the time is spent and
gone, and the memory a world occupies cannot be separated from the heap it shares. This can be,
because it was written.

### src/hxscript/compile/Skip.hx :: class Skip

The reason used to be a bare string against a module name, which is enough to know something was
left interpreted and not enough to do anything about it. A module is a file, a file holds a
hundred lines, and the construct the emitter could not express is on one of them, so the
position is carried when the emitter knew it.

### src/hxscript/Config.hx :: public static var strictAccess:Bool = false;

This flag is not the only way enforcement turns on: `checkAccess` runs when
EITHER this or `typedMode` is set, and `typedMode` defaults on. Leaving this
`false` therefore does not disable the check; both have to be off for that.
An access can still be waived at the call site with `@:privateAccess`.

### src/hxscript/Config.hx :: public static var typedMode:Bool = #if hxscript_dynamic false #else true #end;

Defaults to on; `-D hxscript_dynamic` flips the default off, and a host may set it per script world
at runtime. Numeric result typing (`Int` vs `Float`) is unconditional and not gated by this flag.

### src/hxscript/Config.hx :: public static var callShims:Map<String, (o:Dynamic, args:Array<Dynamic>) -> Dynamic> = new Map();

When `obj.method(args)` finds no runtime method, the interpreter looks up a shim for the object's class
(walking up its superclasses) before failing. The closure receives the receiver and the call arguments.

### src/hxscript/Config.hx :: public static var globalStatics:Map<String, String> = [];

The difference from putting the value in `globalVariables` is when it is read. A value goes in
once and is that value forever; a binding is followed every time an interpreter is set up, so a
static the host reassigns between runs means the current thing rather than whatever it held at
boot. Compiled code always read these live, because the emitter turns the bare name into a real static
access, so this is what stops the two from disagreeing.

Filled from `@:scriptStatic` by `hxscript.macro.Expose.apply`. A name already in
`globalVariables` wins, so a host that sets one by hand keeps it.

### src/hxscript/debug/Metrics.hx :: class Metrics

Off. `on` is a plain static read at each counting site, so a build that never turns it on pays a
predictable branch on paths that already cost far more than one, and a host that never mentions
this file pays that and nothing else.

**These count interpreted work only, and that is the point rather than a limitation.** A module the
runtime compiler took runs as native bytecode and passes through none of this, so `calls` falling to
zero as `Compiler.compile` succeeds is the compiler working, not the counter breaking. A readout
built on these has to say so, or it reports a fully compiled project as a project doing nothing.

Everything here is a count of events since the last `reset`. Rates are the host's business: it knows
what a frame is and this does not.

### src/hxscript/Environment.hx :: public var substituting:Bool = false;

A compiled class carries its own statics and its own identity, so the danger is a class
existing both ways at once and the two halves disagreeing. What prevents that is not every
class being compiled. It is every reference going the same way. With this on, a scripted
class that has a compiled form is reached through the compiled form from everywhere, including
from code that is still interpreted, so there is only ever one of it.

It therefore has to be on whenever ANY class here is compiled, not only when all of them are.

### src/hxscript/Environment.hx :: public function booleansOf(path:String):Map<String, Bool>

cppia has no boolean in its type system and folds `Bool` into its integer one, so a value that
leaves compiled code through reflection arrives as `0` or `1` and the interpreter has to put
the type back. The declaration is the only place that survives, so it is read from there.

Answered lazily off the module's own declarations rather than recorded when something is
compiled, so it cannot fall out of step with a host that drives a backend itself and fills
`compiled` by hand. Every answer is kept, the empty ones included, because a native class asked about
on the way up an inheritance chain is the common case, and it is asked about once.

### src/hxscript/error/Diagnostic.hx :: class Diagnostic

Errors used to arrive by three different routes that agreed on nothing: an exception with a
message, a per-module callback with a different message, and a compile report holding strings. A
host wanting all of them in one place had to normalise them itself, and a host wanting none of
them got silence rather than a default.

A `@:structInit` class rather than an anonymous structure, because a diagnostic crosses into host
code and anonymous structures resolve fields by name at runtime on static targets.

`hint` is the field that earns its place. `message` says what happened, which is usually the
symptom; `hint` says what causes it, which is usually somewhere else entirely. `Unknown
identifier: FlxG` is a message about a script and a hint about a build.

### src/hxscript/error/Hint.hx :: static function unknownName(name:String):String

Three different failures wear this message, and the type index tells them apart. If a type of
that name is in the build, the script only failed to import it, and the import to write can be
quoted exactly. If nothing of that name is in the build, the cause is a step earlier: the
package was never force-compiled, so there was never anything to find.

### src/hxscript/error/Hint.hx :: static function custom(message:String):Null<String>

`Cannot call` is the one worth catching. It is what an `inline` method looks like from a
script: the compiler substituted it at every call site and never emitted a method, so
reflection finds nothing and the call fails against library code that reads perfectly
ordinarily. Nothing about the message suggests that, and it costs a page of documentation to
explain each time.

### src/hxscript/error/Hint.hx :: public static function membersOfValue(o:Dynamic):Array<String>

Emptiness is meaningful and is why this is public: a caller that gets nothing back has learned
that the receiver cannot be enumerated, not that the member is absent. On hxcpp a standard
library class carries no field table unless the build kept one, so `Type.getInstanceFields` on
a `StringBuf` is empty however many methods it has, and answering "no such method" from that
would be a confident wrong answer.

`ReflectProxy` rather than `Reflect`, because a scripted instance keeps its fields in its own
table and the standard one would report the interpreter's plumbing instead.

### src/hxscript/error/InterpException.hx :: public override function details():String

This is what a host prints when it catches one, so it is where the hint has to be: a host that
calls into a script directly and prints the exception is the common case, and it never goes
past a `Module` boundary where the sink would have seen it.

Unless `fullStack`, leading native frames inside the interpreter's own package are trimmed, so
the native trace points at the script rather than at the interpreter.

### src/hxscript/error/ParserException.hx :: public var lineNumber:Int;

Not `line`, which is the obvious name and is taken. On PHP `haxe.Exception` descends from the
native `\Exception`, which already declares one, and redeclaring it fails the whole build with
`Redefinition of variable line in subclass`, on a target this library otherwise compiles for,
refused over a field name. `lineNumber` is also what `haxe.PosInfos` calls it.

### src/hxscript/error/Phase.hx :: enum Phase

Worth carrying rather than folding into the message, because the phase decides where to look and
the same words mean different things in different ones. `Type not found` while parsing is a
missing import in a script; the same words while emitting mean the runtime compiler could not
link something and the script is fine.

### src/hxscript/error/Printer.hx :: public static function errorAt(e:ErrorKind, origin:String, line:Int):String

For a caller that has the position but no exception to read it from. `ParserException`'s
constructor is the one that matters: Java and C# require `super()` to be the first statement
when the base class is a native one, so the message has to be built before any field is
assigned, and `this` cannot be passed to the overload above.

### src/hxscript/error/Sink.hx :: public static var printing:Bool = true;

On by default, and the reason is the shape of the failures rather than a preference for noise.
A host that has not wired up error handling is the host most likely to be looking at a script
that silently does nothing.

Turned off automatically the first time a listener is added, on the reading that a host with a
listener has somewhere better to put them. Set it back to true to keep both.

### src/hxscript/error/Sink.hx :: public static function fromException(e:haxe.Exception, phase:Phase, ?context:String):Diagnostic

The two exceptions the library raises itself know their own position and can say what usually
causes them. Anything else, whether a host's exception crossing a script boundary or a `throw` in a
script of a value that is not an exception, has only a message, and pretending otherwise
would put a wrong position on it.

### src/hxscript/flixel/TriangleTools.hx :: public static function quads(strip:FlxStrip, vertices:Array<Float>, uvs:Array<Float>, quads:Int):Void

Vertices and UVs are interleaved x/y pairs, four vertices per quad in corner order. Indices are
derived rather than passed, because for quads they are entirely predictable and having a script
build them means another buffer to fill and another crossing to pay for.

Buffers are resized and refilled in place, so a steady frame rate allocates nothing.

### src/hxscript/macro/Index.hx :: static function recordConstructor(info:TypeInfo, d:Dynamic):Void

Only the counts: how many arguments it declares and how many a caller must supply.
The types are not wanted here and the defaults cannot be carried across the
serialization boundary, so a padded argument is passed as null and the callee's own
default handling takes it from there.

### src/hxscript/macro/Keep.hx :: public static function run():Void

Both halves are needed, and they answer different failures. Keeping saves a type already in
the build from being stripped, and shows up as `Cannot call null` when it is missing. Including
puts a type in the build that nothing referenced at all, and shows up as
`Unknown identifier`, and `@:keep` cannot help there, because there is nothing yet to keep.

Fields as well as types, because keeping a class whose methods were eliminated does not help:
what a script resolves is the member.

### src/hxscript/Module.hx :: class Module

The lifecycle is staged so cross-references between modules can resolve: `new` parses,
`init` seeds the interpreter and exposes each type's name, `start` runs the module-level program,
and `startType`/`startTypes` initialize the types themselves. An `Environment` drives those stages
across every module in a world so imports between them line up.

### src/hxscript/Module.hx :: public dynamic function onParsingError(e:haxe.Exception):Void {}

Empty by default, and that is not the same as errors being swallowed: everything reaching here
has already gone to [`hxscript.error.Sink`](../src/hxscript/error/Sink.hx), which prints it until a host takes
over. Overriding this is purely additive, so a host that prints here as well should either use
`Sink.listen` instead or set `Sink.printing` to false.

### src/hxscript/proxy/TypeProxy.hx :: class TypeProxy

Note that scripted types and their values are ordinary class instances, not native `Class`/`Enum`/
`EnumValue` runtime objects, so parameters and returns here are `Dynamic`: typing them as the
native runtime types would make the target coerce a scripted instance to null at the call boundary.

### src/hxscript/python/Shims.hx :: class Shims

On python Haxe maps `Array` to the builtin `list` and `String` to `str`, and implements their
Haxe-level members as statics on `python.internal.ArrayImpl` / `StringImpl` taking the value as
their first argument. Nothing is a method of the builtin, so `Reflect.field(arr, 'push')` finds
nothing and a script gets `Cannot call Array.push` against the most ordinary call there is.

The interpreter keys a shim on the receiver's type name, which is what `Array.` and `String.`
below are.

### src/hxscript/runtime/AnyMap.hx :: class AnyMap implements IMap<Dynamic, Dynamic>

`Map` is a multi-type abstract with no runtime class of its own: the compiler reads the key type
and constructs a `StringMap`, `IntMap`, `EnumValueMap` or `ObjectMap` in its place. A script that
writes the key type gets that same choice made for it while parsing. One that does not has nothing
to decide from until a key actually arrives, so this holds the decision open, picks on the first
write, and is a plain delegate from then on.

Every read before that first write answers as an empty map, which is what it is.

The delegate is the real map, so a script may hand one of these to host code typed against
`Map` or `IMap` and it behaves; only `Std.isOfType(m, StringMap)` can tell the difference.

### src/hxscript/runtime/Interp.hx :: class Interp

Inside this class `Type`, `Reflect` and `Std` are aliased to `hxscript.proxy.TypeProxy`,
`ReflectProxy` and `StdProxy` (see the imports), so reflection transparently understands scripted
types as well as native ones. The real ones are still reachable as `HaxeType` and `HaxeReflect`,
which is worth remembering when reading this file.

### src/hxscript/runtime/Interp.hx :: var frameLocals:Map<String, Variable> = null;

`locals` is read for every variable read, write and declaration, and reaching it meant loading
the call stack, loading its array, indexing it and null-checking the frame. The frames only
change in `pushStack`, `shiftStack` and `execute`, so holding the answer costs three
assignments and saves four loads on the interpreter's busiest path. Null exactly when there is
no frame, which is what the entry guard in `expr` tests.

### src/hxscript/runtime/Interp.hx :: var hasCaptures:Bool = false;

Capture variables exist only while a `switch` case with pattern bindings is being evaluated,
which is a sliver of what an interpreter runs, yet every identifier read consulted the map
anyway. Conservative on purpose: `clear` resets it and a single `remove` leaves it set, so the
flag can cost a lookup that was not needed but can never skip one that was.

### src/hxscript/runtime/Interp.hx :: var declaredNames:Array<String>;

An entry is pushed for every variable declaration, every function parameter and every caught
exception, which makes this one of the most frequently written structures in the interpreter.
A pair object meant an allocation per binding; two typed arrays mean none at all.

A `@:structInit` class was tried here first and measured 3.1% SLOWER than the anonymous
structure, because these entries are written once and read once, so there is no repeated
field access to win back the allocation. Removing the object entirely is the version that
pays. The two arrays are always pushed and popped together and so always have equal length.

### src/hxscript/runtime/Interp.hx :: public static var interpSwitches:Int = 0;

Every scripted class builds its own `Interp`, so a call into another class flips this static
on the way in and again on the way back, and each flip is a static write with the write
barrier that implies. This counter is here to confirm that the flips actually track the gap
between same-class and cross-class call costs before anything is restructured around that
theory. Compiled out unless `-D hxscript_profile` is set.

### src/hxscript/runtime/Interp.hx :: public function new(?environment:Environment, ?parent:Dynamic)

Call `setDefaults` before running anything in a bare interpreter. `Script`, `Module`,
`ImportModule` and every scripted type already do, which is why the constructor no longer does
it: all five construction sites in this library called `setDefaults` again immediately
afterwards, either wiping what the constructor had just seeded or seeding it a second time, so
the constructor's copy never had a surviving consumer. Applying the default wildcard import is
most of what an interpreter costs to build, so doing it twice was most of what building one
cost.

### src/hxscript/runtime/Interp.hx :: function abstractArith(op:String, a:Dynamic, b:Dynamic):Dynamic

The left operand is tried first, and the right one only for commutative operators, so a
non-commutative operator can never be applied the wrong way round.

### src/hxscript/runtime/Interp.hx :: inline function numMul(a:Dynamic, b:Dynamic):Dynamic

Unlike `+` and `-` this keeps wrapping when two `Int`s overflow, which is deliberate. Wrapping
multiplication is an idiom, since every hash and seeded random generator is built on it, and
promoting would break them for good: a `Float` carries 53 bits of mantissa, so a product past
that has already lost the low bits the following mask wanted, and no later `&` can recover them.
Addition cannot lose bits that way, which is why it can afford to promote and this cannot.

### src/hxscript/runtime/Interp.hx :: function readLocal(l:Variable, id:String):Dynamic

Split out of `getLocal` so a caller that has just looked the slot up does not look it up again,
and so the accessor dispatch can be skipped outright: a plain variable has no accessor, which
is nearly every read, and testing one field beats falling through a switch over five string
constants to reach the same answer.

### src/hxscript/runtime/Interp.hx :: var frame:Map<String, Variable> = null;

Copying the captured scope into a fresh map on every invocation made a call cost O(size of
the enclosing scope): measured at 3x for twenty captured variables, paid by every local and
anonymous function in a script whose top level declares anything.

Reuse is safe because a frame is left exactly as it was found. `restore` puts back every
binding the prologue and the body shadowed, so the map is pristine again by the time the
call returns, which is the same guarantee the enclosing scope already relies on.

### src/hxscript/runtime/Interp.hx :: var old = declaredNames.length;

`expr` is size-bound on hxcpp: it is one enormous switch, and every line inside it competes
for registers and instruction cache with the handful of node kinds that actually run in a
loop. This was the largest cold body still inline, and it also declared a closure, which
costs the enclosing function further. Moving it out shrinks the hot path without changing
a single thing about what it does.

### src/hxscript/runtime/Interp.hx :: public function bindDeclared(v:Dynamic, ?t:CType):Variable

Shared by local `var` declarations and by class/static field initialisation. They used to
differ. A field assigned its value straight into `r`, so a field declared with an abstract
type never boxed and its methods and operators were unreachable, while the identical local did.

### src/hxscript/runtime/Interp.hx :: function typeMatches(v:Dynamic, ?t:CType):Bool

Deliberately implemented ON `tryCast` rather than as a parallel matcher: the check used to
SELECT a static extension and the check used to ENFORCE an annotation have to agree, and two
implementations of the same rules drift. Only reached on the extension-resolution path, which
is already the fallback taken after a direct field lookup failed.

### src/hxscript/runtime/Interp.hx :: function staticHost(o:Dynamic):Dynamic

A compiled class carries its own statics, so while a world is only partly compiled there are
two stores for the same declaration and redirecting to either one strands the other. Once the
whole world is compiled there is only one store worth using, and every static read, write and
call has to reach it, including the ones the host makes on its way in, which would otherwise
set up a copy that nothing else reads.

### src/hxscript/runtime/Variable.hx :: class Variable

Declared as a `@:structInit` class rather than an anonymous structure so its fields compile to
direct member access. Anonymous structures are looked up by field name at runtime on static
targets, and this type is read on every variable access, so that cost lands in the interpreter's
hottest path. `@:structInit` keeps a construction syntax, which is now `{ref: value}`: `r` became a
property over the numeric lane and a property has no storage for `@:structInit` to fill.

The lane is the second reason this is a class. On a target where a `Dynamic` is a pointer, writing an
`Int` into a slot allocates, and a loop counter is written once per iteration, so a number is kept
unboxed in `num` with `lane` recording which kind it is. `r` boxes on the way out and only when
something asks for a `Dynamic`, so nothing holding one of these has to know which lane it is in, and
the paths that do know use `setInt`/`setFloat`/`asInt`/`asFloat` and never box at all.

### src/hxscript/setup/Abstracts.hx :: public static function generate(libs:Array<Library>):Array<String>

Applying the macro is only half of it: the abstract also has to BE in the build. Metadata on a
type nothing compiled references does nothing, because the type is never typed, and the script
then fails with `Type not found`, which points nowhere near the cause. `Autowire.include` is
the other half, and it runs first for that reason.

### src/hxscript/setup/Autowire.hx :: public static function resolve(path:String):Null<haxe.macro.Type>

Everything here runs inside `onAfterInitMacros`, which is late enough for the typer: the class
path is complete and every `-D` has been read. Asking it, rather than looking for a file, is
what tells the two ways of not having a type apart: a record naming something that was
renamed or misspelled, and a module that exists on disk but whose contents are `#if`-gated out
of this build. The second is entirely normal and must not be reported as anything.

### src/hxscript/setup/Autowire.hx :: static function include(libs:Array<Library>):Void

`include`, not `keep`. Keeping only adds metadata to types the build is already compiling, so
pointing it at a library the program never references does nothing whatsoever and does it
without complaint. Scripts reach library classes by name, reflectively, so dead code
elimination has no reason to keep anything the host itself never touched.

The ignore list is the union across every active library, not each library's own. A module that
has to be skipped is often not in the package of the library that brought it in.
`flixel.addons.nape` arrives with flixel-addons and is skipped by flixel's include, because
flixel-addons declares no root of its own.

### src/hxscript/setup/Autowire.hx :: static function reference(libs:Array<Library>):{refs:Array<Expr>, args:Array<FunctionArg>, named:Array<String>}

The other way to get a type into the build, for a library where including the package is not
an option, so see `Library.types`. A reference is what pulls a module in; `@:keep` on its own
cannot, because it only marks a module the build already has.

Two forms come back, because an abstract cannot be a reference *value*: an array of class
expressions, and a signature whose parameter types name the rest. Naming a type in a signature
loads its module either way.

### src/hxscript/setup/Autowire.hx :: static function tagged(source:String, pack:String, module:String, bases:Array<String>, named:Array<String>):Void

Line-based rather than one regular expression: metadata and access keywords may sit on any
number of lines between the tag and the `class` it belongs to, and a pattern loose enough to
span that is also loose enough to attach a tag to the type after the one it was meant for.
Pending tags are therefore cleared by the first line that is neither blank, metadata, nor a
comment.

### src/hxscript/setup/Boot.hx :: static function read():Void

Reflective rather than a direct reference, because the manifest only exists when autowiring
ran. A build with `-D hxscript_no_autowire`, or one that puts `src` on the class path without
going through the haxelib at all, which is what the test suites do, has no such class, and
a direct reference would stop the library compiling in either case.

### src/hxscript/setup/Boot.hx :: static function imports():Void

Guarded on the type actually resolving. A record may name something this build does not have, such as
a class renamed between library versions, or a module an ignore list kept out. Registering a
global import for a type that is not there turns a clear `Unknown identifier` into a resolution
that silently yields null.

### src/hxscript/setup/Boot.hx :: static function blacklist():Void

`hxscript.Config` is blocked always, and is the only thing that is. A script that can reach it
can turn off the blacklist, replace the interpreter class and rewrite the global imports for
every other script in the process, so leaving it open makes every other entry decorative.

The file system and process APIs are a policy question rather than a safety one, and the answer
differs by host: a modding API wants them shut, a tool whose scripts are its program wants them
open. `-D hxscript_sandbox` is the shut answer. Neither is imposed by default, because a
default that breaks a working host on upgrade is worse than a default that asks.

### src/hxscript/setup/Library.hx :: var roots:Array<String>;

`include`, never `keep`: keeping only marks types the build already compiles, so pointing it at
a library nothing references does nothing at all, silently. Empty for a library that shares a
package root with one already listed, since flixel-addons and flixel-ui both live under `flixel`,
and one recursive include covers all three across classpaths.

### src/hxscript/setup/Library.hx :: var ignore:Array<String>;

Collected across every active library and applied to every include, because the module that has
to be skipped is often not in the package of the library that brought it.

### src/hxscript/setup/Library.hx :: var types:Array<String>;

The second of the two ways to get a type into the build, and the one to reach for when the
first cannot work. `ignore` only removes a module from an include; it does nothing about a
module something else *references*, and a package with one broken module in it therefore
cannot be included at all. heaps 2.1.0 is that case: `h2d.Flow` does not compile without
domkit, plain `new h2d.Flow()` fails in a bare project, and enough of `h2d` refers to it that
including the package is not an option at any ignore list.

[`Autowire`](../src/hxscript/setup/Autowire.hx) emits an array naming these, which is a real reference and so pulls
each module in. The cost is that the list is explicit rather than "everything under here".

### src/hxscript/setup/Presets.hx :: public static var custom:Array<Library> = [];

Appended from an init macro, which is early enough: `Autowire` does its work inside
`onAfterInitMacros`, after every `--macro` line has run. A record whose `define` matches one
below replaces it rather than adding to it, so overriding a preset is the same gesture as
adding one.

### src/hxscript/setup/Presets.hx :: public static final OPENFL:Library =

**The display objects do bridge**, which is worth saying because the documentation used to
claim they could not. `DisplayObject`'s surface does mention types a generated override cannot
name, and those methods are skipped and left to `super`, which is the designed degradation,
not a failure. Bridging one is expensive though: `DisplayObject` has a very wide method
surface and the cost is one generated override per inherited method.

**No abstract scan.** openfl and lime hold roughly four hundred abstracts between them, nearly
all platform plumbing, and every generated wrapper is a `@:keep` class in the binary. The ones
named here are the ones scripts hold as values.

### src/hxscript/setup/Presets.hx :: public static function active():Array<Library>

Callable from a macro and from the running program, which is the reason this file imports
nothing: the compile-time half and the runtime half read the same records, so a name the
bridge generator wired cannot be a name the startup code forgot to register.

A `custom` record whose `define` matches a shipped one replaces it, so overriding a preset and
adding one are the same gesture.

### src/hxscript/stdlib/BytesTools.hx :: class BytesTools

Reading bytes one at a time from a script is expensive twice over. Every accessor on
`haxe.io.Bytes` is declared `inline` in the standard library, so none of them has a runtime
representation to call and each one has to go through a shim; and even with a shim in place, a
file of any size means one interpreted call per byte.

These do the loop in compiled code, so reading a whole file costs one call instead of tens of
thousands. The result is a plain array, which a script indexes at roughly a tenth the cost of a
call, so the copy pays for itself long before the file is finished with.

`@:keep` because nothing in a host calls this; only scripts do, by name, and dead code elimination
cannot see that.

### src/hxscript/stdlib/Shims.hx :: class Shims

`StringTools.hex` and `lpad` are `inline`, so under the default `-dce std` every compiled call
site substituted them, nothing references them, and they are eliminated, so a script calling one
gets `Cannot call null` against a method that is plainly in the standard library. `-dce no` is the
other answer, at the cost of binary size across the whole program.

### src/hxscript/syntax/Lexer.hx :: var tokens:Array<TokenEntry>;

An `Array` used as a stack rather than a `List`: a linked list allocates a node per pushback on
top of the entry itself, and the depth here is never more than a token or two. The end is the
next token to be read, so `push`/`pop` are the array's own; `add`, which queues a token to be
read after everything already pending, inserts at the front instead.

### src/hxscript/syntax/Parser.hx :: function mapClassFor(path:String, targs:Array<CType>):String

`Map` is a multi-type abstract, so the compiler picks `StringMap`, `IntMap`, `ObjectMap` or
`EnumValueMap` from the key type and there is no `Map` class to instantiate at runtime. A
written key type settles it here, for free, at parse time.

Only `String` and `Int` are decided this way. Any other key needs to tell an enum value from a
plain object, which a name alone cannot do, so it stays `Map` and the runtime picks from the
first key instead.

### src/hxscript/syntax/Token.hx :: class TokenEntry

A `@:structInit` class rather than an anonymous structure, for the same reason as `Variable` and
`StackFrame`: anonymous structures resolve their fields by name at runtime on static targets, and
a recursive-descent parser pushes a token back on every lookahead that does not match, which is
most of them. Keeps the `{t: ..., min: ..., max: ...}` construction syntax.

### src/hxscript/types/IScriptedInstance.hx :: private function __scriptConstruct(base:ScriptedClass, arguments:Array<Dynamic>):Void;

**Not `__construct`**, which is the name hxcpp generates for a class's own constructor. A bridge
declaring both meets its base's constructor as an overload of the same name, and where the base
takes two arguments that erase to `Dynamic` the two are indistinguishable, and the C++ compiler
reports an ambiguous call inside generated code, naming a file nobody wrote.
`flixel.addons.ui.FlxUIState`, whose constructor is two optional `TransitionData`s, is the case
that found it.

### src/hxscript/types/ScriptedAbstract.hx :: class ScriptedAbstract implements IScriptedType

The implementation follows what Haxe itself does: every method becomes a static taking the boxed
value as its first argument, named `this`. That makes `this` an ordinary parameter inside the
body, so the whole existing call machinery (argument binding, scoping, `return`) applies
unchanged, and a constructor's `this = v` is simply a write to that parameter.

### src/hxscript/types/ScriptedAbstract.hx :: public static function staticForm(f:FieldDecl, name:String, underlying:Null<CType>):FieldDecl

Shared with the runtime compiler, which has to produce the same shape from the same
declaration or the two would disagree about what a method is. Every method becomes a static
taking the boxed value as a leading `this`, a parameter of the abstract's own type becomes its
underlying type, and a constructor is renamed and made to return what it built.

### src/hxscript/types/ScriptedAbstractValue.hx :: class ScriptedAbstractValue extends AbstractValue

It extends `AbstractValue` so that everything the interpreter already knows about abstracts (the
operator dispatch, the equality and comparison fallbacks, the variable-slot bookkeeping) applies
to scripted ones without a second code path. What a compiled abstract carries in macro-generated
statics, this carries in its `owner`.

### src/hxscript/types/ScriptedClass.hx :: public function staticArgType(name:String):Null<CType>

A `using` is otherwise matched by method NAME alone, so `(5).twice()` would reach a `String`
extension. A script-declared extension still carries its parameter types at runtime, so the
receiver can be checked against this before the call. Compiled extensions have no such
information, so see the parity document.

### src/hxscript/types/ScriptedTypedef.hx :: public function matchesStructure(value:Dynamic):Bool

Without the interpreter that resolved this typedef there is nothing to resolve field types
against, so the check falls back to field presence alone.

### src/hxscript/types/TypeCollection.hx :: var ?ctorArgs:Int;

Recorded because the runtime compiler needs it and has nowhere else to get it. cppia links a
call by its exact argument count, so a script's `super(a, b)` against a constructor whose third
argument is optional is a count short, accepted by the loader and rejected by the runtime.
Knowing the real shape lets the emitter make up the difference. Only a class has one.
