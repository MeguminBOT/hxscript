# Changelog

## 2.0.0

### Breaking: renamed modules

Every one of these is a rename or a move. The behaviour is unchanged, so a host updates the name and
carries on. Sorted by how likely you are to have written it.

| Was | Now | You wrote it if you |
| --- | --- | --- |
| `hxscript.macro.AbstractMacro` | `hxscript.macro.Abstract` | made a native abstract scriptable with `@:build` |
| `hxscript.macro.ExposeMacro` | `hxscript.macro.Expose` | called `Expose.apply()` or `Expose.expose([...])` |
| `hxscript.runtime.InterpException` | `hxscript.error.InterpException` | caught a script failure by type |
| `hxscript.runtime.ParserException` | `hxscript.error.ParserException` | caught a parse failure by type |
| `hxscript.runtime.Error` | `hxscript.error.ErrorKind` | matched on an error kind |
| `hxscript.ImportModule` | `hxscript.runtime.ImportModule` | used a shared prelude module |
| `hxscript.compile.Cppia` | `hxscript.cppia.Backend` | called the cppia emitter rather than `Compiler` |
| `hxscript.compile.CppiaInput` | `hxscript.compile.Unit` | drove the cppia emitter yourself |
| `hxscript.compile.CppiaResult` | `hxscript.compile.Result` | drove the cppia emitter yourself |
| `hxscript.runtime.CallStack` | `hxscript.runtime.ScriptStack` | typed a variable as the interpreter's stack |

Internals renamed at the same time, unlikely to appear in a host: `CppiaEmitter` and `CppiaWriter`
drop their prefix and move to `hxscript.cppia`, beside the backend; `CppiaCapture` and
`CppiaUnsupported` drop theirs and stay in `hxscript.compile`, being shared with the second backend;
`KeepMacro`, `ScriptedMacro` and `TypeCollectionMacro` become `Keep`, `Scripted` and `Index`;
`HLMacro` becomes `Statics` and `proxy.HLMath` becomes `proxy.MathProxy`; `runtime.Mirror` becomes
`runtime.Reference`;
`types.DummyClass` becomes `types.ScriptedObject`; `tools.Tools` splits into `syntax.ExprTools` and
`types.TypeTools`, and `tools.Defines` moves to `setup.Defines`.

`Script`, `Environment`, `Module`, `Config`, `IScripted`, `Interp`, `ScriptedClass` and
`compile.Compiler` keep their names.

### Breaking for scripts, if you tracked the repo rather than releases

Three helpers are reachable from a script by a bare name, with no import, because the presets list
them in `globals`. They were renamed with everything else, so a script written against the repo
between 1.1.2 and now needs the new name. Nothing that shipped in 1.1.2 had them.

| Script wrote | Now writes |
| --- | --- |
| `Decode.toIntArray(...)` | `BytesTools.toIntArray(...)` |
| `Upload.quads(...)` | `TriangleTools.quads(...)` |
| `Encode.sound(...)` | `SoundTools.sound(...)` |

The failure is `Unknown identifier: Decode` at the call site, and under the bytecode compiler the
module holding it is reported as `unresolved identifier` and left interpreted, along with everything
that names it.

### Added

- **A second compiler backend, for HashLink.** The same declarations emitted as HashLink's own
  bytecode and loaded into a running process, under `hxscript.hl`. Bytecode compiling was hxcpp-only
  before this; it now needs only a target with bytecode of its own, and HashLink is the second.
  `-D hxscript_hl` is the whole of what a host writes: the VM's loader is compiled into `hl.exe`
  rather than into `libhl`, so the library carries the loader sources and the same macro builds the
  native module the backend needs, `hxscript.hdll` beside a `.hl` or linked in for HL/C. It is
  skipped when one is already there and was built for the same HashLink, recorded beside it rather
  than guessed from timestamps, because an upgraded VM leaves a module whose struct offsets are
  silently wrong. Nothing about it can fail a build: with no HashLink, no C compiler, or a version
  the carried loader does not match, you get one warning and every script is interpreted.
  HashLink jits what it loads, so there is no separate jitted mode the way there is on hxcpp.
- **One conformance corpus, six columns, and a table written from what came back.** `sh test/all.sh`
  runs every suite and reports by part rather than by file. The middle suite is the interesting one:
  332 constructs offered to six ways of running a script, interpreted on eval, hxcpp and HashLink,
  and compiled as cppia with and without the JIT and as HashLink bytecode, so that a part of the
  language working in one and not another is visible rather than inferred. `docs/support-table.md`
  is regenerated from those columns, never edited. A case that ends the process is recorded as
  `killed` and the run resumes past it, which is not a detail: hxcpp's cppia has taken the process
  down more than once, and losing that reading is worse than losing the case.
