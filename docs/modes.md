# Execution modes

A script can be interpreted or compiled to bytecode, and the bytecode can be jitted. **Compiling
needs a target with bytecode of its own**: hxcpp, through cppia, and HashLink, through its own
loader. Everywhere else a script is interpreted and this page is not a decision you have. It is
about what choosing between them means where you do.

Every figure quoted here is hxcpp's, measured in [`mode-benchmarks.md`](mode-benchmarks.md). The
HashLink backend reaches the same construct-for-construct agreement, recorded in
[`support-table.md`](support-table.md), and is measured separately in
[`hl-benchmarks.md`](hl-benchmarks.md), which asks a different question: what a script costs against
the same program compiled by Haxe rather than against interpreting it.

The short version: compiling is worth about **26x** on ordinary work and about **46x** on calls, it
costs roughly **9ms per module** to do, and it is decided per module rather than per application. If
your scripts contain loops, turn it on. If they are short handlers called a few times each, it will
not pay for itself.

The compiler translates at runtime, from source text, inside your application. That is the point of
it: Haxe can emit the same bytecode, but only as a build step, so it cannot compile a script that did
not exist when you shipped. [Runtime translation, and how it differs from Haxe's
cppia](#runtime-translation-and-how-it-differs-from-haxes-cppia) is the comparison.

## Contents

- [The four modes](#the-four-modes): [interpreted](#interpreted), [cppia](#cppia),
  [cppia with the JIT](#cppia-with-the-jit), [HashLink bytecode](#hashlink-bytecode)
- [What compiling buys](#what-compiling-buys)
- [What compiling costs](#what-compiling-costs)
- [Choosing](#choosing)
- [Runtime translation, and how it differs from Haxe's cppia](#runtime-translation-and-how-it-differs-from-haxes-cppia)
  covering [the two pipelines](#the-two-pipelines), [side by side](#side-by-side),
  [what it makes possible](#what-runtime-translation-makes-possible),
  [what Haxe's does better](#what-haxes-does-better)
- [What the compiler refuses](#what-the-compiler-refuses)
- [Where compiled code still differs](#where-compiled-code-still-differs)
- [What is not known](#what-is-not-known)

## The four modes

### Interpreted

The default. A module is parsed into declarations, an `Environment` builds scripted classes from
them, and calling a method walks its expression tree.

This is the only mode that needs no cppia-specific build flags, which is not the same as needing
nothing from the host's build. What a script can reach, interpreted or compiled, is decided by how
the host is built and what it exposes; [`embedding.md`](embedding.md) is the page for that. What
interpreting saves you is `-D scriptable` and `-D hxscript_cppia`, and nothing else.

### cppia

The same declarations compiled to hxcpp's own bytecode. `Compiler.compile(env)` emits a module,
loads it, and makes its classes the ones the world runs; `hxscript.cppia.Backend.compile` is the layer
under that for a host that wants the bytes rather than the effect. Either way what comes back is an
ordinary `Class<Dynamic>`. [`embedding.md`](embedding.md#compiling-at-runtime)
is the integration.

Needs two defines. `-D scriptable` is hxcpp's, and makes the host's own types reachable from
bytecode, which is what a compiled script calls into. `-D hxscript_cppia` is this library's, and is
what compiles the emitter in at all: without it `Compiler.compile` reports every module skipped, which
looks exactly like a compiler that refuses everything.

### cppia with the JIT

The same bytecode with `cpp.cppia.Host.enableJit(true)` called before a module loads.

It is a process-wide switch in hxcpp rather than a per-module one, so it is a decision made once at
startup, and you cannot have some modules jitted and others not.

### HashLink bytecode

The same declarations emitted as HashLink's own bytecode and loaded into the running process, by a
second backend under `hxscript.hl`. HashLink jits what it loads, so there is no separate jitted mode
here the way there is on hxcpp.

Needs `-D hxscript_hl`, and links a small native module that the same macro compiles into the binary,
so a host writes the define and nothing else. Why it needs one at all, and what else differs from
cppia, is [`how-it-works.md`](how-it-works.md#part-three-compiling-to-hashlink). It reaches the same construct-for-construct agreement
cppia does, recorded in [`support-table.md`](support-table.md), and refuses nothing in the corpus.

The figures on this page are hxcpp's. This backend's are in
[`hl-benchmarks.md`](hl-benchmarks.md), against natively compiled Haxe rather than against the
interpreter, so the two sets are not comparable and none of them is repeated here.

## What compiling buys

Per **ordinary operation**, about **26x**. Per **call**, about **46x**. Calls gain more because a
call is where the interpreter does most of its bookkeeping, and bytecode does none of it.

Adding the JIT on top is worth about **1.5x on operations** and **2.3x on calls**, which is useful but not
another order of magnitude, and the spread matters more than the average. It runs from 7x on a case
that is nothing but bytecode (`locals`) down to 1.1x on one bounded by a read into the host
(`hostStatic`), which would not care what drove it, with string work (`strConcat`, `strInterp`) close
behind at 1.3x. The rule of thumb: the JIT speeds up a script's own logic and does nothing for time
spent inside the standard library or the host.

**Expect less than this in a real application.** Those figures come from a corpus built to isolate
the interpreter, where every case is a loop of one operation, which is exactly the work bytecode removes. A
script that mostly calls into your engine will move far less, because the part being sped up is not
where its time goes. Treat them as a ceiling.

## What compiling costs

**About 9ms per module, once.** Getting a module ready costs about 1.3ms interpreted against about
10.6ms compiled, for a module of 80 small functions. That scales with module size, so treat it as a
shape rather than a constant.

It is charged once against a saving charged per operation, so there is a break-even. For the module
measured it lands near **5,500 operations** in the life of that module. Anything with a loop in it
clears that inside one frame. A module of short event handlers, each called a handful of times, may
never clear it, and compiling it is a straight loss.

**The JIT is free to turn on.** It adds nothing measurable to load time, so it does not move the
break-even. If compiling is worth doing, so is jitting.

**`-D scriptable` is not free**, though what it costs is not measured here. It makes the host keep
type information it would otherwise discard, so it is a decision about your binary rather than about
any one script.

## Choosing

**Interpret** when scripts are small, short-lived, or called a few times each; when you cannot or do
not want to build the host with `-D scriptable`; or when you want the simplest thing that works.

**Compile** when a script has a hot loop, lives for the length of a level or a session, or is doing
enough work to notice. Compiling is per module, so this is not all-or-nothing: compile the ones that
are hot and interpret the rest.

**Enable the JIT** whenever you are compiling at all.

`Compiler.compile` reports what it emitted and what it skipped with a reason, so a host can decide per
module and interpret the remainder. Both modes produce the same class, so nothing downstream needs to
know which one it got.

## Runtime translation, and how it differs from Haxe's cppia

Haxe emits cppia itself, and it is the same bytecode, the same loader and the same JIT. So it is
worth being exact about what this library adds, because it is not a second implementation of the
same thing.

**Haxe's cppia is a build step. This is a runtime translation.** That single difference is what the
feature is for; everything else on this page follows from it.

### The two pipelines

Haxe's, where the script is an artefact you build:

```
your machine, at build time                  the user's machine
---------------------------------            -------------------------
Script.hx
  -> haxe -cppia, against                     script.cppia
     host_classes.info exported by       ->     -> Module.fromData
     the host build                              -> boot
  -> script.cppia                                -> Class<Dynamic>
```

This library's, where the script is data your application reads:

```
the user's machine, while it is running
------------------------------------------------------------------
source text  ->  hxscript parser  ->  AST  ->  Emitter
             ->  cppia bytes      ->  Module.fromData  ->  boot
             ->  Class<Dynamic>
```

Nothing in the second path leaves the process, and no part of it needs a Haxe installation. The
input is a string. It can come from a mod folder, an in-app editor, a text field, a download, or a
save file, and none of those existed when your application was compiled.

### Side by side

| | Haxe's cppia | this library's |
| --- | --- | --- |
| when the script is compiled | at your build time | while your application runs |
| what has to be installed | the Haxe compiler | nothing |
| the input | a `.hx` file on disk | a string in memory |
| can compile a script written after the release | no | yes |
| bound to the host via | `host_classes.info`, exported and imported | names resolved at load |
| after you rebuild the host | scripts must be recompiled | nothing to do |
| type checking | the full Haxe compiler | hxscript's, weaker |
| optimisation | inlining, folding, the analyzer | none |
| language covered | everything it accepts | a subset, [listed below](#what-the-compiler-refuses) |
| same source runs interpreted too | no | yes, unchanged |

### What runtime translation makes possible

**Scripts that ship after your application does.** A mod, a community map, a downloadable behaviour.
Haxe's path cannot serve this at all, because compiling would mean putting a Haxe toolchain on the
user's machine and running it there.

**One source of truth for a script.** The same text is interpreted or compiled, and both produce the
same class. There is no build artefact to keep in step with the source it came from, and no way for
the two to disagree.

**Developing interpreted and shipping compiled**, without changing anything. Interpret while you are
iterating, where errors carry positions and a change takes effect on reload; compile in production.
Because it is one input, that is a flag rather than a pipeline.

**Recompiling in place.** A module can be recompiled from changed text without restarting, so edit
and reload works with compiled code instead of only with interpreted code.

**No version handshake.** `host_classes.info` binds a script to the host build it was compiled
against, so shipping a patch means every script built against the old snapshot needs rebuilding.
Resolving by name at load has no equivalent, which matters most for exactly the scripts you did not
write and cannot rebuild.

**Deciding per module, from data.** Which modules compile can be a setting rather than a build
configuration. The engine this was written for takes it from a flag in each pack's manifest.

### What Haxe's does better

Everything else, and it is not close.

It type-checks properly, it optimises with inlining, constant folding and the analyzer, and it emits the
whole language it accepts rather than a subset. Where both can compile the same script, expect Haxe's
output to be the faster of the two. The figures on this page are a claim about this emitter, not
about cppia.

So: use Haxe's when scripts ship with your application and change when it does. Use this one when
they do not. They compose, too, since nothing stops a host from loading a `.cppia` built by Haxe and a
module translated at runtime in the same process.

### Writing cppia by hand

A third option in principle. cppia is a textual token stream with string and type pools, so nothing
stops you emitting it directly.

The tokens are not the work. The work is deciding what to emit: laying out classes and fields,
resolving names, working out which field accesses can link by offset and which have to go by name,
handling capture, and keeping all of it consistent with what the loader expects to link against.
That is what this emitter is, and it is around 4,900 lines of it. HashLink's, which has registers and
a binary format to keep straight as well, is around 5,400.

## What the compiler refuses

Very little, now. A module is refused whole, before anything runs, and interpreting it is correct,
so a refusal costs speed rather than behaviour.

| refused | note |
| --- | --- |
| a name it cannot resolve | an identifier or type that is in neither the batch, the module's imports, the module's own package, the world's type table, nor the host's ambient names |
| a reference to a class compiled in another batch | it cannot link across batches, so it waits for one that holds both |
| a reference to a scripted type that stays interpreted | there is nothing for the name to link to, and cppia resolves an unknown one to null and then uses it without looking |
| a host superclass whose constructor shape is unknown | the type table has no entry for it, so a call to it cannot be padded |
| a method or non-constant field *of a native abstract* | an abstract has no class to call a method on once compiled; its constants fold to their value |
| an inline type declaration | a `class` or `enum` declared inside a function body, which has no module to be declared into |
| a `super(...)` short of an optional in the middle whose arguments do not say which | the recorded parameter shape is what places it, and where two parameters both accept what was written there is nothing to decide on |
| a property with no field behind it, named inside its own accessor | Haxe rejects it too; compiled it would call the accessor from inside itself forever. `@:isVar` gives it a field and it compiles |
| a `for (k => v in ...)` whose key or value is not a plain name | the pair is bound to a temporary and read by name, and there is nothing to bind a pattern to |
| a `case` pattern that neither `SWITCH` nor the if-else rewrite can take | value cases, enum constructors, arrays, objects and nested shapes all can, so what is left is narrow |

The emitter carries a handful of further `Unsupported` throws for operators and accessor keywords
outside the set the parser produces. They are guards against a future parser change rather than
constructs a script can write, so they are not listed.

Everything else in the language a script actually uses now compiles, including the things this page
listed as refused until recently: abstracts, map comprehensions, rest arguments, property accessors,
key-value loops, `??`, `%=`, `case a | b:`, and a `using` whatever its receiver type, since one the
emitter cannot place statically goes through `hxscript.runtime.Using` and is decided on the value the
way the interpreter decides it. **Local property accessors** are no longer refused either: `Accessors`
rewrites `var x(get, set)` in a function body into the `get_x()` and `set_x(v)` calls it stands for
before a token is written, so the emitter never meets one. And a **mixed array and map literal** is
not a refusal but a match: it emits the same `Invalid map key=>value expression` the interpreter
raises, on the same line, which is what agreement means for a construct that is an error either way.

Three more went the same way and they are the ones a project met most often. **Constructing an
abstract the host compiled**, meaning `h3d.Vector`, `h3d.Matrix` and `h2d.col.Point`, which is most
of what a 3D script writes, used to name a type with no runtime class, so it was refused; it is now built
through `hxscript.runtime.Construct`, which reaches the static the constructor became. **A
constructor call that leaves out an optional in the middle**, `new Mesh(prim, parent)` against
`(primitive, ?material, ?parent)`, is placed by the same helper for a `new` and against the recorded
parameter shape for a `super(...)`, rather than padded from the right into the wrong parameter. And
**a host name the module never imported**, whether a secondary type of an imported module, an enum
constructor or an enum-abstract constant, is now looked up in the world's type table, which is where
the interpreter had been finding it all along.

The evidence is the shared conformance corpus: 332 constructs offered to six columns, one per way
of running a script, with `sh test/all.sh` collecting them and
[`support-table.md`](support-table.md) written from what came back rather than by hand. Every
compiled column agrees with its own target's interpreter on all 332 and refuses none.

That is a stronger claim than "nothing was refused", and the two halves are deliberately kept apart:
a refusal costs speed, and a construct that compiled to the wrong thing is reported as a difference
instead. Several were, during this work: the wrapper's class name where a boxed abstract's value
belonged, and `0` where a scaled vector belonged. That is the reason the table separates them.

## Where compiled code still differs

A refusal is safe: it is reported and the module is interpreted, so the program is slower and not
wrong. What follows is the other kind, where compiled code runs and answers differently, and says
nothing while it does it. The list is short and each entry says how to keep the module compiled.

**The check takes ten seconds.** Run the script interpreted. If the behaviour changes back, it is
this page rather than your script, and bytecode without the JIT is worth trying next.

| construct | interpreted | compiled | keep it compiled by |
| --- | --- | --- | --- |
| `Int` arithmetic that overflows | widens to `Float`: `2147483647 + 1` is `2147483648` | wraps, as Haxe does: `-2147483648` | nothing to do; compiled is the one that matches Haxe |
| reading a `Bool` field by reflection | `true` | `1` | reading the field directly, which is corrected |
| a `Bool` instance field with no type annotation, under the JIT | `true` | `1` | writing `:Bool`, which is corrected |

The first is deliberate on the interpreter's side: a script that never wrote `Int` should not have a
value silently corrupted, and without a declared type the interpreter cannot tell which case it is
in. The other two are cppia's own: it has no boolean, and folds `Bool` into its integer type. A
field the emitter knows is `Bool` is read back through a comparison, which restores it; a field it
was never told about, and a read that bypasses the field entirely, are the two places left where
the integer shows.

`test/cpp/SweepTest.hx` runs both modes over the constructs a script actually uses and reports any
that disagree, so this list is generated rather than remembered.

### One upstream fault worth knowing

Adding a comparison to a string ends the process under the hxcpp JIT:

```haxe
var n:Int = 1;
trace('' + (n == 1));   // segfault with cpp.cppia.Host.enableJit(true)
```

The emitter routes that shape through `Std.string` so a script cannot reach it, but the fault is in
`hx::CppiaJitCompiler::convert` and any cppia reaches it, including bytecode Haxe's own `-cppia`
built. It has nothing to do with this library beyond avoiding it.

It is issue 3 in [`HXCPP-ISSUES.md`](../HXCPP-ISSUES.md), which has the three lines that fix it, and
it is already applied on
[`MeguminBOT/hxcpp`, branch `patched-hxscript`](https://github.com/MeguminBOT/hxcpp/tree/patched-hxscript)
along with the other three fixes that have one:

```sh
haxelib git hxcpp https://github.com/MeguminBOT/hxcpp patched-hxscript
```

## What is not known

**A script type cannot share a short name with a host type across modules.** Each module resolves
names its own way, so a module declaring `Damage` beside a host `game.Damage` gets its own, but
another module in the same batch, which has not imported it, gets the host's. Haxe would need an
import to see it either way, so this matches, but the emitter has no per-module import table for
other people's modules and would not notice if you wrote one.

**Nothing here has been checked across scales.** The figures come from one iteration count. A fixed
per-call overhead would show up as scale sensitivity, and nothing has ruled that out.
