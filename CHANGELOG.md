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
| `hxscript.compile.CppiaInput` | `hxscript.compile.Unit` | drove `Cppia.compile` yourself |
| `hxscript.compile.CppiaResult` | `hxscript.compile.Result` | drove `Cppia.compile` yourself |
| `hxscript.runtime.CallStack` | `hxscript.runtime.ScriptStack` | typed a variable as the interpreter's stack |

Internals renamed at the same time, unlikely to appear in a host: `CppiaEmitter`, `CppiaWriter`,
`CppiaCapture` and `CppiaUnsupported` drop their prefix inside `hxscript.compile`; `KeepMacro`,
`ScriptedMacro` and `TypeCollectionMacro` become `Keep`, `Scripted` and `Index`; `HLMacro` becomes
`Statics` and `proxy.HLMath` becomes `proxy.MathProxy`; `runtime.Mirror` becomes `runtime.Reference`;
`types.DummyClass` becomes `types.ScriptedObject`; `tools.Tools` splits into `syntax.ExprTools` and
`types.TypeTools`, and `tools.Defines` moves to `setup.Defines`.

`Script`, `Environment`, `Module`, `Config`, `IScripted`, `Interp`, `ScriptedClass`,
`compile.Compiler` and `compile.Cppia` keep their names.

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

### Compiler and parser

- `??`, `%=`, `case a | b:` and a `using` whose receiver type is known now compile instead of being
  refused. A typedef alias such as bare `List` resolves.
- `final class`, `abstract class` and `extern` members parse. The flags are recorded but not
  enforced, so a script may still extend a `final` class.

### Docs

`embedding.md` is restructured around what a host does, and lists every build flag, mark and runtime
setting. `internals.md` is new, holding the design rationale that used to live in oversized
docstrings.

## 1.1.2

Three lexer and typing fixes. A dollar sign that begins no interpolation is now a literal dollar
without consuming the character after it; previously the character was appended blind, so a string
ending in a dollar swallowed its own closing quote and ran on to the next quote elsewhere in the
file, reporting the error on an unrelated line. Unary bit-complement is now lexed outside a regex,
where it was only ever reached through the regex path and otherwise rejected with the position of the
character after it. Nested array literals now carry their declared element type down to the inner
arrays, so an array of arrays no longer erases to objects one level in and read back as zeroes under
cppia.