- **`apps/sandbox-heaps`**, the heaps sandbox, as a native HashLink binary: the same
  folder-of-`.hx`-files idea as the lime sandbox, on heaps, and where the 3D half is exercised.
  Nine project templates, seven of the heaps samples ported as examples listed apart from your own
  projects, and a first-person shooter whose physics is tested without opening a window. A project's
  assets are read from disk when it runs rather than baked in when it is built, and scripts reach
  the gamepad and the pointer that heaps already carried.
- **Your own classes, without writing a bridge.** Mark a class `@:scriptable` and name its package
  with `-D hxscript_host=<packages>`, and the bridge is generated. A hand-written bridge and
  `--macro include('bridges')` still work and are still the answer for a base in a library you do not
  own. `@:scriptAmbient` and `@:scriptStatic` are read from the same scan.
- **One diagnostic channel.** Parsing, building a type, running and compiling all report to
  `hxscript.error.Sink` as a `Diagnostic` carrying the origin, line, column, the source line it
  happened on and a likely cause. `Sink.listen` takes them over for a host with a window rather than
  a terminal.
- **Automatic setup for the game library already in your build.** `-lib hxscript` beside lime,
  openfl, flixel, flixel-addons, flixel-ui or heaps force-compiles their packages, generates the
  bridges, gives their abstracts a runtime form and registers emulations for members with no runtime
  form. `-D hxscript_verbose` prints what it did.
- **`apps/sandbox`**, the hxScript Sandbox, Lime HXCPP edition: a prototyping tool for lime, openfl
  and flixel whose projects are folders of `.hx` files read at runtime.
- **Per-library shim packages**: `hxscript.stdlib`, `hxscript.flixel`, `hxscript.openfl` and
  `hxscript.python` hold the closures standing in for members a target cannot reflect on.
- **heaps ships as two presets, so a 2D project can stop paying for the scene graph.** `heaps` is
  the 2D half and `heaps3d` the 3D one; both arrive with `-lib heaps` and nothing changes by
  default. `-D hxscript_setup_skip=heaps3d` drops the second: eleven bridges become two, and the
  sandbox binary goes from 8.68 MB to 7.56 MB. `h3d.Vector`, `h3d.Matrix` and `h3d.mat.Texture` stay
  in the 2D half, because `h2d.Drawable` and `h2d.Tile` name them. A `Library` record can now say
  `requires` where the define that switches it on is not its own name, which is what lets a preset
  describe half of a library.
- **A constructor call short in the middle is placed by type, the way Haxe places it.**
  `new Mesh(prim, parent)` against `(primitive, ?material, ?parent)` means the first parameter and
  the last, and binding it in order put the parent in the material and failed on a cast naming two
  types the script never wrote. It is the shape every scene graph is built on, so a 3D project could
  not be written without knowing to pass the `null` itself. The build's type table now records the
  parameters of the constructors this can matter for, and `new` and `super(...)` ask.
  `hxscript.types.ArgumentTools` answers with the call unchanged wherever it cannot be certain, so
  nothing that worked before is placed differently now. It also unwraps a boxed abstract on the way
  into a constructor, which every other call had always done.

### Fixed

Five portability faults, each one a target answering a reflection question differently:

- `for` over an interval or an iterator returned null on neko, because the loop pulled `hasNext` and
  `next` out with `Reflect.field` and called them unbound.
- The bridge table was built in a static initializer, which on python runs before `python.Boot` has
  its own statics, so every lookup returned null and the library looked installed and inert.
- `v is Class` is false for python's builtins, so import registration and `cast` skipped every branch
  meant for a class.
- `AbstractTools.resolveName` reported `unknown` for a scripted abstract.
- A registered shim now wins over reflection for a static call, since a shim exists precisely because
  reflection is unreliable for that member.

Neko went from 287 to 370 passing and python from 38 to 367. php, js, lua and hl build again.

Then a set found by running real projects rather than by reading the code, most of them where a
script meets the host:

- A closure naming something of the class around it resolved to nothing, so `hit.onClick =
  function(e) tapped();`, the most ordinary line in an interface, did not compile. The instance is
  captured now.
