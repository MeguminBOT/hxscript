# hxScript

[![haxelib](https://badgen.net/haxelib/v/hxscript?label=haxelib&color=orange)](https://lib.haxe.org/p/hxscript)
[![downloads](https://badgen.net/haxelib/d/hxscript?label=downloads)](https://lib.haxe.org/p/hxscript)
[![license](https://badgen.net/github/license/MeguminBOT/hxscript)](LICENSE)
[![last commit](https://badgen.net/github/last-commit/MeguminBOT/hxscript)](https://github.com/MeguminBOT/hxscript/commits/main)
[![stars](https://badgen.net/github/stars/MeguminBOT/hxscript)](https://github.com/MeguminBOT/hxscript/stargazers)
[![Haxe](https://badgen.net/badge/Haxe/4.3+/orange)](https://haxe.org/)

A Haxe interpreter with a runtime compiler. It parses Haxe-shaped source and evaluates it directly,
with enough of the language intact that a script can declare classes, enums, typedefs and
abstracts, and extend the ones your application already compiled.

It can also **compile a script to native bytecode while your application is running**, with no Haxe
toolchain anywhere in sight, which is worth around 20x. See
[compiling at runtime](#compiling-at-runtime).

Two things it is for:

- **A scripting language for your application.** Ship a program that loads `.hx` files at runtime, so
  users can add content or behaviour without rebuilding, and without learning a second language.
- **Prototyping.** Iterate on logic without a compile cycle, in the language you are already
  writing, then move the parts that settled into compiled code unchanged.

It runs **typed by default**: declared types on variables, parameters, returns and `cast(x, T)` are
enforced as values pass through them. That is the main thing separating it from the interpreters it
descends from, and it means a script fails where Haxe would reject it rather than several frames
later somewhere unrelated.

```haxe
import hxscript.Script;

// Note the DOUBLE-quoted host string: a single-quoted one would interpolate `$name`
// in your own code, before the script ever sees it.
var script = new Script("
    class Greeter {
        var name:String;
        public function new(name:String) this.name = name;
        public function greet() return 'hello, $name!';
    }

    function run() {
        var g = new Greeter('world');
        trace(g.greet());
    }
", 'MyScript');

script.start();
script.call('run');   // MyScript:10: hello, world!
```

## Install

```
haxelib install hxscript
```

or track the repository, for the unreleased state:

```
haxelib git hxscript https://github.com/MeguminBOT/hxscript
```

Then `-lib hxscript` in your hxml, or `<haxelib name="hxscript" />` in a `Project.xml`. **That is the
whole of the setup, including for the game library you are already using.** If the build has flixel,
openfl, lime or heaps in it, hxScript notices and does the four things a script needs before it can
touch them: force-compiles their packages so scripts can name the types, generates a bridge per
class scripts may `extend`, gives their abstracts a runtime form so `BlendMode.ADD` means something,
and registers emulations for the `inline` members that have no runtime form to call. None of it is
mentioned in your build file, and a library it does not know is
[a record you write once](docs/advanced.md#4-adding-a-game-library).

```
-lib hxscript
-lib flixel        # this line is also the flixel scripting setup
```

Errors say where and why. A parse error quotes the line with a caret under the column; an unknown
name says whether it is missing from the build or only from the script's scope, and prints the
`import` to add; a call that resolved to nothing says whether the member is misspelled or `inline`.

The [embedding guide](docs/embedding.md) covers the rest, from exposing your API to letting scripts
subclass your classes, along with the things that will bite you.

Two worked examples, both runnable: [`examples/battle/`](examples/battle) is a small turn-based RPG
whose creatures, bosses and status effects are all scripts, and
[`examples/workbench/`](examples/workbench) is a coding environment where you write, test and run
any number of scripts with no rebuild. The program it ships is a playable game written entirely in
script.

And one application: [`apps/sandbox/`](apps/sandbox) is a prototyping tool for lime, openfl and
flixel, where a project is a folder of `.hx` files it reads at runtime. Drop a folder in, press Run,
edit, save, watch it reload.

## How it differs from hscript

[hscript](https://github.com/HaxeFoundation/hscript) is a small, fast expression interpreter. It
evaluates Haxe-shaped expressions and does that well; what it does not do is let a script declare
*types*, or bring the module-level language along with them.

| | hscript | hxScript |
| --- | --- | --- |
| expressions, functions, closures | yes | yes |
| **declaring classes in a script** | no | yes, including `extends` on your compiled classes |
| enums, typedefs, abstracts, module-level fields | no | yes, scripted or imported from compiled code |
| `import` / `using` | no | yes, incl. `as` aliases, `.*` wildcards, single fields |
| string interpolation (`'v$n'`) | no | yes |
| pattern matching | basic `switch` | extractors, guards, captures, struct and array patterns |
| property accessors (`var x(default, set)`) | no | yes |
| type annotations | parsed, ignored | **enforced at runtime** |
| `Int` / `Float` distinction | blurred by `Dynamic` | preserved (`/` is always `Float`) |
| errors | message | call stack across scripts and into the host |
| **compiling to native bytecode** | no | yes, at runtime, from source text |

The hscript column reflects 2.7.0, the version the benchmark suite actually ran; the absence of
scripted classes and of single-quote interpolation are both recorded in
[benchmarks.md](docs/benchmarks.md), which puts six libraries in this family through identical
scripts. That page is worth reading before picking one. hxScript carries the largest language
surface and pays for it per operation, while being several times faster per *call*, because it
signals `return` and `break` with flags where the others throw exceptions. Neither number is the
whole story, and "fastest" depends entirely on which of the two your scripts do more of.

## Haxe parity

The useful question is not "is it Haxe" but "which Haxe does it reach". It is a tree-walking
interpreter, so what needs the *compiler* is gone and what needs only runtime values is there.

| Works with parity | Erased or weakened | Not available |
| --- | --- | --- |
| classes, `extends`, `override` | type parameters (erased to `Dynamic`) | macros, `@:build`, reification |
| scripted and native interfaces | structural typedefs (values, not literals) | compile-time type errors, inference |
| enums with params, `switch` extraction, guards | custom metadata (mostly inert) | overload resolution |
| abstracts: `@:op`, `@:arrayAccess`, `from`/`to` | `private` enforcement (opt-in) | `@:structInit`, `@:multiType` |
| typedef aliases | `untyped` (a no-op) | overriding native `inline` / `final` |
| statics, properties, getters and setters | | interface default methods |
| `using`, `import`, string interpolation | | compile-time inlining, DCE |
| comprehensions, optional / default / rest args | | |
| typed multi-catch, closures, `#if` | | |
| runtime type enforcement, `Int`/`Float` correctness | | |

[parity.md](docs/parity.md) is the long form: what each boundary is, why it is there, and where in
the source it lives. The short version of the last column is that a macro runs *in* the compiler and
there is no compiler at runtime; type parameters are erased by Haxe itself before the interpreter
ever sees them; and an `inline` method has no runtime representation to override.

Type mismatches surface as runtime throws rather than compile errors. That catches the same
mistakes, just later. There is no static checker yet, and adding one is real work rather than a
missing flag.

## The language surface

A tour of the parts that are not obvious. Everything here runs.

**Scripted types.** Classes, enums, typedefs, abstracts and module-level fields can all be declared
in a script. To let scripts subclass one of *your* classes, extend it and implement the marker
interface:

```haxe
class ScriptedThing extends BaseThing implements hxscript.IScripted {}
```

**Typed mode.** On by default; `Config.typedMode = false` or `-D hxscript_dynamic` turns it off.

```haxe
var x:Int = 5;        // ok
var y:Int = 3.5;      // throws: 3.5 should be Int
var f:Float = 5;      // ok, widened
trace(cast(5, Int));  // a real checked cast
trace(5 is Int);      // true, primitives work as targets
```

**Abstracts**, scripted or compiled. Compiled ones need
`@:build(hxscript.macro.Abstract.build())`, and an explicit cast to reach the abstract type:

```haxe
var color:FlxColor = cast 0xff0040;
color.green = FlxColor.GREEN.green;
```

**Imports and static extension**, as in Haxe:

```haxe
import sys.*;
import Reflect.getProperty as get;
using Lambda;
```

**Pattern matching**, with captures, extractors, guards and struct or array patterns:

```haxe
switch (struct) {
    case {name: a, rating: b}: '$a is $b';
    default: 'no match';
}
```

**Also**: string interpolation with nesting, regex literals (`~/hx/i`), map and array comprehension,
property accessors, rest and optional arguments, `#if` with comparisons against real compilation
defines, and field access on any compiled type without importing it first.

**Errors** carry a call stack across script boundaries and into the host, rather than a bare message:

```
Exception: ouch...
Called from test/TestScript.hxs.crash (test/TestScript.hxs line 2 column 8)
Called from script test/TestScript.hxs (test/TestScript.hxs line 4 column 1)
Called from Main.main (Main.hx line 10 column 3)
```

[`Config`](src/hxscript/Config.hx) sets the global behaviour: proxying or blacklisting types, modules and
packages, swapping the interpreter class, preprocessor values for conditionals, and predefined
variables and imports.

## Compiling at runtime

Scripts are interpreted by default. A module can instead be translated to
[cppia](https://haxe.org/manual/target-cppia.html), hxcpp's own bytecode, and loaded as a real
`Class<Dynamic>`, worth about **21x per operation** and **37x per call**, rising to about **30x** and
**104x** with hxcpp's JIT enabled on top.

```haxe
// once, at startup: marks on your own types say where your API lives
hxscript.macro.Expose.apply();

// once per world
var report = hxscript.compile.Compiler.compile(env);
trace('${report.compiled.length} compiled, ${report.skipped.length} interpreted');
```

Needs `-D hxscript_cppia` here and `-D scriptable` on the host. It is decided per module: whatever
the emitter cannot express is reported with a reason and left to the interpreter, so turning it on
cannot break a script that was working. `Cppia.compile` is underneath if you want to drive it
yourself, whether to compile a subset or to cache the bytecode on disk between launches.

**Haxe can emit cppia too, but only as a build step.** That is the difference this is for. Haxe's
path compiles a `.hx` file ahead of time, against a snapshot of your host's classes, on a machine
with the Haxe compiler installed, so it cannot compile a script that did not exist when you
shipped. This translates source text in-process, at load, with nothing installed, which is what makes
it work for mods, in-app editors and anything else a user writes after the fact. The same text still
runs interpreted, unchanged, so it is a flag rather than a second pipeline.

Where both can compile the same script, expect Haxe's output to be faster: it type-checks and
optimises, and this is a direct translation with no optimisation passes and a smaller language
subset.

**It is new**, and younger than the rest of the library. What it rests on is
[`test/SweepTest.hx`](test/SweepTest.hx), which runs 33 constructs interpreted and compiled and
compares the answers, currently 0 refused and 0 wrong, plus a differential suite that does the same
for the language surface. Three wrong-answer bugs were found that way during the work, which is both
the reason to trust it as far as you do and the reason not to trust it further.

[modes.md](docs/modes.md) is the full comparison and the guidance on when compiling repays what it
costs; [mode-benchmarks.md](docs/mode-benchmarks.md) is where the figures come from.

## Documentation

- **[Embedding guide](docs/embedding.md)** puts the library in a project, worked end to end in
  [`examples/battle/`](examples/battle).
- **[Macros, a custom interpreter, and binding your API](docs/advanced.md)** covers generating bridges,
  making native abstracts visible, subclassing `Interp`, and every surface for handing your API over.
- **[Execution modes](docs/modes.md)** covers interpreting, compiling at runtime, or compiling and
  jitting: how runtime translation differs from Haxe's own cppia, what each needs from your build,
  and when compiling repays what it costs.
- [Parity with Haxe](docs/parity.md) sets out what scripts can and cannot do, and why.
- [Performance](docs/performance.md) covers what has been optimised, and how to measure without
  fooling yourself.
- [Benchmarks](docs/benchmarks.md) puts six libraries in this family through identical scripts.
- [Mode benchmarks](docs/mode-benchmarks.md) runs the same corpus interpreted, compiled and jitted.
- [Static checking](docs/checker.md) sets out the design for a pre-run checker, and its limits.
- [Internals](docs/internals.md) explains why the parts that are not obvious are the way they are,
  keyed by the file and symbol each note belongs to.
- [Examples](examples): [`battle/`](examples/battle) embeds the library in a game;
  [`workbench/`](examples/workbench) writes the whole program in script.
- [Apps](apps): [`sandbox/`](apps/sandbox) is a prototyping tool for lime, openfl and flixel.
- [Tests](test) holds the suites, which double as executable documentation of behaviour.

## To-do

Implemented, unless listed as not done below.

**Compiled types**: abstracts (statics, instance fields, `from`/`to`, `@:op`, `@:arrayAccess`,
`@:forward`), enum abstracts, enums with constructor arguments, typedefs (alias, and anonymous
structure checked by field name *and* field type), module-level fields.

**Scripted types**: classes (extending scripted or compiled classes, property accessors, `toString`,
iterators and iterables), enums, typedefs, module-level fields, abstracts (boxed underlying value,
constructor, methods, properties, statics, `from`/`to`, operators, enum abstracts, `@:forward`).

**Typed mode**: runtime enforcement on variables, arguments, returns and `cast`; primitives as
`is`/`cast` targets; `Int`/`Float` numeric correctness; container and function-type checking;
structural typedef shape checking; `private` access enforcement. A class or static field declared
with a type binds exactly as the identical local does, so an abstract-typed field boxes.

**Static extensions**: a `using` on a script-declared class registers, and the receiver is checked
against the extension's first parameter, so several extensions can share a method name. Compiled
extensions still cannot be checked. See below.

**Printing**: `Printer` prints every module declaration, and printing round-trips through a reparse.

**Runtime compilation**: a module translates to cppia bytecode in-process and loads as a real class,
gated on `-D hxscript_cppia`, per module, with anything it cannot express reported and left to the
interpreter.

Not done:

- [ ] **A script type cannot share a short name with a host type across modules.** Its own module
      resolves it correctly; another module in the same batch gets the host's, since the emitter
      keeps no per-module import table for other people's modules.

- [ ] **Static checking before a script runs.** Designed but not built: see
      [checker.md](docs/checker.md) for what it could prove without inference, what it could not, and
      why the boundary sits there.
- [ ] **Call-stack frames across interpreters.** A method declared in a module runs on that module's
      interpreter, and each interpreter owns its own stack with no link to its caller, so the frame
      does not appear in the calling script's trace. Errors themselves now carry their frames
      wherever they are reported; this is the remaining half.

## Impossible to add

Not "not yet": these need information that stops existing once the Haxe compiler has finished, so no
amount of emulation inside a runtime interpreter recovers it.

- **Macros, `@:build` and reification in scripts.** A macro runs *in* the Haxe compiler, and that is
  not what runs at runtime. The bytecode compiler above translates a script; it does not evaluate
  macros, and could not, because a macro expects the compiler's own API and type information.
- **Compile-time type errors and inference.** The interpreter sees values, not the types of
  expressions that have not run yet. A static checker over the AST could catch some before running;
  that is the to-do above, and it is a different thing from inference.
- **Generic type safety.** Type parameters are erased by the Haxe compiler itself, so at runtime
  `Array<Int>` and `Array<String>` are the same type. Nothing can tell them apart.
- **`@:multiType`.** Choosing an implementation from a type parameter is a compile-time decision.
  `Map` works only because it is special-cased on the key's runtime value.
- **Type-checking `using` extensions on compiled classes.** A compiled static's parameter types do
  not exist at runtime, so the first argument cannot be checked against them. Extensions declared in
  a script can be checked, because their declarations are still around.
- **Overriding a native `inline` or `final` method.** An `inline` method has no runtime
  representation to override, and a `final` one is devirtualised at the call site. Calls to them can
  be emulated with `Config.callShims`; overriding them cannot.

## Lineage

A fork of [inky03/hscript-insanity](https://github.com/inky03/hscript-insanity), itself an
experimental fork of [hscript](https://github.com/HaxeFoundation/hscript). hscript-insanity drew on
[hscript-iris](https://github.com/pisayesiwsi/hscript-iris) and
[RuleScript](https://github.com/Kriptel/RuleScript); both are worth a look, and both are in the
benchmark comparison.

What hxScript adds on top of hscript-insanity: type annotations enforced at runtime, with
`-D hxscript_dynamic` to opt out and `Int` versus `Float` kept correct either way; abstracts that
work, scripted or compiled, including operators, array access and `from`/`to`; structural typedefs
checked by field *type* rather than by name alone; documentation and a runnable example rather than
a feature list; interpreter performance work that was measured rather than assumed; and a compiler
that translates a script to cppia bytecode at runtime.

Still a work in progress. The to-do above says what is missing, and
[parity.md](docs/parity.md) is honest about where scripts diverge from real Haxe. Pull requests
welcome at [hxScript](https://github.com/MeguminBOT/hxscript/pulls).
