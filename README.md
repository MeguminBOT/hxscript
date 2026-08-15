# hxScript

[![haxelib](https://badgen.net/haxelib/v/hxscript?label=haxelib&color=orange)](https://lib.haxe.org/p/hxscript)
[![downloads](https://badgen.net/haxelib/d/hxscript?label=downloads)](https://lib.haxe.org/p/hxscript)
[![license](https://badgen.net/github/license/MeguminBOT/hxscript)](LICENSE)
[![last commit](https://badgen.net/github/last-commit/MeguminBOT/hxscript)](https://github.com/MeguminBOT/hxscript/commits/main)
[![stars](https://badgen.net/github/stars/MeguminBOT/hxscript)](https://github.com/MeguminBOT/hxscript/stargazers)
[![Haxe](https://badgen.net/badge/Haxe/4.3+/orange)](https://haxe.org/)

**An advanced Haxe interpreter.**

It parses Haxe-shaped source and evaluates it directly, with enough of the language intact that a
script can declare classes, enums, typedefs and abstracts, and extend the ones your application
already compiled. The interpreter is plain Haxe and builds on every target; see
[Status](#status) for where that is exercised rather than only compiled.

**On hxcpp and HashLink** it can also translate a script to native bytecode while your application
is running, with no Haxe toolchain anywhere in sight. That part needs a target with bytecode of its
own: hxcpp has cppia, and HashLink has its own, each reached through a backend of its own.

It began as a fork of [hscript-insanity](https://github.com/inky03/hscript-insanity), itself a fork
of [hscript](https://github.com/HaxeFoundation/hscript), and has since grown into its own thing:
runtime type enforcement, working abstracts, a diagnostic channel, and a bytecode compiler with a
backend for hxcpp and one for HashLink. See [lineage](#lineage) for what came from where.

```haxe
import hxscript.Script;

// Note the DOUBLE quotes: a single-quoted host string would interpolate `$name`
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

## What it is for

- **A scripting language for your application.** Ship a program that loads `.hx` files at runtime, so
  users can add content or behaviour without rebuilding, and without learning a second language.
- **Prototyping.** Iterate on logic without a compile cycle, in the language you are already writing,
  then move the parts that settled into compiled code unchanged.

## Install

```
haxelib install hxscript
```

or track the repository, for the unreleased state:

```
haxelib git hxscript https://github.com/MeguminBOT/hxscript
```

Then `-lib hxscript` in your hxml, or `<haxelib name="hxscript" />` in a `Project.xml`.

**That is the whole of the setup, including for the game library you already use.** If the build has
flixel, openfl, lime or heaps in it, hxScript notices and does the four things a script needs before
it can touch them: force-compiles their packages so scripts can name the types, generates a bridge
per class scripts may `extend`, gives their abstracts a runtime form so `BlendMode.ADD` means
something, and registers emulations for the `inline` members with no runtime form to call.

```
-lib hxscript
-lib flixel        # this line is also the flixel scripting setup
```

None of that is mentioned in your build file, and a library it does not know is
[a record you write once](docs/advanced.md#4-adding-a-game-library). To let scripts reach your *own*
classes, mark them and name their package:

```xml
<haxedef name="hxscript_host" value="game" />
```

```haxe
@:scriptable      // scripts may extend it
class Entity { ... }

@:scriptAmbient   // scripts may name it without importing it
class Api { ... }
```

The [embedding guide](docs/embedding.md) covers the rest, and lists every build flag, every mark and
every runtime setting.

## Errors say where and why

A parse error quotes the line with a caret under the column. An unknown name says whether it is
missing from the build or only from the script's scope, and prints the `import` to add. A call that
resolved to nothing says whether the member is misspelled or `inline`.

```
Playground.hx:42: character 17
  var x = foo(;
              ^
Unexpected token ';'
```

Errors carry a call stack across script boundaries and into the host, rather than a bare message:

```
Exception: ouch...
Called from test/TestScript.hxs.crash (test/TestScript.hxs line 2 column 8)
Called from script test/TestScript.hxs (test/TestScript.hxs line 4 column 1)
Called from Main.main (Main.hx line 10 column 3)
```

## How it compares to hscript

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
| **compiling to native bytecode** | no | yes, at runtime, from source text, on hxcpp and HashLink |

The hscript column reflects 2.7.0, the version the benchmark suite ran.
[benchmarks.md](docs/benchmarks.md) puts six libraries in this family through identical scripts and
is worth reading before picking one. hxScript carries the largest language surface and pays for it
per operation, while being several times faster per *call*, because it signals `return` and `break`
with flags where the others throw exceptions. Which of those matters depends on what your scripts do
more of.

## What scripts can do

It is a tree-walking interpreter, so what needs the *compiler* is gone and what needs only runtime
values is there.

| Works like Haxe | Parses, but weaker | Not available |
| --- | --- | --- |
| classes, `extends`, `override` | type parameters, erased to `Dynamic` | macros, `@:build`, reification |
| scripted and native interfaces | structural typedefs check values, not literals | compile-time type errors, inference |
| enums with parameters, `switch` extraction, guards | custom metadata, mostly inert | overload resolution |
| abstracts: `@:op`, `@:arrayAccess`, `from`/`to` | `private`, only where written explicitly | `@:structInit`, `@:multiType` |
| typedef aliases | `untyped`, a no-op | overriding a native `inline` or `final` method |
| statics, properties, getters and setters | `final` and `abstract` on a class, recorded but not enforced | interface default methods |
| `using`, `import`, string interpolation | | compile-time inlining, DCE |
| comprehensions, optional / default / rest args | | |
| typed multi-catch, closures, `#if` | | |
| runtime type enforcement, `Int`/`Float` correctness | | |

**Typed by default.** Declared types are enforced as values pass through them, which is the main
thing separating this from the interpreters it descends from. A script fails where Haxe would reject
it, rather than several frames later somewhere unrelated.

```haxe
var x:Int = 5;        // ok
var y:Int = 3.5;      // throws: Float should be Int
var f:Float = 5;      // ok, widened
trace(cast(5, Int));  // a real checked cast
trace(5 is Int);      // true, primitives work as targets
```

`Config.typedMode = false`, or `-D hxscript_dynamic`, turns it off.

The last column is not a to-do list. A macro runs *in* the compiler and there is no compiler at
runtime; type parameters are erased by Haxe itself before the interpreter ever sees them; and an
`inline` method has no runtime representation to override.
[parity.md](docs/parity.md) is the long form, including where each boundary lives in the source.

## Compiling at runtime

**Where the target has bytecode of its own.** Scripts are interpreted everywhere by default. On
hxcpp a module can instead be translated to [cppia](https://haxe.org/manual/target-cppia.html),
hxcpp's own bytecode, and loaded as a real `Class<Dynamic>`, worth about **21x per operation** and
**37x per call**, rising to about **30x** and **104x** with hxcpp's JIT on top. On HashLink a second
backend emits HashLink bytecode and loads it into the running process, where the VM's own JIT takes
it.

```haxe
var report = hxscript.compile.Compiler.compile(env);
trace('${report.compiled.length} compiled, ${report.skipped.length} interpreted');
```

Needs `-D hxscript_cppia` here and `-D scriptable` on the host, or `-D hxscript_hl` for HashLink.
It is decided per module: whatever the emitter cannot express is reported with a reason and left to
the interpreter, so turning it on cannot break a script that was working.

**Haxe can emit cppia too, but only as a build step.** That is the difference this is for. Haxe's
path compiles a `.hx` file ahead of time, against a snapshot of your host's classes, on a machine
with the compiler installed, so it cannot compile a script that did not exist when you shipped. This
translates source text in-process, at load, with nothing installed, which is what makes it work for
mods, in-app editors and anything a user writes after the fact. Where both can compile the same
script, expect Haxe's output to be faster: it type-checks and optimises, and this is a direct
translation with no optimisation passes.

**It is the newest part of the library.** What it rests on is a shared conformance corpus of 329
constructs, run in six columns, one per way of executing a script: interpreted on eval, hxcpp and
HashLink, and compiled as cppia with and without the JIT and as HashLink bytecode. Every compiled
column currently agrees with its own target's interpreter on all 329 and refuses none of them, and
[`support-table.md`](docs/support-table.md) is that reading, regenerated rather than written.
Several wrong-answer bugs were found this way, which is both the reason to trust it as far as you do
and the reason not to trust it further.

[modes.md](docs/modes.md) is the full comparison and the guidance on when compiling repays what it
costs; [mode-benchmarks.md](docs/mode-benchmarks.md) is where the figures come from.

## Try it

Two worked examples and two applications, all runnable:

- [`examples/battle/`](examples/battle) is a small turn-based RPG whose creatures, bosses and status
  effects are all scripts. Its whole integration is one short file.
- [`examples/workbench/`](examples/workbench) is a coding environment where you write, test and run
  any number of scripts with no rebuild. The program it ships is a playable game written entirely in
  script.
- [`apps/sandbox/`](apps/sandbox) is the **hxScript Sandbox: Lime HXCPP**, a prototyping tool for
  lime, openfl and flixel where a project is a folder of `.hx` files it reads at runtime. Drop a
  folder in, press Run, edit, save, watch it reload.
- [`apps/sandbox-heaps/`](apps/sandbox-heaps) is the same idea on heaps and HashLink, and is where
  the 3D half is exercised: it ships seven of the heaps samples as examples plus a first-person
  shooter whose physics is tested without opening a window, and it drives the conformance projects
  that check a real project's interop interpreted against compiled.

## Documentation

- **[Embedding guide](docs/embedding.md)** puts the library in a project, and lists every flag, mark
  and setting.
- **[Macros, a custom interpreter, and binding your API](docs/advanced.md)** covers generating
  bridges, making native abstracts visible, and subclassing `Interp`.
- **[Execution modes](docs/modes.md)** covers interpreting, compiling and jitting, and when each pays.
- [Parity with Haxe](docs/parity.md) sets out what scripts can and cannot do, and why.
- [Performance](docs/performance.md) covers what has been optimised, and how to measure without
  fooling yourself.
- [Benchmarks](docs/benchmarks.md) puts six libraries in this family through identical scripts.
- [Mode benchmarks](docs/mode-benchmarks.md) runs the same corpus interpreted, compiled and jitted.
- [HashLink benchmarks](docs/hl-benchmarks.md) runs it against the same program compiled by Haxe,
  which is what a script costs against not scripting it at all.
- [Static checking](docs/checker.md) sets out the design for a pre-run checker, and its limits.
- [Internals](docs/internals.md) explains why the parts that are not obvious are the way they are.
- [Tests](test) holds the suites, which double as executable documentation of behaviour.
- [Changelog](CHANGELOG.md) has what changed per release, including the renames 2.0.0 asks you
  to follow.

## Status

Working, and in use. What is known to be missing:

- [ ] **A script type cannot share a short name with a host type across modules.** Its own module
      resolves it correctly; another module in the same batch gets the host's, since the emitter
      keeps no per-module import table for other people's modules.
- [ ] **Static checking before a script runs.** Designed but not built: see
      [checker.md](docs/checker.md) for what it could prove without inference, what it could not, and
      why the boundary sits there.
- [ ] **Call-stack frames across interpreters.** A method declared in a module runs on that module's
      interpreter, and each interpreter owns its own stack with no link to its caller, so that frame
      does not appear in the calling script's trace. Errors themselves carry their frames wherever
      they are reported; this is the remaining half.

**Targets.** The suite builds on all nine and runs on four of them.

| | built | suite runs | result |
| --- | --- | --- | --- |
| eval, cpp | yes | yes | pass in full |
| neko, python | yes | yes | a handful of scripted-abstract cases fail |
| js, java, lua, php, hl | yes | no runtime here | compile and generate only |

The bytecode compiler needs a target with bytecode of its own, hxcpp or HashLink, and passes in
full on both. What neko and python fail, and why, is in
[`test/known-failing.txt`](test/known-failing.txt).

## Lineage

A fork of [inky03/hscript-insanity](https://github.com/inky03/hscript-insanity), itself an
experimental fork of [hscript](https://github.com/HaxeFoundation/hscript). hscript-insanity drew on
[hscript-iris](https://github.com/pisayesiwsi/hscript-iris) and
[RuleScript](https://github.com/Kriptel/RuleScript); both are worth a look, and both are in the
benchmark comparison.

What hxScript added on top of hscript-insanity, and what makes it a separate library rather than a
fork with patches:

- type annotations enforced at runtime, with `-D hxscript_dynamic` to opt out, and `Int` versus
  `Float` kept correct either way;
- abstracts that work, scripted or compiled, including operators, array access and `from`/`to`;
- structural typedefs checked by field *type* rather than by name alone;
- one diagnostic channel for every phase, carrying the position, the source line and a likely cause;
- automatic setup for the game library already in your build;
- a compiler that translates a script to cppia or HashLink bytecode at runtime;
- interpreter performance work that was measured rather than assumed.

Pull requests welcome at [hxScript](https://github.com/MeguminBOT/hxscript/pulls).
