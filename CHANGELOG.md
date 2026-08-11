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
| `hxscript.compile.CppiaInput` | `hxscript.compile.Unit` | drove the backend yourself |
| `hxscript.compile.CppiaResult` | `hxscript.compile.Result` | drove the backend yourself |
| `hxscript.compile.Cppia` | `hxscript.cppia.Backend` | called `Cppia.compile` or `Cppia.declaredPaths` |
| `hxscript.runtime.CallStack` | `hxscript.runtime.ScriptStack` | typed a variable as the interpreter's stack |

Internals renamed at the same time, unlikely to appear in a host: `CppiaEmitter`, `CppiaWriter`,
`CppiaCapture` and `CppiaUnsupported` drop their prefix, and the first three move with the backend
into `hxscript.cppia`, which now holds everything specific to compiling for hxcpp; `KeepMacro`,
`ScriptedMacro` and `TypeCollectionMacro` become `Keep`, `Scripted` and `Index`; `HLMacro` becomes
`Statics` and `proxy.HLMath` becomes `proxy.MathProxy`; `runtime.Mirror` becomes `runtime.Reference`;
`types.DummyClass` becomes `types.ScriptedObject`; `tools.Tools` splits into `syntax.ExprTools` and
`types.TypeTools`, and `tools.Defines` moves to `setup.Defines`.

`Script`, `Environment`, `Module`, `Config`, `IScripted`, `Interp`, `ScriptedClass` and
`compile.Compiler` keep their names. `Compiler` is still where a host configures compiling and asks
for it, and still reports the same way, so a host that only ever called `Compiler` is unaffected by
the backend moving out from under it.

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
