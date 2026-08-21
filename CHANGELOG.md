# Changelog

## Unreleased

### Added

- **A name the host bound reaches compiled code on hxcpp, and costs what a local costs.** A host
  binds values into scripts five documented ways, and compiled code reached exactly one of them:
  `Compiler.statics`, which needs the value to already live as a host static. Every other one refused
  its module as `unresolved identifier`, and skips cascade, so a module that named a global cost its
  bytecode to everything naming that module. `world.variables` is the surface `docs/embedding.md`
  calls "the usual choice", so this was most projects. All five reach compiled code now, along with
  an `Interp` subclass overriding `resolve` or `setVar`, which no surface covered at all: reads and
  writes go through the interpreter the class already has, so a compiled module and an interpreted
  one cannot disagree about what a name holds.

  What a name compiles to is decided by what it held while the module compiled, cheapest first. A
  type becomes the type's own path, so a host alias for a class is now the class: `new Bucket()` and
  `Bucket.ping()` work where only `Sink` did, and it costs nothing at runtime. A host static is read
  where it lives. An `Int`, `Float`, `Bool` or `String` is read out of a real typed static holding a
  copy, which measures 2.3ns against the 92ns of asking the interpreter and against 2.3ns for a
  local. Anything else is a call, and its class is still what the emitter reasons with, so an operator
  overload, a map index against an array one, and how an optional is padded are all decided from it.

  **The type is the whole of why the fast path is fast.** A `Dynamic` static reads ten times slower
  than a typed one, so a global holding an object or a function stays on the call path deliberately:
  measured, a boxed slot buys it nothing.

  Nothing has to be registered twice for any of that. `Config.globalStatics` is merged into the
  emitter's own list rather than left to the host to mirror, which was a real gap: a name set there
  alone resolved interpreted and refused its module compiled, with nothing saying why.

- **`hxscript.runtime.Bindings`, which is what makes the copy safe.** `Interp.variables` is one of
  these rather than a bare `Map`, so a write to a name reaches the copy before anything can read a
  stale one. It matters because a host writes that table directly, and the alternative was a `rebind`
  call for hosts to remember, which fails the moment somebody forgets. `set`, `get`, `exists`,
  `remove`, `clear` and iteration all read as a map's do.

- **`Compiler.globalNames`, for the three cases a bound value cannot decide.** A name bound after the
  compile, one holding null, and one whose type the host means to change. Written `name` or
  `name:Type`, and a pin beats what the value says. `name:Dynamic` keeps one untyped on purpose.
  `examples/battle` shows the case: `round` and `log` reach scripts through a context that only
  exists once a fight starts, and naming them is the difference between eleven of its twelve scripts
  compiling and all twelve.

- **`Compiler.globals`, which turns the whole thing off.** On by default. Off restores the older
  behaviour, where such a name is reported as an unresolved identifier and its module left
  interpreted, for a host that would rather be told than served quietly. It reads on HashLink too,
  where it gates the bound-name lookup that backend already had.

- **`Report.globals`**, listing every bound name a compile reached and how each was spelled, so the
  ones still read through a call can be found and given a real home. `-D hxscript_verbose` names them
  as they happen.

### Fixed

- **A running total accumulated through a field of a host class wrapped at two billion.** hxcpp
  cannot tell a whole `Float` from an `Int`: `2.0` held as `Dynamic` answers true to `is Int` and
  `TInt` to `Type.typeof`, and so does the same value read straight out of a field declared `Float`.
  The declared type is the only thing that can say which it is, and the interpreter had that for its
  own slots and not for a field of a class the host compiled, since Haxe keeps no field types at
  runtime and the build's type index records what a type is rather than what its fields hold.

  So `sink.total = sink.total + i` against a `Float` field was added as an `Int` and wrapped, which
  `CppiaHostBench` had been reporting for some time as `-1455759936` where every compiled mode said
  `1999999000000`. A field nothing declares now promotes rather than wrapping. That costs a host field
  really declared `Int` its wraparound at 2^31, which is a shape scripts reach for deliberately and
  almost always through bitwise operators, and those never come this way. A field of a scripted
  object is still read from its own slot and still wraps when that slot says `Int`.

  Asking the question got cheaper at the same time. `x += y` used to work out whether either side
  widens before doing anything, and only an addition that carries past `Int` cares about the answer,
  so it is asked on the carry instead: `field` 118 to 111, `fieldGuard` 120 to 114, `instFieldGuard`
  82 to 68.

### Changed

