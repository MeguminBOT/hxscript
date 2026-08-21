# Tests

Standalone programs that embed scripts as strings, run them through the library and check the
results, so they exercise the interpreter the way a host application does.

The suite is organized by **target**, because that is where the failures were hiding: six of the nine
Haxe targets it builds for are currently broken, and five of those were found by running this matrix
rather than by anyone reporting them.

hxcpp is the target this library is built for and the only one held to a working suite. See
[which targets are actually supported](#which-targets-are-actually-supported) before reading the
matrix as a support promise.

## Running

Everything, on every target:

```sh
sh test/run.sh
```

A subset:

```sh
sh test/run.sh cpp js
```

One target on its own, which is what the per-target `build.hxml` is for. Run these from the
repository root:

```sh
haxe test/eval/build.hxml                       # fastest, runs during compilation
haxe test/cpp/build.hxml && ./bin_test/cpp/common/AllCommon.exe
```

One test on its own, which is often what you want while fixing it:

```sh
haxe -cp src -cp test/common -cp test/common/fixtures -cp test/lib -main ReturnTest --interp
```

`run.sh` exits non-zero only on an **unexpected** failure. A target in
[`known-failing.txt`](known-failing.txt) is reported as `known-fail` and does not fail the run, so
the matrix is usable as a gate while those six are open. Delete a line from that file when its cause
is fixed; if the target still fails, the runner will say so.

## Layout

| path | holds |
| --- | --- |
| `lib/TestCase.hx` | shared assertions, portable output, the exit code |
| `common/` | the 15 portable tests, run on all nine targets, plus `AllCommon` |
| `common/fixtures/` | `OpVec`, `OpBare`, `OpColor`, `OpName`, which `AbstractTest` asserts against |
| `cpp/` | the 8 hxcpp-only tests plus `AllCpp`, and the manual tools |
| `eval/ js/ java/ neko/ python/ lua/ php/ hl/` | a `build.hxml` each; target-specific tests land here as they appear |
| `xbench/` `mbench/` | the benchmarks, not tests: see [benchmarks.md](../docs/benchmarks.md) and [mode-benchmarks.md](../docs/mode-benchmarks.md) |
| `Bench.hx` | the micro-benchmark, see [performance.md](../docs/performance.md) |

Each test exposes `run()` and a `main()` that reports once, so it works standalone and inside an
aggregate. The aggregate matters for cost: fifteen separate builds per target would be 135
compilations across the matrix, most of it the library recompiled, against 10 this way.

`TestCase` counts three things, and the difference between the last two is the point:

- **pass** / **fail** is an assertion. A failure fails the build.
- **gap** means a probe found something missing. Reported, counted, does **not** fail the build. The
  probes sweep a broad surface looking for holes; `SweepProbe`'s `regex replace` gap is DCE in the
  probe's own build rather than a defect, and `DceProbe`'s `List (bare)` gap is there because these
  builds use `-cp src`, so `extraParams.hxml` and its `Keep` never run.

## What each test covers

| file | covers |
| --- | --- |
| `ReturnTest` | `return` from loops, `switch`, `try`/`catch`, nested blocks, recursion, early and bare return |
| `LoopTest` | `break` / `continue` scoping to the innermost loop, comprehensions, `return` unwinding past a loop |
| `RangeTest` | `a...b` integer ranges, including with `break`, `continue`, `return` and comprehensions |
| `ArgsTest` | argument binding: exact, optional, default and rest parameters |
| `TypedTest` | typed mode: enforcement, coercion, and that dynamic mode disables it |
| `StructTest` | structural typedefs via `is`, `cast` and annotations: field presence, field types, optional fields |
| `ClassProbe` | scripted classes: inheritance, `super`, statics, properties, interfaces, enums, closures |
| `AbstractTest` | native abstracts: construction, fields, statics, and `@:op` operator dispatch |
| `ScriptedAbstractTest` | script-declared abstracts: construction, members, implicit boxing, operators, conversions |
| `UsingTest` | static extensions on scripted classes: registration, selection by receiver type, errors inside an extension |
| `AccessTest` | `private` on scripted members: the enforcement gate, unmarked members staying public, and `@:privateAccess` |
| `PrinterTest` | `Printer` on module declarations, checked by print-reparse-print stability |
| `FieldBindTest` | that a typed class or static field binds as the identical local does, and that field errors carry a stack |
| `SweepProbe` | numeric edges, the `#if` preprocessor, string and regex handling, error handling, imports and `using` |
| `GapProbe` | a broad sweep of everyday script constructs, used to hunt for gaps rather than assert one thing |
| `cpp/CppiaTest` | the differential test: every case run interpreted and compiled, and the two must agree |
| `cpp/CppiaWorldTest` | compiling part of a world, and that the compiled half is what actually runs |
| `cpp/SweepTest` | the constructs the emitter accepts, both ways, with refusals reported |
| `cpp/CompilerTest` | the `Compiler` facade: compile, bind, reload, and what `substituting` means |
| `cpp/ExposeTest` | `Expose` filling the ambient types and static bindings from build marks |
| `cpp/PropTest` | host properties reached from compiled code through their accessors |
| `cpp/CatchNative` | catching a native exception in compiled script code |
| `cpp/DceProbe` | which standard-library members a script can still reach after DCE |
| `cpp/GlobalsTest` | names the host bound rather than the script, reached from compiled code |

Map key order is unspecified in Haxe, so an ordering difference in `GapProbe` is not a defect.

### Manual tools

In `cpp/`, not in the suite, because none of them asserts anything a runner could check:

| file | is |
| --- | --- |
| `CppiaBench`, `CppiaHostBench`, `CppiaGlobalsBench`, `SwitchProbe` | timings |
| `CppiaDump`, `CppiaOne` | print bytecode for a human to read |
| `FieldFormProbe` | walks a directory named on the command line and counts the field forms emitted |

## Which targets are actually supported

**hxcpp is the target this library is built for.** MeguminBOT develops and uses it on cpp, that is
where the design decisions get made, and it is the one held to a working suite.

The other targets are tested here because knowing they are broken is better than not knowing, and
because a fix is usually small once the matrix has pointed at the line. They are not held to the same
bar: a bug that only shows up off cpp is lower priority, and may sit for a while or not be fixed at
all. Nothing here is a promise that the library works on your target.

If you need one of them, the matrix is the fastest way to find out where you stand, and a pull
request fixing a line in [`known-failing.txt`](known-failing.txt) is very welcome. PR #2 is exactly
that, for js and hl.

## Target status

Run `sh test/run.sh` for the current answer. As of writing:

| target | status |
| --- | --- |
| eval | ok |
| cpp | ok, and the reference: hxcpp is what ships |
| cppia | ok |
| java | generates; javac is not exercised here |
| js, lua, neko, php, hl | do not compile |
| python | compiles, then evaluates to null |
| cs | not covered, hxcs is not installed |

The causes are in [`known-failing.txt`](known-failing.txt). Two of them are what PR #2 reports.

**A target that only generates is still worth building.** Generation must be real output rather than
`--no-output`: the js and lua failures are generator-stage errors that `--no-output` never reaches,
so a matrix that skipped generation would report those two green while they cannot build at all.
