# Execution modes

A script can be interpreted or compiled to bytecode, and the bytecode can be jitted. This page is
about what choosing between them means for you. The measurements behind every figure quoted here are
in [`mode-benchmarks.md`](mode-benchmarks.md).

The short version: compiling is worth about **21x** on ordinary work and about **37x** on calls, it
costs roughly **7ms per module** to do, and it is decided per module rather than per application. If
your scripts contain loops, turn it on. If they are short handlers called a few times each, it will
not pay for itself.

The compiler translates at runtime, from source text, inside your application. That is the point of
it: Haxe can emit the same bytecode, but only as a build step, so it cannot compile a script that did
not exist when you shipped. [Runtime translation, and how it differs from Haxe's
cppia](#runtime-translation-and-how-it-differs-from-haxes-cppia) is the comparison.

## Contents

- [The three modes](#the-three-modes): [interpreted](#interpreted), [cppia](#cppia),
  [cppia with the JIT](#cppia-with-the-jit)
- [What compiling buys](#what-compiling-buys)
- [What compiling costs](#what-compiling-costs)
- [Choosing](#choosing)
- [Runtime translation, and how it differs from Haxe's cppia](#runtime-translation-and-how-it-differs-from-haxes-cppia)
  covering [the two pipelines](#the-two-pipelines), [side by side](#side-by-side),
  [what it makes possible](#what-runtime-translation-makes-possible),
  [what Haxe's does better](#what-haxes-does-better)
- [What the compiler refuses](#what-the-compiler-refuses)
- [What is not known](#what-is-not-known)

## The three modes

### Interpreted

The default. A module is parsed into declarations, an `Environment` builds scripted classes from
them, and calling a method walks its expression tree.

This is the only mode that needs no cppia-specific build flags, which is not the same as needing
nothing from the host's build. What a script can reach, interpreted or compiled, is decided by how
the host is built and what it exposes; [`embedding.md`](embedding.md) is the page for that. What
interpreting saves you is `-D scriptable` and `-D hxscript_cppia`, and nothing else.

### cppia

The same declarations compiled to hxcpp's own bytecode. `Compiler.compile(env)` emits a module,
loads it, and makes its classes the ones the world runs; `Cppia.compile` is the layer under that for
a host that wants the bytes rather than the effect. Either way what comes back is an ordinary
`Class<Dynamic>`. [`embedding.md`](embedding.md#compiling-at-runtime)
is the integration.

Needs two defines. `-D scriptable` is hxcpp's, and makes the host's own types reachable from
bytecode, which is what a compiled script calls into. `-D hxscript_cppia` is this library's, and is
what compiles the emitter in at all: without it `Cppia.compile` reports every module skipped, which
looks exactly like a compiler that refuses everything.

### cppia with the JIT

The same bytecode with `cpp.cppia.Host.enableJit(true)` called before a module loads.

It is a process-wide switch in hxcpp rather than a per-module one, so it is a decision made once at
startup, and you cannot have some modules jitted and others not.

## What compiling buys

Per **ordinary operation**, about **21x**. Per **call**, about **37x**. Calls gain more because a
call is where the interpreter does most of its bookkeeping, and bytecode does none of it.

Adding the JIT on top is worth about **1.4x on operations** and **2.8x on calls**, which is useful but not
another order of magnitude, and the spread matters more than the average. It is 16x on a case that is
nothing but bytecode (`noCall`) and 1.1x on one bounded by string allocation in the runtime
(`strConcat`), which would not care what drove it. The rule of thumb: the JIT speeds up a script's
own logic and does nothing for time spent inside the standard library.

**Expect less than this in a real application.** Those figures come from a corpus built to isolate
the interpreter, where every case is a loop of one operation, which is exactly the work bytecode removes. A
script that mostly calls into your engine will move far less, because the part being sped up is not
where its time goes. Treat them as a ceiling.

## What compiling costs

**About 7ms per module, once.** Getting a module ready costs about 1.2ms interpreted against about
8.4ms compiled, for a module of 80 small functions. That scales with module size, so treat it as a
shape rather than a constant.

It is charged once against a saving charged per operation, so there is a break-even. For the module
measured it lands near **5,100 operations** in the life of that module. Anything with a loop in it
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

`Cppia.compile` reports what it emitted and what it skipped with a reason, so a host can decide per
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
That is what this emitter is, and it is around 2,900 lines of it.

## What the compiler refuses

Very little, now. A module is refused whole, before anything runs, and interpreting it is correct,
so a refusal costs speed rather than behaviour.

| refused | note |
| --- | --- |
| a name it cannot resolve | an identifier or type that is neither in the batch, ambient, nor a host static |
| a reference to a class compiled in another batch | it cannot link across batches, so it waits for one that holds both |
| a host superclass whose constructor shape is unknown | the type table has no entry for it, so a call to it cannot be padded |
| a method or non-constant field *of a native abstract* | an abstract has no class to call a method on once compiled; its constants fold to their value |
| a static extension whose receiver type is not known here | rewriting a call that was really a member call would change what the program does, so it is refused instead |
| inline type declarations | anonymous types declared in place |
| local property accessors | `var x(get, set)` declared inside a function body |
| mixed array and map literals | a literal the emitter cannot type as one or the other |

Everything else in the language a script actually uses now compiles, including the things this page
listed as refused until recently: abstracts, map comprehensions, rest arguments, property accessors,
key-value loops, `??`, `%=`, `case a | b:`, and a `using` whose receiver type is known. Pattern
matching compiles in full, over enum constructors, arrays, objects and nested shapes alike: a switch
the `SWITCH` instruction cannot express is rewritten into an if-else chain rather than refused.

The evidence is [`test/cpp/CppiaTest.hx`](../test/cpp/CppiaTest.hx), which runs 151 constructs
interpreted and compiled and compares the answers. It reports 0 wrong, and one refusal that is
asserted on purpose. That is a stronger claim than "nothing was refused": a construct that compiled
to the wrong thing would show as `WRONG`, and two of them did during the work.

## What is not known

**A script type cannot share a short name with a host type across modules.** Each module resolves
names its own way, so a module declaring `Damage` beside a host `game.Damage` gets its own, but
another module in the same batch, which has not imported it, gets the host's. Haxe would need an
import to see it either way, so this matches, but the emitter has no per-module import table for
other people's modules and would not notice if you wrote one.

**Nothing here has been checked across scales.** The figures come from one iteration count. A fixed
per-call overhead would show up as scale sensitivity, and nothing has ruled that out.