- A host property was written past rather than through: assigning to one stored the value and never
  ran the setter.
- A bridge could collide with itself, and a base named in full was not recognised as the same type
  as the base named short, so extending one dropped the bridge.
- A host abstract's forwarded members were unreachable from compiled code, and a host enum reached
  through a short name had no constructor built for it.
- An import binding a static rather than a type (`import HostDial.step;`) was recorded as a type, so
  the name evaluated to null where the interpreter gave the field's value.
- A typed array's elements were read back as something other than what the annotation promised,
  which reinterprets memory rather than misbehaving.
- A `break` or `continue` leaving a `try` did not give its trap back.
- A wildcard import reached nothing a package declared, because the filter that keeps a module's main
  type compared the whole module path against the type's name.
- An integer result stored where a float goes was not converted, and `Int` arithmetic that overflows
  now has one answer rather than one per mode.
- A world that failed to start died silently instead of reporting it.

### Compiler and parser

- **A type in the module's own package resolves with no import**, the way Haxe resolves one. Naming
  a sibling module used to reach nothing, and the failure surfaced at the first use rather than at
  the name (`Invalid access to field` interpreted, `Cannot call` compiled), so both sides failed
  alike and it read as an unsupported construct rather than as a defect. Every module of a packaged
  project had to import its own siblings. Imports are still read first, so an explicit import of
  another package's type of the same name still wins.
- **An enum's constructors are bound when its type is imported on hxcpp.** A class and an enum are
  one runtime object there, so `t is Class` was true of an enum and took it down the class branch:
  `import haxe.ds.Option;` bound `Option` and neither `Some` nor `None`, and a bare `None` read
  whatever else was in scope under that name. This was the one case where two interpreters answered
  differently on different targets.
- **cppia refuses nothing in the conformance corpus**, down from 19 of 332 cases, with no case
  answering differently. Three causes: constructing an abstract the host compiled, which has no
  runtime class for a `NEW` to name and is now built through `hxscript.runtime.Construct`; a
  constructor call short of an optional in the middle, now placed by type rather than padded from
  the right into the wrong parameter; and a host name the module never imported, now resolved
  through the world's type table. Boxed abstracts also reach `Std.string` and their `@:op` methods
  from compiled code, which is what construction working made reachable.
- More constructs compile that used to be refused: `super.m` as a value, a local declared with
  property accessors, a static extension whose receiver type is only known at run time, a scripted
  abstract's operators (with what they return), optional arguments and their defaults, and the `is`
  operator. A typedef is emitted as the class it aliases rather than as itself, since a typedef has
  no runtime class and cppia resolved the name to null and then used it without looking.
- `a[i]` is decided the same way compiled as interpreted. It is three operations in Haxe depending on
  the value (a map keyed, an array indexed, an abstract's `@:arrayAccess`), and the two sides
  choosing differently on the same line is the whole hazard.
- A `Bool` survives the round trip through cppia and its JIT, which has several shapes because cppia
  has no boolean of its own and carries one as an integer.
- A nested function's locals belong to it rather than to its parent, and an argument the capture pass
  boxes has its declared type erased rather than kept and misapplied.
- Typedef chains are followed to the end when resolving a type, rather than one hop.
- `??`, `%=`, `case a | b:` and a `using` whose receiver type is known now compile instead of being
  refused. A typedef alias such as bare `List` resolves.
- `final class`, `abstract class` and `extern` members parse. The flags are recorded but not
  enforced, so a script may still extend a `final` class.

### Docs

`embedding.md` is restructured around what a host does, and lists every build flag, mark and runtime
setting. `internals.md` is new, holding the design rationale that used to live in oversized
docstrings. `how-it-works.md` is new and is the technical document: the interpreter everything else
is measured against, then the cppia half, then the HashLink one, each with a real method going in and
the bytecode coming out. `support-table.md` is new and generated. `modes.md` gains the fourth mode
and README no longer says compiling is hxcpp-only.

## 1.1.2

Three lexer and typing fixes. A dollar sign that begins no interpolation is now a literal dollar
without consuming the character after it; previously the character was appended blind, so a string
ending in a dollar swallowed its own closing quote and ran on to the next quote elsewhere in the
file, reporting the error on an unrelated line. Unary bit-complement is now lexed outside a regex,
where it was only ever reached through the regex path and otherwise rejected with the position of the
character after it. Nested array literals now carry their declared element type down to the inner
arrays, so an array of arrays no longer erases to objects one level in and read back as zeroes under
cppia.