- **A scripted instance stands on its class's names instead of copying them, so constructing one no
  longer costs more as the host's script API grows.** Every instance was handed a copy of the class's
  whole variable table, about 0.14us per bound value: 5.7us to construct at eight bound values,
  9.1us at thirty-three, 12.9us at fifty-eight, without limit. A host with a hundred names in scope
  paid for all hundred every time a script made an object.

  It is flat now, 3.95us whatever the host binds, and lower than it was even at eight. Reads fall
  through to the class and writes never do, so an instance assigning to one of those names gets an
  entry of its own from that moment, which is exactly what the copy gave it.

  Its `imports` table is stood on the same way, worth another 40%, and that one had to be measured
  rather than assumed: `imports.get` is the first thing `resolve` does for every bare identifier, so
  a fallback there lands on the hottest path there is. It costs nothing measurable. Together,
  `newInstBare` 145 to 56, `newInstFields` 237 to 149, `newInstGuard` 197 to 104, with `arith`,
  `locals`, `field`, `call` and `instCall` unmoved.

- **A typed write remembers how its annotation is enforced instead of resolving it every time,
  worth 32% on writing an annotated variable.** `tryCast` asked `imports` whether anything shadowed
  the written type name on every store, a map miss for `Int` or `String`, and then `castCoreType`
  worked out which type it had been asked about by comparing the name. The answer depends only on the
  annotation, which cannot change, and on the import table, which can, so `Bindings` carries a version
  and the slot remembers the plan against it. `varTyped` 109 to 74.

  Worth recording how it was got wrong first: keeping the plan, the stamp and the name as three
  fields on `Variable` measured a net 1% LOSS across the benchmark, spread over cases that never
  write a typed variable at all. A `Variable` is allocated per local per frame, so anything it
  carries is paid for by every script whether or not it uses the feature. Packed into one `Int` it is
  a net 2% gain instead, on the same control.

- **Operator dispatch is a jump table instead of a table of closures, worth 16 to 23% across the
  interpreter.** `binops` was a `Map<String, Expr->Expr->Dynamic>` built per interpreter, so every
  operator cost a string hash, a null test and a call through a closure field, and every interpreter
  allocated thirty-eight closures and a map before running anything. A scripted class gets its own
  interpreter, so that was thirty-eight per class too.

  Switching on the operator token is worse than the map, which is worth knowing because it is the
  obvious fix: hxcpp lays a string switch out as a chain of comparisons, so `<` in a loop condition
  paid for every operator ahead of it. Switching on the token's length and first character is two
  integer switches, which become jump tables. `arith` 211 to 172, `locals` 163 to 125, `noCall` 43 to
  33, `varPlain` 83 to 65, `newInstBare` 144 to 119. The instantiation rows are the closures no longer
  being built, which every scripted class and instance was paying for whether or not it evaluated an
  operator.

- **A compiled class resolves its bound names against its own interpreter, not its module's.** A
  scripted class runs on an interpreter seeded with a copy of the module's names rather than sharing
  them, so `damage` inside one class and `damage` inside its neighbour are two bindings. Reaching the
  module's meant a name written by an interpreted method and read by a compiled one answered what it
  held before the write.

- **A rebound global is reported at the write instead of the read.** A compiled read of a typed name
  is a static field access with no room for a check, so the write is both the only place that can
  notice and the better one: it names the line that broke the contract rather than a read far away.
  A refused write leaves the name as it was. Dropping such a name is not reported, because a slot has
  no value that means "gone"; a compiled read keeps answering the last value until something writes
  it again.

### Measured, and not done

Three things that looked worth doing and are not, each ruled out by building them:

- **Calling the helper as a closure rather than `CALLSTATIC`.** 25% cheaper in isolation and 60%
  worse in place: reading a static method as a closure allocates per read and loses the callee's
  declared return type, so the value comes back boxed.
- **Typing an object slot by its class.** 160ns against 163ns for a boxed one, because cppia
  dispatches member access by name whatever the receiver's type says (HXCPP-ISSUES.md, 4).
- **Reaching a `Variable` cell from bytecode.** Worse than the call it would replace, since reading
  the cell is itself a by-name member call.

### Still open

- **HashLink resolves a bound name to the value it held when the module loaded, and refuses writes.**
  It reached `Environment.variables` before this and still does, by folding a snapshot into a global
  rather than resolving through the interpreter, so a host writing the name afterwards is not seen and
  a script assigning to one leaves its module interpreted. Moving it onto the same hook is the
  follow-up; `Compiler.globalNames` is hxcpp-only until then.

## 2.0.3

### Fixed

- **A constant of a plain abstract had no bytecode spelling, so `FlxColor.RED` left its whole module
  interpreted.** An abstract's constant is its underlying value once compiled, which is why a backend
  has to write the value rather than a field access, and the test for which fields those are was
  whether the abstract was an `enum abstract`. `flixel.util.FlxColor` is not one: it is a plain
  `abstract FlxColor(Int)` whose fifteen colours are `static inline`, so all fifteen were refused, and
  one of them anywhere in a script cost every class in that module its bytecode. A script doing
  nothing more unusual than filling a rectangle red compiled zero classes and reported one
  interpreted. The wrapper now records which of an abstract's statics are `inline` or `final`, which
  is the set Haxe folds itself, and both backends fold exactly those. An ordinary `static var` is
  still refused, because a script may assign to it.

- **Nothing else a host abstract declares had a compiled form either, so `FlxColor` was unusable
  past its constants.** An abstract has no runtime form: Haxe moves everything it declares onto a
  companion class and passes the value that would be `this` as a first argument, so
  `FlxColor.fromRGB(r, g, b)` is `FlxColor_Impl_.fromRGB(r, g, b)` and `colour.getDarkened(f)` is
  `FlxColor_Impl_.getDarkened(colour, f)`. Asking the value itself for a member of that name finds
  nothing, because the value is only the `Int` the abstract wraps. A static method was refused, and
  an accessor was worse than refused: `colour.red` read `null` through `Reflect.getProperty` with
  nothing said about it. Both backends reach the implementation class now, so static methods,
  ordinary statics, accessors, methods on a value and `@:op` operators all work, while a member that
  is only forwarded is left to the dispatch that already reached it. The set is gated on the class
  really carrying the member, since cppia rejects a whole module for one name it cannot link.

- **cppia held a constructed host abstract as a wrapper where the host holds the value.** A constant
  folded to the underlying value while `new HostVec(3, 4)` handed back the box, so the two spellings
  of the same type were different things and a member call on one of them fed a wrapper to a static
  that had declared the underlying type. Compiled code holds what the host's own compiled code holds.

- **Annotating a local with the abstract it already is ended the script on eval and HashLink.**
  `var a:HostAxes = HostAxes.XY` casts a value against its own declared type, and the interpreter
  performed that by building the wrapper a second time around one it already had. Every route through
  `resolveFrom` is written for the value underneath, and the enum one showed it by asking `_enumMap`
  for a key that was a wrapper rather than a name: a `StringMap` refuses that on eval and HashLink
  where hxcpp answers false, so two targets out of three died on a lookup that could only have missed.
  A value that is already the wrapper now hands its contents over ahead of every other route, the name
  lookup runs only when a name arrived, and the cast returns what it was given rather than allocating a
  second wrapper per annotated declaration.

- **A constant whose name collided with an accessor was refused even on an enum abstract.** A wrapper
  normally offers each constant behind a lazy `get_NAME`, but when the abstract declares an accessor
  of that name already it holds the constant as a plain static instead, and only the getter was read.
  `flixel.util.FlxAxes` is that shape, so `X` and `Y` were refused where `XY` and `NONE` compiled,
  which is a difference nothing in a script accounts for. Both shapes are read now.

## 2.0.2

### Fixed

- **The package shipped without `extraParams.hxml`, so none of the library's setup ran.** haxelib
  applies that file to every build that says `-lib hxscript`, and it is the whole of how the three
  setup macros come to run. Installed from haxelib, the library therefore did nothing: dead code
  elimination stripped the standard-library members a script reaches by reflection, no game library
  was detected, no bridge or abstract wrapper was generated, the runtime half was never installed,
  and there was no banner to say any of it had been skipped. `package.sh` names what goes in the zip
  and listed `src`, the manifest, the readme and the licence, and `git archive` ships exactly what it
  is told. Nobody working from a checkout could see it, because `haxelib dev` points at the
  repository, where the file has always been.

## 2.0.1

### Fixed

- **The flixel shims registered on versions they cannot work on.** Every one of them is written
  against flixel 6.2.0, and the gate around them read `#if (flixel >= "6.0.0")`, which is two
  releases too low. On 6.1.2 that was not a wrong shim but a build that did not happen:
  `FlxSprite.clipToWorldRect` and the `clipToWorldBounds` it calls do not exist before 6.2.0, so the
  shim failed to compile and took the host's build with it. Under it sat a quieter one.
  `SoundFrontEnd.playMusic` is an ordinary method on 6.1.2 rather than the inline overload it became
  in 6.2.0, so it already has a runtime form and needs no shim, and registering one replaced a
  working member with a closure reading `(asset, group, volume, loop)` where that version passes
  `(asset, volume, looped, group)`. A script calling it got its group where its volume should be.
  The gate is now `#if (flixel > "6.1.2")`, so the shims register on 6.2.0 and later and nowhere
  else.

## 2.0.0

### Breaking: no preset offers a bare name any more

A preset's `globals` list used to be registered as global imports at startup, so `-lib flixel` beside
`-lib hxscript` put forty-three bare names into the scope of every script in the process. Every
shipped preset now offers an empty list, and a script reaches a game library by writing an `import`,
as in Haxe:

```haxe
import flixel.FlxSprite;   // in the script, and this is all that was ever needed
```

A host that wants some names bare says which:

```haxe
Boot.importGlobals(['flixel.FlxG', 'flixel.FlxSprite']);
```

**What breaks:** a script writing a bare `FlxG`, `FlxSprite` or any of the other forty-one now fails
with `Unknown identifier`, and the hint on that error names both fixes. Adding the `import` is the
one to prefer.

**Why.** A preset's job is to say what a script *can* import, which is steps 1 to 3 of the wiring:
include the types, bridge the bases, wrap the abstracts. What is already imported into every script
is a different question and not a library's to answer. Forty-three names in every script's global
scope shadow anything the host binds under the same name, and a script reading `FlxG` gives no clue
where it came from.

**The mechanism is unchanged**, only the shipped data. `globals` is still a field on
`hxscript.setup.Library`, `Presets.custom` still takes a record that fills it, `Boot.importGlobals()`
with no argument still takes whatever a record offers, and `-D hxscript_globals` still takes it at
startup. All three now find nothing to take unless you put it there.

`@:scriptAmbient` on your own class is unaffected and still automatic: marking one is the request, so
there is nothing to ask twice. `Boot.ambient` is that list, kept apart from `Boot.globals` for the
same reason.

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

Three helpers were reachable from a script by a bare name, because the presets listed them in
`globals`. They were renamed with everything else, so a script written against the repo between 1.1.2
and now needs the new name. Nothing that shipped in 1.1.2 had them. As of the change at the top of
this file they also need an `import`, since no preset offers a bare name any more.

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

- **Presets for five more libraries**, so `-lib` is still the whole of the setup for each.

  **hxvlc**, video playback through libVLC, which is the case a mod that plays a cutscene needs.
  `hxvlc.impl` is deliberately left out of the roots: it is the libVLC extern layer, written in
  `cpp.RawPointer` and `cpp.Callable`, and a script drives video through `FlxVideoSprite` or `Video`
  rather than below them. One bridge, `FlxVideoSprite`; `openfl.Video` is reachable but not
  extendable, because it inherits most of the openfl display list and holding one is how openfl is
  used anyway. `hxvlc.util.typeLimit.OneOfTwo` is wrapped, since `Location` is a typedef of it and it
  is the argument type of every `load` call.

  **extension-haptics**, vibration, as the one cross-platform class `extension.haptics.Haptic`. Every
  platform branch in it is behind a conditional and the library has no `#error` anywhere, so it
  compiles everywhere and does nothing where there is no hardware. `HapticAndroid` and `HapticIOS`
  are left out on purpose: naming them would undo exactly that.

  **extension-androidtools**, the Android system surface, and the one record here that is Android
  only. See the `requires` change below for why that had to become expressible.

  **haxe.ui**, as two records, because that is how it ships: `haxeui-core` is the components and the
  layout, and a backend library decides what they draw on. `haxe.ui.backend` is left to the backend
  record rather than named in core, since core ships that package as the shape a backend must fill
  and the backend library shadows it on the classpath. `abstractPackages` covers the whole of
  `haxe.ui`, because the toolkit is built out of abstracts: every constant is an enum abstract,
  `Variant` is what a component's value is typed as, and `EventType` is how an event is named. No
  bases in core, since a haxe.ui screen is composed rather than subclassed and `Component` would be
  the most expensive bridge in any preset shipped; `haxeui-flixel` bridges `UIState` and `UISubState`,
  which is where a flixel project does subclass.

- **A `Library` record may require several defines**, comma-separated in `requires`, all of which must
  hold. `extension-androidtools` answers `#error 'not supported on your current platform'` off
  Android, so a desktop build that merely had the library would have stopped compiling the moment the
  preset force-compiled its packages. Requiring `extension-androidtools` and `android` together keeps
  a project that lists the library unconditionally, and guards its own calls, building on every other
  target.

- **`docs/verified-imports.md`**, generated by `python test/lib/reach.py`: every type a script can
  `import` and use, per shipped stack, with the ones that cannot be used listed by name and reason.
  Nothing in it is read off `Presets`. `test/lib/Probe.hx` writes an `import` for every type in the
  build, runs it, and records whether the name came back with a runtime form behind it, which is the
  only way to catch the three failures that accept an `import` and then answer nothing: a type dead
  code elimination dropped, an abstract with no wrapper, and a typedef of a shape the interpreter
  cannot represent. 1882 usable and 377 not for the flixel stack; 414 and 60 for heaps 2D and 3D.

  **Measured on the targets a game ships as**, hxcpp first and HL/C second, rather than on the
  interpreter. That costs a real build per stack and is the only way the answer means anything: dead
  code elimination is what strips a member and is a property of the target, and a library is free to
  define a type per target the way heaps does with `hxd.FloatBuffer`. HL/C needs a HashLink
  installation for `hl.h` and `libhl`, which `src/hxscript/hl/native/build.sh` finds under
  `/c/hashlink/*` or takes from `HLPATH`. A stack neither target can build is reported as *not
  verified*, with both build errors, rather than guessed at.

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

- **`openfl.Lib` was offered without anything guaranteeing it was in the build.** The openfl preset
  names it in `globals`, but every included root is a sub-package of `openfl` and `Lib` sits at the
  package root, so nothing in the record puts it there. It may have arrived anyway, the way
  `h3d.Vector` does, by some included type naming it in a signature; what is certain is that nothing
  made it so. It is in `types` now, which does. Separately, a path that cannot be registered is
  **reported through `Sink`** rather than dropped in silence, which is what would have made this
  visible either way.
- **The abstract scanner invented three abstracts from flixel.** `abstract` is a type, a class
  modifier and a method modifier in Haxe 4, and the pattern took whatever word followed it, so
  `flixel.tile.FlxBaseTilemap`'s `abstract class`, `abstract public function` and `abstract function`
  produced `FlxBaseTilemap.class`, `.public` and `.function`. They were handed to
  `Compiler.addMetadata` as though they were types, which harmed nothing because metadata on a path
  nothing declares does nothing, but the count was three too high. `AbstractScan` now has cases for
  what the scanner must NOT report, which it never had: it only ever asked what the scanner finds,
  never what it invents.
- **A generated abstract wrapper failed a host library's null-safety pass, and took the build with
  it.** A wrapper is defined into the package of the abstract it wraps, because that is what lets
  `AbstractTools.resolve` find it, and that also puts it inside any `--macro nullSafety(...)` covering
  that package. hxvlc's `extraParams.hxml` has exactly that line for `hxvlc`, so wrapping
  `hxvlc.util.typeLimit.OneOfTwo` produced a class checked against a standard it was never written
  to: `_enumMap`, `_enumConstructors` and `_enumValues` have no initial value, and adding one library
  to a project stopped that project compiling for a reason nothing in it could act on. Wrappers now
  carry `@:nullSafety(Off)`. The library's own modules are unaffected, and this is generated code of a
  known shape rather than code anyone maintains, so nothing a person would have checked is lost.
- **Two thirds of the abstracts a preset scanned for were never actually wrapped.**
  `Compiler.addMetadata` takes the path a type is *declared* under, which is its package and its own
  name, and the scanner was passing the module as well: `flixel.text.FlxText.FlxTextAlign` rather
  than `flixel.text.FlxTextAlign`. Metadata on a path nothing declares is not an error, so every
  abstract that shared a module with another type was counted as wrapped and silently skipped, and
  only the eleven flixel wrote in a module of their own came out with a wrapper. Without one an
  abstract has no runtime form at all, so `FlxTextAlign.CENTER` answered nothing, assigning to
  `FlxText.alignment` did nothing, and `import flixel.text.FlxText.FlxTextAlign;` bound the name to
  null and failed on first use with `Module FlxTextAlign does not define type FlxTextAlign`, naming
  the type as though it were the module. The flixel stack now generates 71 wrappers where it
  generated 31, and every abstract these presets ask for is usable from a script.
  `docs/verified-imports.md` lists what is still not.

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
