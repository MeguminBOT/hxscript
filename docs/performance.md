# Interpreter performance

A log of what has been optimized, what it cost before, and how it was measured. Numbers come from
[`test/bench/Bench.hx`](../test/bench/Bench.hx), a micro-benchmark whose cases are chosen so a gain
can be attributed to a specific change rather than to "things feel faster".

**Every number on this page is milliseconds, so lower is faster.** A table showing `before` and
`now` is an improvement when `now` is the smaller of the two. The only figures that read the other
way are the explicit `Nx` speedups, where a bigger multiple is better, and they say so.

## Running it

```
haxe -cp test/bench -cp src -main Bench -cpp bin_bench && ./bin_bench/Bench.exe
```

Its first argument scales every case's loop count, for a change small enough that the default counts
finish inside the machine's own run-to-run drift.

Measure on **hxcpp**, not `--interp`. The interpreted target hides exactly the costs that matter here
(the typed-boundary coercions and exception costs behave differently), and hxcpp is what ships.

### The one rule: always rebuild the control

Absolute timings drift with machine state by well over 10%, which is more than most individual
optimizations are worth. Twice during this work a "regression" or an "improvement" turned out to be
nothing but a warmer or cooler machine.

So never compare against a number written down earlier. Build the previous commit in the **same
session**, run both, and compare those:

```
git worktree add /tmp/before <previous-commit>
haxe -cp /tmp/before/test/bench -cp /tmp/before/src -main Bench -cpp /tmp/before_bin
/tmp/before_bin/Bench.exe
git worktree remove /tmp/before --force
```

Only same-session pairs appear as verified deltas below.

## What the cases measure

| case | what it isolates |
| --- | --- |
| `arith` | operator dispatch and numeric promotion |
| `locals` | variable read/write through the scope map |
| `blocks` | per-block scope bookkeeping |
| `field` | field-access chain resolution |
| `method` | a native method call through the interpreter |
| `call` | a script function call |
| `call0` / `call1` / `call3` | fixed per-call overhead versus per-parameter cost |
| `callRet` / `callNoRet` | a body that returns versus one that does not |
| `noCall` | empty loop floor, the baseline every other case includes |
| `loopPlain` / `loopCont` | loop iteration with and without `continue` |
| `call_cap20` | whether call cost scales with captured-scope size |
| `newInstBare` / `newInstFields` | scripted-class instantiation: fixed cost versus per-member cost |
| `instCall` / `instField` | a method call and a field read through a generated instance bridge |

## Changes

Each entry opens with the commits that made the change, followed by any later commit that fixed,
finished or reworked it, so the cause of a number can be read in full rather than inferred from the
diff. Every hash links to the commit on GitHub, where most messages carry the measurements behind
the change in more detail than this page does.

### The constructor no longer seeds defaults nothing was going to read

- [`9f22bc7c`][9f22bc7c] stops `Interp.new` seeding defaults every construction site seeds again.

The entry below made the default wildcard import cheap to resolve. This one stops resolving it twice.

`Interp.new` ended with `setDefaults()`, and **every one of the five construction sites in the library
called `setDefaults` again straight afterwards**: `Module.init`, `Script.start`,
`ScriptedClass.init`, `ScriptedInterface.init` and the generated instance bridge. Four of them pass
`wipe: true`, which clears `imports`, `usings` and `variables`, so the constructor's work was thrown
away; the bridge then copies the class's own tables over the top. The constructor's seeding had no
surviving consumer anywhere in the library.

Attribution, on one pre-built interpreter, 200,000 calls each:

| | cost |
| --- | --- |
| `setDefaults(wipe, with config seeding)` | 2.728us |
| `setDefaults(wipe, no config seeding)` | 0.047us |
| `Reflect.makeVarArgs` (the `trace` binding) | 0.007us |
| five empty collections | 0.016us |

So the seeding is 2.68us of a 4.09us interpreter, and 28% of a 9.4us scripted-class instantiation.
Two suspects that looked obvious were both wrong and are worth recording: the `trace` closure is
free, and `Type.createInstance` matches a direct `new` (4.03 against 4.09), so reflection is not the
cost either.

Verified deltas (same session):

| case | before | after | |
| --- | --- | --- | --- |
| `new Interp()` | 3.91 - 4.09us | 1.05 - 1.07us | **3.8x** |
| `new Interp()` + an explicit `setDefaults()` | 6.48 - 6.84us | 4.04 - 4.21us | **1.6x** |
| `new Script(...)` + `start()` | 10.84 - 11.32us | 8.22 - 8.28us | -25% |
| `classNew`, bare class | 9.17 - 9.57us | 6.37 - 6.44us | -31% |
| `classNew`, four methods | 11.56 - 12.08us | 8.71 - 8.94us | -25% |
| `newInstBare` / `newInstGuard` / `newInstFields` | 190 / 220 / 244 | 129 / 161 / 186 | -32% / -27% / -24% |
| the other 29 `Bench` cases | | unchanged | |

`call0` first read +3.8%, which is inside this machine's drift: four alternating runs gave 79/80,
80/79, 81/80, 81/81. It is timed after construction and the change cannot reach it.

**This changes the public API**, and is the reason the entry is worth reading rather than just the
diff: a bare `new Interp()` is now unseeded until something calls `setDefaults()`. Everything the
library hands out (`Script`, `Module`, `ImportModule`, scripted classes and interfaces) already
does it, so only a host driving an `Interp` directly is affected, and it is one line. That host is
still better off than before the change, since it used to seed twice.

For reference, hscript-improved builds its interpreter in 1.24us, which is the whole of its 2x lead
on `classNew` (4.70us against our 9.4us). At 1.05us we now construct one faster than it does, and the
remaining gap is its much cheaper class shape, with fields in a map behind `hget`/`hset` rather than real
fields on a generated bridge, which is also why it loses 6x on method calls.

### Identifiers sliced out of the source instead of grown a character at a time

- [`9c72f844`][9c72f844] slices identifiers, `@metadata` names and `#if` directives.

The lexer built every identifier with `id += String.fromCharCode(char)`: an allocation per character
plus a copy of everything read so far, so lexing one was quadratic in its length, on the most
common token in any source. `readPos` already indexes the input, so the whole identifier comes out in
one `substr`. Applied to identifiers, `@metadata` names and `#if` directives; operators are left
alone, being one to three characters with backtracking that makes the same change fiddly for nothing.

Parse throughput on an 89.8KB, 3401-line source: **21 -> 24 MB/s**, reproducible.

Worth keeping in proportion: a 200KB mod parses in about 8ms either way, so parsing was not the
bottleneck and this does not make it one.

### A closure no longer copies its captured scope on every call

- [`5e5425b8`][5e5425b8] reuses one frame per closure, and fixes the `inTry` unwinding bug described
  at the end of this entry.
- [`95637f93`][95637f93] adds `callCap20` to the cross-library suite, validated against this fork
  before and after the change.
- [`f40e950d`][f40e950d] records the per-library table below, as measured at the time. The current
  figures are in [`benchmarks.md`](benchmarks.md).

`buildFunction` built the call frame with `duplicate(capturedLocals)` per invocation, so a script call
cost O(size of the enclosing scope). A closure now keeps one frame map and reuses it; only re-entry
takes a copy. Safe because `restore` already puts back every binding the prologue and body shadowed,
which is the guarantee the enclosing scope relies on.

| case | before | after | |
| --- | --- | --- | --- |
| `call_cap20` | 407 | 140 | **2.9x** |
| `call0` / `callRet` | 85 | 79 | -7% |
| `call1` | 128 | 119 | -7% |
| `call` | 142 | 135 | -5% |
| every other case | | unchanged | |

`call_cap20` now matches plain `call`, so call cost no longer scales with scope size at all. Scripted
class methods were always exempt, running in a fixed `functionLocals`.

This is a design difference and not a universal one, which is worth knowing before assuming any
hscript-derived library behaves the same way. The cross-library suite grew a `callCap20` case for it
(see [`benchmarks.md`](benchmarks.md)); measured against each library's OWN `call1`, so the ratio is
independent of how fast that library is otherwise:

| library | penalty for twenty captured variables |
| --- | --- |
| this fork | none |
| hscript-improved | none |
| RuleScript | 1.27x |
| hscript / hscript-iris | 1.29x |
| hscript-insanity | 1.36x |

Fixed a latent bug the reuse made reachable: the `inTry` path unwound the frame on a caught exception
but not its declarations, leaving them on `declared` for an enclosing `restore` to roll back once
`locals` was the CALLER's scope, so it wrote a callee's parameters into its caller.

### The default wildcard import, resolved once per world instead of once per interpreter

- [`141006bb`][141006bb] caches a wildcard import's bindings on the world.
- Later, [`be646edc`][be646edc] fixed the filter whose result that cache holds. It compared a whole
  module path against a bare type name, so `import pack.*` brought in nothing for any packaged type.
  The bug is older than the cache, which is why the root-package wildcard measured here looked
  healthy: an unpackaged module was the only kind that could pass.

Constructing an interpreter cost **44.2us**, and **42.7us of it was `setDefaults`** seeding
`Config.globalImports`, which is `'' => IAll`: a wildcard import of the root package. `setDefaults`
with the Config seeding skipped costs 0.042us, so the seeding was a thousand times the cost of
everything else in the constructor put together.

That lands on scripted-class instantiation, which builds an interpreter per instance and paid it
twice (once in the constructor, once in the bridge's own `setDefaults` a few lines before it copied
the class's imports over the top and discarded the result).

Attribution inside the import, over the 27 root-package types, per call:

| step | cost |
| --- | --- |
| `listTypesEx('')` | 3.5us |
| plus the sub-type/`_Impl_` filter | 6.5us |
| plus resolving each surviving type | 41.9us |
| the whole `setDefaults(true, true)` | 43.4us |

So 82% of it was `TypeCollection.resolve` per type, and none of it changes until the world's type
index does. A wildcard import now remembers its name-to-type bindings (`ImportEntry`) on the
`Environment`, or in a static for interpreters with no world, and drops them in `rebuildTypes`.
`Interp.clearImportCache()` drops the world-less ones, for a host that changes `Config.blacklist` or
`Config.typeProxy` after scripts have already run.

Verified deltas (same session):

| case | before | after | |
| --- | --- | --- | --- |
| `newInstBare` | 1882 | 188 | **10.0x** |
| `newInstFields` | 1957 | 242 | **8.1x** |
| `instCall` / `instField` | 163 / 110 | 157 / 106 | unchanged |
| every other case | | unchanged | |

A scripted instance went from 94us to 9.4us. For reference a script call is about 1.1us, so
instantiation went from ~85 calls to ~9. The measurement was taken with only this library's types in
the collection; a host with a populated root package pays more before the change and the same after.

Full suite green, and `SweepProbe` gives byte-identical output to `HEAD` (30 ok, 9 intentional
parse-error traces).

### Core types kept off the type-resolution path

- [`00cd8111`][00cd8111] checks a core type directly once the `imports` lookup misses.
- Later, [`1e2cd54e`][1e2cd54e] removed the `imports` lookup this entry ends on as what is left; see
  *A typed write remembers how its annotation is enforced*.

A type annotation was costing far more than the check it stands for. `tryCast` runs on every write to
an annotated variable, every annotated argument and every annotated return, and it re-resolved the
annotation from scratch each time: `p.join('.')` (a string allocation, for a path that is one element
in nearly every case), an `imports` lookup, a `TypeCollection` lookup with a `compilePath` and a
`resolve` behind it, and `Type.getSuperClass` (which drags in the blacklist walk) - only to reach
`case 'Int'` and do one `isOfType`.

Measured spread against the identical un-annotated code:

| | before | after | annotation overhead |
| --- | --- | --- | --- |
| `varPlain` -> `varTyped` | 102 -> 176 | 102 -> 141 | **+73% down to +38%** |
| `fnPlain` -> `fnTyped` | 148 -> 226 | 145 -> 193 | **+53% down to +33%** |
| `varTypedObj` | 156 | 152 | |

So `varTyped` -20% and `fnTyped` -15%, with every other case unchanged.

A core type cannot resolve to a script-declared type and is not in the type index, so once the
`imports` lookup misses, the index lookup and the abstract handling have nothing to contribute and the
check runs directly. A boxed abstract still takes the long way round, since it may convert. The
one-element path no longer allocates.

This matters more here than in most forks because typed mode is the default, so the better-typed a
script is, the more it used to pay.

What is left is one `imports` lookup plus the check itself, about 0.2us per typed write. Removing that
needs the resolved type cached on the slot or on the closure, which is a bigger change than this one.

### Block entry, and dead control-flow handlers

- [`a40947bb`][a40947bb] drops the `Stop` handlers nothing throws to any more.
- [`f2a037d3`][f2a037d3] looks a loop counter up once per increment instead of five times.
- [`79c8a96a`][79c8a96a] scopes a block without allocating an iterator. The guard it removes was
  [`af48eebc`][af48eebc]'s replacement for `Lambda.count`, which tested for one entry instead of
  counting them all but still allocated to do it.
- [`1d5d03a8`][1d5d03a8] clears a recycled locals map before it reaches a new scope, the bug fixed on
  the way below. The pool itself came from upstream hscript-insanity, in [`0002455e`][0002455e].
- Later, [`f0e7f888`][f0e7f888] rewrote the increment again, onto the `readLocal`/`writeLocal` pair
  from *Per-operation dispatch*.

Three changes, measured as two steps against same-session controls.

**Step one, dead `Stop` handlers and `increment`.** Nothing has thrown `Stop` since control flow moved
to flags, but the handlers stayed: `loopRun` wrapped **every loop body iteration** in a
`try/catch (err:Stop)`, and `exprReturn` wrapped every call. Separately, `increment` opened with a
`locals.get(id)` whose result was never read, then did `exists` + `getLocal` + `exists` + `setLocal`,
five scope-map operations for one `i++`.

Worth **1 to 3%**, and that is the useful part of the result: removing an untaken `try` buys almost
nothing, because C++ exceptions cost nothing on the path that does not throw. Do not spend time
hunting unused `try` blocks for speed. They are still worth removing as dead code.

**Step two, the map iterator on block entry.** This is where that first bundle's gain actually came
from. Block entry ran `locals.keys().hasNext()` to ask "does this scope hold anything", which
**allocates a map iterator**, on entry to every block, every function body and every loop body.
`restore` is already a no-op when the block declared nothing, so the guard bought nothing and is gone.

| case | before | after | |
| --- | --- | --- | --- |
| `noCall` | 58 | 49 | -16% |
| `blocks` | 182 | 150 | -18% |
| `neg` / `locals` | 128 / 226 | 109 / 193 | -15% |
| `indexSet` / `index` | 132 / 154 | 114 / 133 | -14% |
| `loopPlain` | 68 | 59 | -13% |
| `field` / `not` | 192 / 143 | 168 / 125 | -13% |
| `arith` | 269 | 238 | -12% |
| `call0` / `callRet` | 105 / 107 | 93 / 95 | -11% |
| `method` / `instField` | 104 / 104 | 95 / 95 | -9% |
| `call` | 168 | 159 | -5% |

**This one changes script behaviour**, and deliberately. The guard meant a block leaked its variables
into the enclosing scope whenever that scope happened to hold no locals, so whether `{ var x = 1; } x;`
resolved depended on whether an unrelated `var` had been declared earlier:

| script | before | after |
| --- | --- | --- |
| `{ var x = 1; } x;` | `1` | error |
| `var a = 0; { var x = 1; } x;` | error | error |
| `function f() { { var x = 1; } return x; } f();` | `1` | error |
| `var x = 'outer'; { var x = 'inner'; } x;` | `outer` | `outer` |

The new column is what Haxe does and what the old column already did as soon as any local existed. A
script relying on the old leak would have had to have no locals at all in the enclosing scope.

**A bug fixed on the way.** `duplicate()` with no source map popped a map off the pool and returned it
**without clearing it**, so a new frame inherited whatever the previous frame had left there. That
reached fresh interpreters, whose first frame is pushed with no locals: a scripted class's statics
scope could start out holding another scope's variables. It also made the block guard above
nondeterministic, since it tested a map that might be dirty.

### Control flow by flag instead of exceptions

- [`bc537e63`][bc537e63] propagates `return` by flag.
- [`934502ea`][934502ea] propagates `break` and `continue` the same way.
- [`aac5e06e`][aac5e06e] commits the `ReturnTest` and `LoopTest` suites both were verified with.
- Later, [`a40947bb`][a40947bb] removed the `try/catch` handlers for the `Stop` these two stopped
  throwing; see *Block entry, and dead control-flow handlers*.

The big one. `return`, `break` and `continue` unwound by throwing `Stop`, and a thrown exception costs
microseconds on static targets. `return` alone was about **94% of the cost of every script call**.

Attribution, before touching anything:

| probe | result |
| --- | --- |
| `call0` with pooled locals map | 856 ms |
| `call0` with a fresh map per call | 4825 ms (pooling was already doing the work) |
| `call0` with no scope copy at all | 852 ms (the copy is free) |
| body `return 1` | 869 ms |
| body `{ 1; }` | 112 ms |
| empty loop floor | 61 ms |

This is why the suspects that *looked* obvious (Reflect dispatch, the per-call locals map) were both
wrong, and why attribution comes before optimization.

Verified deltas (same session):

| case | before | after | |
| --- | --- | --- | --- |
| `call` | 941 | 169 | 5.6x |
| `call0` | 867 | 107 | |
| `callRet` | 868 | 108 | now equal to `callNoRet`; the penalty is gone |
| `call_cap20` | 1228 | 445 | |
| `loopCont` | 477 | 88 | 5.4x |
| `loopPlain` | 69 | 72 | unchanged |
| `arith` / `locals` / `blocks` / `field` / `method` | | unchanged | |

### Hot-path types as `@:structInit` classes

- [`168596d8`][168596d8] turns `Variable`, `StackFrame`, `Expr` and `Position` into classes.
- Later, [`a001dec4`][a001dec4] gave the lexer's pushback entries the same treatment, and
  [`af87d5b9`][af87d5b9] found where it does not pay: a type written once and read once. See
  *Cold code out of `expr()`*.
- Later still, [`91a66c5b`][91a66c5b] gave `Variable` an unboxed numeric lane behind `r`, for the
  HashLink backend, which is why construction reads `{ref: value}` now. The interpreter measured
  identical with it, since the accessors inline away.

`Variable`, `StackFrame`, `Expr` and `Position` were anonymous structures, which resolve fields **by
name at runtime** on static targets where a class field is a direct offset. All four are read on
essentially every interpreter step.

| case | before | after | |
| --- | --- | --- | --- |
| `arith` | 441 | 309 | -30% |
| `locals` | 382 | 256 | -33% |
| `blocks` | 309 | 214 | -31% |
| `field` | 314 | 240 | -24% |
| `method` | 157 | 125 | -20% |
| `call` | 1153 | 1028 | -11% |

`@:structInit` keeps the `{r: value}` construction syntax, so the change was contained; only two sites
needed a type annotation. Worth applying to any remaining hot anonymous structure. (`r` later became a
property over `Variable`'s unboxed numeric lane, so construction reads `{ref: value}` now.)

### Hot-path fixes

- [`af48eebc`][af48eebc] makes all three fixes below.
- Later, [`79c8a96a`][79c8a96a] removed the block-entry test entirely. The single-entry test this
  commit put in place of `Lambda.count` still allocated a map iterator; see *Block entry, and dead
  control-flow handlers*.

Three separate issues, measured together (not same-session controlled, so treat as indicative):
`blocks` -15%, `locals` -15%, `arith` -11%, `field` -11%, `method` -6%.

- Block entry called `Lambda.count(locals)` just to test "any locals", on entry to every block,
  including every function and loop body.
- `pushStack` stamped the caller frame by shifting it off, allocating a replacement frame and a new
  `SFilePos`, then unshifting it back, instead of stamping in place.
- A precedence bug: `args?.length ?? 0 != params.length` parses as
  `args?.length ?? (0 != params.length)` because `??` binds looser than `!=`, so the condition was
  `args.length` itself and every call passing arguments ran the argument-fixup path.

### Decomposition

- [`b8372633`][b8372633] splits `Parser` into `Lexer` and `Parser`.
- [`8d9924f7`][8d9924f7] lifts the comprehension and `switch` arms out of `Interp.expr()`.

Behaviour-preserving refactors, both verified performance-neutral: splitting `Parser` into `Lexer`
plus `Parser`, and lifting the two largest arms of `Interp.expr()` (the comprehension machinery and
the `switch` evaluator) into their own methods. `Interp` deliberately stays a single class; extracting
collaborator objects would add a cross-object indirection to operations that run on every AST node.

### Restructure

- [`ad39d368`][ad39d368] reorganizes the packages, one type per file.
- [`c4ab7b2e`][c4ab7b2e] drops the 46 imports the mechanical split left behind.

Package reorganization, verified **performance-neutral** against a same-session control (442/384/314/
1164/310/156 before versus 435/378/306/1118/301/155 after).

### Abstract operators and typed writes (`@:op`)

- [`357914ad`][357914ad] dispatches binary `@:op` operators and checks typed writes.
- [`4135de6a`][4135de6a] also consults the right-hand operand, for `+` and `*`.
- [`f834fa62`][f834fa62] extends dispatch to unary operators and `@:arrayAccess`, the change measured
  at the end of this entry.
- Later, [`c195efd6`][c195efd6] rewrote the binary dispatch these checks sit in; see *Operator
  dispatch by jump table*.

The one change so far that cost time rather than saving it, kept because it buys correctness:
dispatching `@:op` operators on abstracts, and enforcing a variable's declared type on every write
instead of only at its declaration.

Both land in the hottest paths there are, so the first attempt cost 5-6% interpreter-wide (11% on the
emptiest loop). Attribution split it roughly evenly between two additions:

- a type check on the value at every local write, and
- an abstract check on both operands of every `<`, `>`, `<=`, `>=`.

The write path was then rewritten to test the *slot* instead of the value: only a slot that already
holds an abstract needs its box kept in step, and `l.a != null` is a field read where
`v is AbstractValue` is a runtime type check. The declared-type check stays a null test on a field
that is null for every unannotated variable.

| case | before | after | |
| --- | --- | --- | --- |
| `arith` | 276 | 280 | +1.4% |
| `locals` | 230 | 234 | +1.7% |
| `blocks` / `field` / `call0` | | within noise | |
| `noCall` | 60.5 | 63 | +4%, the emptiest possible loop body |

Remaining cost is the two type checks per relational operator, which is what an interpreter without
static types has to pay to tell `a < b` on two abstracts apart from `a < b` on two ints.

Extending the same dispatch to the unary operators and to `@:arrayAccess` then cost **nothing
measurable**, on new `index`, `indexSet`, `not` and `neg` cases added to isolate exactly those paths.
The check disappears into the dynamic dispatch already happening around it, which is worth
remembering before assuming the next one is too expensive: measure the path, do not reason about it
from the relational-operator result.

### Measured and left alone: `strictAccess` and the blacklist

- [`d64a3e2a`][d64a3e2a] adds the guard cases and records the result.
- [`141006bb`][141006bb] is the change that silenced the blacklist traces described below.

Both are on in a shipping host, and both looked like they belonged on this list: `checkAccess` runs on
every field read and write, and the blacklist walk (four `EnumValueMap` lookups and a linear scan
each) sits behind every type resolution. The `fieldGuard` / `methodGuard` / `instFieldGuard` /
`instCallGuard` cases exist to measure exactly that, by re-running the ordinary cases with
`strictAccess` on and a populated blacklist.

The answer is that they cost **nothing measurable** (170 against 173, 96 against 97, 96 against 93).
`checkAccess` returns immediately for a non-scripted receiver, and a scripted one does a single
`indexOf` on a short array. The blacklist walk is per *resolution*, and resolutions are now cached.

Recorded so the next person does not re-derive it. Do not optimize these without a new measurement
showing they became hot.

One side effect worth knowing: with a blacklist configured, the old per-interpreter wildcard import
re-warned about every blacklisted root-package type on every construction. The benchmark run emitted
**120,051** `is blacklisted` traces before the caching change and **0** after, each one a string
interpolation and a trace call. A host that configures a blacklist and then builds interpreters was
paying that in log I/O.

The one caveat of the cache: a blacklist installed *after* scripts have already run does not apply to
packages already cached. Configure it at startup, or call `Interp.clearImportCache()` after changing
it.

### Per-operation dispatch: one hash per name, one field test per accessor

- [`f0e7f888`][f0e7f888] makes all four changes below.
- Later, [`50f88d7c`][50f88d7c] took out an `exists`-then-`get` pair left in the `value.field` fast
  path, which hashed every qualified name four times; see *what a qualified call costs*.
- Later, [`c3f9c4ba`][c3f9c4ba] fixed that fast path skipping a host enum's constructor. A short name
  already in scope, such as `BlendMode.Add` after an import, was answered by reflection and read as
  null, while the qualified `h2d.BlendMode.Add` took the long path and built the constructor. The fast
  path now asks the same question the long one does.

Prompted by [`benchmarks.md`](benchmarks.md), which put plain hscript at roughly **half** this fork's
time on per-operation work while this fork stayed 5x ahead on calls. The gap was not in the operators
themselves: `not`, `neg`, `index` and `indexSet` have bodies here that are within one type check of
hscript's and still cost 1.8x, which puts the cost before the case body, in what every node pays.

Four things:

**Names were hashed two to four times per access.** Reading an identifier ran `captures.exists` then
`captures.get`, then `locals.exists` then a `getLocal` that looked the slot up again. Writing ran
`locals.exists` then a `setLocal` that looked it up again, and `x op= y` did the whole read sequence
and the whole write sequence for the same slot. `readLocal`/`writeLocal` now take the slot the caller
already holds, and every one of those pairs is a single `get` with a null test. `resolve` keeps a
membership test only for the case it exists for, telling "bound to null" apart from "not bound".

**Every accessor dispatch was a string switch.** `getLocal` and `setLocal` fell through a switch over
five string constants (`null`, `never`, `get`, `dynamic`, `default`) to reach `store` for a plain
variable, which is nearly every variable. A `l.get == null` / `l.set == null` test in front skips it.

**`locals` was a call into the call stack.** It is a property, and its getter loaded the stack, loaded
its array, indexed it and null-checked the frame, on every read, write and declaration. The frames
only change in `pushStack`, `shiftStack` and `execute`, so `frameLocals` holds the answer and the
three of them keep it current. The per-node `stack.length == 0` entry guard became a null test on the
same field.

**`resolveField` allocated to recognise a type path.** An array, two enum values and a joined string
per field access, all so `pack.Type.field` could be told from `value.field`. The `value.field` case,
which is nearly all of them, now resolves the base and calls `get` directly, and falls through to the general
path untouched when the base is not a value, which is exactly when a type path is still possible.

Also: `numAdd` tested `is String` twice before reaching the integer case, and `expr` stored two
statics unconditionally per node where a compare avoids hxcpp's write barrier.

| case | before | after | | case | before | after |
| --- | --- | --- | --- | --- | --- | --- |
| `field` | 173 | **119** | | `arith` | 244 | **195** |
| `fieldGuard` | 192 | **121** | | `locals` | 200 | **161** |
| `instField` | 98 | **71** | | `varPlain` | 110 | **86** |
| `instFieldGuard` | 102 | **73** | | `varTyped` | 154 | **128** |
| `index` / `indexSet` | 143 / 120 | **104 / 98** | | `blocks` | 153 | **128** |
| `not` / `neg` | 132 / 130 | **103 / 100** | | `loopPlain` / `loopCont` | 65 / 82 | **47 / 68** |
| `method` | 97 | **86** | | `noCall` | 54 | **43** |

Interpreter-wide **-12.5%**, and 16 to 37% on the per-operation cases the comparison was losing on.
Calls moved 10% as a side effect, since they read and write variables too.

Measured as best-of-3 inside the harness, then the minimum across four paired runs of both binaries,
because a single pair put `neg` at -18% on one run and +6% on the next. All eleven tests
[`../test`](../test) held at the time produced byte-identical output before and after, on both
`--interp` and hxcpp.

### Parsing: most of the "4x slower" was position tracking

- [`a001dec4`][a001dec4] replaces the pushback `List` of anonymous structures and the reflective
  `Type.enumEq` in `maybe`.
- [`9c72f844`][9c72f844], identifier slicing, is the other parser change, in its own entry above.

[`benchmarks.md`](benchmarks.md) put this fork's parser at roughly **4x** hscript's. That number is
real but it is not a like-for-like comparison, and it took a controlled experiment to see why.

hscript's `Expr` is `typedef ExprDef = Expr` unless you compile it with `-D hscriptPos`: without that
define it does not record positions **at all**, and its token pushback is a `GenericStack<Token>`
instead of a list of `{min, max, t}`. The comparison suite passes no defines, so it was measuring a
parser that tracks source positions against one that does not.

Parsing the same 19KB source, best of 5 x 200 parses, three runs:

| | ms/parse | vs hscript as benchmarked |
| --- | --- | --- |
| hscript, no position tracking | 0.684 | 1.00x |
| hscript, `-D hscriptPos` | 1.219 | **1.78x** |
| this fork, before | 1.266 | 1.85x |
| this fork, after | **1.045** | **1.53x** |

Position tracking costs *hscript itself* 1.78x. Against hscript doing the same job this fork was 4%
slower before the changes below and is now **14% faster**. Positions are not optional here, because
error reporting, `posInfos` and the call-stack traces a host renders all depend on them, so the residual
1.53x is the price of a feature, not a defect to chase.

The cross-library suite reaches the same conclusion on its own 11.6KB corpus source, where the effect
is larger still: hscript costs 1.97x with positions on (0.985ms against 0.501ms), and this fork
parses it in 0.819ms, **17% faster** than hscript doing the same job. See
[`benchmarks.md`](benchmarks.md). The two sources disagree on the exact multiple because they exercise
different syntax; they agree on the direction and on the cause.

What changed, all in the lexer:

- The pushback buffer held **anonymous structures** (`List<{min, max, t}>`), which resolve their
  fields by name at runtime on static targets. It is a `@:structInit class TokenEntry` now, for the
  same reason `Variable` and `StackFrame` already were.
- It was a `List`, which allocates a node per pushback on top of the entry. It is an `Array` used as
  a stack; a recursive-descent parser pushes back on every lookahead that does not match, which is
  most of them.
- `maybe` compared tokens with `Type.enumEq`, reflectively, on all 71 call sites. 62 of them pass a
  parameterless constructor, so plain equality is tried first, because it answering true always implies
  structural equality, so the reflective path is only reached for the handful carrying a payload.

That is **-17% on parse**, and a further **-1.6%** on the interpreter from the reduced garbage, which
is worth knowing: allocation during parse is paid for again during execution.

> The -1.6% figure is itself a lesson in the rule at the top of this page. Measured against numbers
> taken earlier in the same session it looked like **-9.4%**, which would have been a nonsense
> attribution, because parsing happens outside the benchmark's timer. Re-running both binaries interleaved
> at the same moment gave -1.6%, and showed the machine had drifted nearly 9% faster in between.

### Cold code out of `expr()`, and a binding without a pair object

- [`af87d5b9`][af87d5b9] makes both changes.
- Later, [`f8289416`][f8289416] ran into the same layout effect from the other side, described at the
  end of this entry.

Two changes aimed at what hxcpp generates rather than at what the interpreter does.

**`expr()` is size-bound.** It is one enormous switch, and every line inside it competes for
registers and instruction cache with the handful of node kinds that actually run in a loop. `ETry`
was the largest cold body still inline, at 44 lines and declaring a closure, and `EMeta` was
another 22 lines. Both moved to `@:noinline` methods. Hot node kinds stay inline, since extracting
one would add a call to something evaluated constantly.

**`declared` is two parallel arrays** instead of an array of `{n, old}` pairs. An entry is pushed for
every variable declaration, every function parameter and every caught exception, so the pair object
was an allocation on one of the most frequently written paths in the interpreter.

Two attempts were measured and dropped, and both are worth knowing:

- A `@:structInit` class for the pair measured 3.1% slower than the anonymous structure. Each entry
  is written once and read once, so there is no repeated field access to win back the allocation.
  The rule in *Hot-path types as `@:structInit` classes* applies to types read many times per
  evaluation, and does not generalise.
- Hoisting `params[i]` into a local and precomputing the rest-argument index in the argument-binding
  loop also measured slower.

The gain is small and not settled: interleaved A/B pairs at x5 gave -1.5%, -3.1%, -5.0% and +0.9%, a
mean near -2% with about 3% of noise per pair either way. Both changes are strictly less work than
what they replace.

The layout effect showed up again in [`f8289416`][f8289416], from the other direction. Adding one
small method to `Interp`, for a conversion no hot path performs, moved every hot path's code around
and cost the whole micro-benchmark 3 to 9%, measured against two builds of the unchanged source that
agreed within 1.5%. The helper went to `AbstractTools` instead. A new method on `Interp` is not free
even when nothing hot calls it.

### Measured and left alone: what a qualified call costs

- [`50f88d7c`][50f88d7c] commits the probe, the measurements, and two tidies on the path.

A qualified call cost about 385ns more than a bare one: over 200k calls, `bump(a)` ran in 438ms and
`Caller.bump(a)` in 515ms. [`test/cpp/SwitchProbe.hx`](../test/cpp/SwitchProbe.hx) reproduces it and
rules out each explanation that looked likely:

- **Not interpreter switching.** Every scripted class builds its own `Interp`, and `expr` keeps a
  static pointing at whichever is evaluating, so a call into another class rewrites it going in and
  coming back. The probe counts exactly two writes per call. Tracking is now skipped unless something
  declares a `null` property accessor, the only thing that reads the static, and the gap moved from
  19% to 18%.
- **Not crossing classes.** Calling a static in the caller's own class through a qualified name cost
  515ms against 517ms for another class's, while the bare call cost 438ms. Qualification is the whole
  difference, and one interpreter per world would not have addressed it.
- **Not reflection.** A direct field read is 1ns, `Reflect.field` and `Reflect.getProperty` are both
  16ns, and a compiled switch over field names, which is what a generated accessor would emit, is
  15ns. That is sixteen of the 385, and no macro can do better than the reflection it would replace.

Two things on the path were tidied anyway, both strictly less work and neither measurable: the
`value.field` fast path from *Per-operation dispatch* asked `exists` of two maps and then `get` of the
same two, and the interpreter tracking above. Most of the 385ns is still unattributed, and finding it
wants a sampling profiler rather than more probes.

### Operator dispatch by jump table instead of a closure table

- [`c195efd6`][c195efd6] replaces the per-interpreter `binops` map with two integer switches.
- [`edd3924a`][edd3924a] drops the doc comment the removed map left behind.
- Later, [`45f7eea0`][45f7eea0] reworked `combine`, the compound-assignment half of this dispatch; see
  the next entry.

`binops` was a `Map<String, Expr->Expr->Dynamic>` built per interpreter, so every operator a script
evaluated cost a string hash, a null test and a call through a closure field, and every interpreter
allocated thirty-eight closures and a map before running anything. A scripted class gets its own
interpreter, so that was thirty-eight per class as well.

**Switching on the operator token is worse than the map it replaces**, which is worth recording
because it is the obvious fix and it is wrong: hxcpp lays a string switch out as a chain of
comparisons, so `<` in a loop condition pays for every operator declared ahead of it. Measured that
way, `arith` went 211 to 227 and `loopPlain` 51 to 63, against the map's own numbers.

Switching on `op.length` and then on `StringTools.fastCodeAt(op, 0)` is two integer switches, which
it lays out as jump tables, and no operator is compared against a string at all. Same session, same
machine, control rebuilt:

| case | before | now | | case | before | now |
| --- | --- | --- | --- | --- | --- | --- |
| `arith` | 211 | 172 | | `varPlain` | 83 | 65 |
| `locals` | 163 | 125 | | `varTyped` | 121 | 106 |
| `blocks` | 127 | 111 | | `varTypedObj` | 136 | 117 |
| `indexSet` | 101 | 82 | | `neg` | 94 | 76 |
| `noCall` | 43 | 33 | | `loopCont` | 67 | 56 |
| `field` | 134 | 119 | | `newInstBare` | 144 | 119 |
| `index` | 113 | 104 | | `newInstFields` | 233 | 212 |
| `call0` | 80 | 73 | | `newInstGuard` | 194 | 169 |

Interpreter-wide that is 16 to 23%. The instantiation rows are the closures no longer being built:
that half of the gain is paid to every scripted class and every scripted instance, whether or not it
ever evaluates an operator.

### Int or Float: whether a sum widens is asked only when it carries

- [`7f450741`][7f450741] stops a `Float` total wrapping into a negative number.
- [`f6b1a03b`][f6b1a03b] makes `Int` overflow wrap as compiled code does, and gives `numAdd`, `numSub`
  and compound assignment the question of whether an operand is meant to widen.
- [`45f7eea0`][45f7eea0] promotes a total accumulated through a host field, and moves that question
  to the carry, which is the speedup below.

A correctness fix first, with a speedup that came with it. On hxcpp a `Dynamic` cannot tell a whole
`Float` from an `Int`: `2.0` answers true to `is Int` and `TInt` to `Type.typeof`, so only a declared
type can say whether a sum is allowed to leave `Int` range. The first commit had addition and
subtraction work a sum out both ways and keep the narrow answer only when it agrees, which measured
inside the noise on the interpreter's own arithmetic loop. The second made them take whether an operand
is meant to widen, so a declared `Int` wraps and a declared `Float` does not.

The third found a field of a host object that the question always answered wrongly, since Haxe keeps
no field types at runtime, so a total accumulated through one wrapped. A field nothing declares now
promotes. In the same change the question moved: compound assignment worked out whether either side
widens before doing anything, while only an addition that carries past `Int` cares. `combine` now
takes the operand expressions and asks on the carry, and `addExpr` and `subExpr` split into an
evaluating half and a value half that the compound path shares.

| lower is faster | before | after |
| --- | --- | --- |
| `field` | 118 | 111 |
| `fieldGuard` | 120 | 114 |
| `instFieldGuard` | 82 | 68 |

Multiplication deliberately keeps wrapping. Every hash and seeded generator is built on it, and
promoting would break them for good: a `Float` carries 53 bits of mantissa, so a product past that
has already lost the low bits the following mask wanted.

### A scripted instance stands on its class's names instead of copying them

- [`7baeca6a`][7baeca6a] stands an instance on its class's variable table.
- [`f57b183d`][f57b183d] does the same for its import table, the second half of this entry.
- Both rest on `Bindings`, which [`b634970b`][b634970b] introduced so compiled globals could see every
  write to `Interp.variables`. The fallback itself is new in `7baeca6a`.

Constructing one used to copy the class's whole variable table into the new instance's interpreter,
so a host's script API cost something per object spawned and the cost grew with the API. Measured by
binding values into a world and timing construction:

| bound values | before, ms | after, ms |
| --- | --- | --- |
| 8 | 5.74us | 4.57us |
| 18 | 6.60us | 3.95us |
| 33 | 9.06us | 3.95us |
| 58 | 12.85us | 3.95us |

About 0.14us per bound value per object, without limit. A host with a hundred names in scope paid
for all hundred every time a script made an object, which is the wrong way round: the more useful the
script API, the slower the game.

`Bindings` carries a fallback now and an instance points at its class's table rather than copying it.
**Reads fall through and writes never do**, so an instance assigning to one of those names gets an
entry of its own from that moment, which is exactly what the copy gave it. `test/common/InstanceScopeTest.hx`
pins that, since it is the whole reason the change is safe.

`newInstBare` 121 to 98, `newInstFields` 211 to 192, `newInstGuard` 170 to 148 on the micro-benchmark,
where only eight values are bound. The flat column above is the part that matters for a real host.

Its `imports` table is stood on the same way, and that one had to be measured rather than assumed:
`imports.get` is the first thing `resolve` does for every bare identifier, so a fallback there lands
on the hottest path in the interpreter. It does not cost anything measurable, and it takes another
40% off constructing an instance.

| case | copying both | standing on both |
| --- | --- | --- |
| `newInstBare` | 98 | 56 |
| `newInstFields` | 192 | 149 |
| `newInstGuard` | 148 | 104 |
| `arith` / `locals` / `field` / `instCall` | 170 / 131 / 112 / 142 | 171 / 131 / 111 / 143 |

Against the numbers this page recorded before any of it, `newInstBare` is 145 to 56 and
`newInstGuard` 197 to 104.

### A typed write remembers how its annotation is enforced

- [`1e2cd54e`][1e2cd54e] caches the plan on the slot, packed into one field. It finishes what
  [`00cd8111`][00cd8111] named as left over in *Core types kept off the type-resolution path*.

`tryCast` resolved the written type name against `imports` on every store, to see whether an import
shadows it, and for `Int` or `String` that is a map miss every time. Then `castCoreType` decided which
type it had been asked about by comparing the name, which hxcpp lays out as a chain of string
compares. Both happen per write, and a store is what a typed variable is for.

The answer only depends on the annotation, which cannot change, and on the import table, which can.
`Bindings.stamp` moves whenever that table or the one it falls back to does, so the slot remembers
the plan and the stamp it was true of, and works it out again when it is not. The plan is an integer,
so the test a core type really is costs an integer switch and no string at all. `varTyped` 109 to 74.

**Three fields on `Variable` cost more than the whole thing gained.** The first version kept the plan,
the stamp and the type's name as separate fields, and measured a 2 to 5% loss spread across cases
that never write a typed variable: `blocks`, `neg`, `indexSet`, `call_cap20`, `newInstGuard`. A
`Variable` is allocated per local per frame, so anything it carries is paid for by every script
whether or not it uses the feature. Packed into one `Int`, low three bits the plan and the rest the
stamp, with the name derived from the plan for the complaint:

| lower is faster | three fields | one packed field |
| --- | --- | --- |
| `varTyped` | 79 | 74 |
| `varTypedObj` | 133 | 124 |
| `blocks` | 118 | 111 |
| `neg` | 84 | 78 |
| whole benchmark | +1% | -2% |

Both against the same rebuilt control. The lesson is about the object rather than the feature: adding
to `Variable` is not free, and a change that looks contained to one path can be paid for on all of
them.

## Where the time goes now

A script call is roughly 1.1us, against about 0.6us for an empty loop iteration, so call overhead is
now in the same order as ordinary interpreter work rather than 15x it. Per-parameter cost is about
0.3us.

A scripted instance is roughly 9.4us to construct, down from 94us.

Standing numbers at the time of writing (hxcpp, best of 3; useful only as a shape, since absolute
values drift with the machine), against the same run of the previous release for the shape of the
gain:

| case | before | now | | case | before | now |
| --- | --- | --- | --- | --- | --- | --- |
| `arith` | 275 | 240 | | `varPlain` | 122 | 102 |
| `locals` | 239 | 197 | | `varTyped` | 197 | 142 |
| `blocks` | 197 | 152 | | `varTypedObj` | 183 | 153 |
| `call` | 176 | 161 | | `fnPlain` | 158 | 146 |
| `field` | 200 | 172 | | `fnTyped` | 239 | 191 |
| `method` | 111 | 96 | | `newInstBare` | 1888 | 188 |
| `index` / `indexSet` | 162 / 142 | 137 / 114 | | `newInstFields` | 1959 | 245 |
| `not` / `neg` | 158 / 135 | 126 / 114 | | `instCall` | 159 | 147 |
| `call0` | 110 | 96 | | `instField` | 110 | 95 |
| `loopPlain` / `loopCont` | 72 / 91 | 62 / 78 | | `noCall` | 62 | 52 |

Interpreter-wide that is 8 to 23%, and 8 to 10x on instantiation.

[0002455e]: https://github.com/MeguminBOT/hxscript/commit/0002455e
[af48eebc]: https://github.com/MeguminBOT/hxscript/commit/af48eebc
[ad39d368]: https://github.com/MeguminBOT/hxscript/commit/ad39d368
[c4ab7b2e]: https://github.com/MeguminBOT/hxscript/commit/c4ab7b2e
[168596d8]: https://github.com/MeguminBOT/hxscript/commit/168596d8
[bc537e63]: https://github.com/MeguminBOT/hxscript/commit/bc537e63
[934502ea]: https://github.com/MeguminBOT/hxscript/commit/934502ea
[b8372633]: https://github.com/MeguminBOT/hxscript/commit/b8372633
[8d9924f7]: https://github.com/MeguminBOT/hxscript/commit/8d9924f7
[aac5e06e]: https://github.com/MeguminBOT/hxscript/commit/aac5e06e
[357914ad]: https://github.com/MeguminBOT/hxscript/commit/357914ad
[4135de6a]: https://github.com/MeguminBOT/hxscript/commit/4135de6a
[f834fa62]: https://github.com/MeguminBOT/hxscript/commit/f834fa62
[1d5d03a8]: https://github.com/MeguminBOT/hxscript/commit/1d5d03a8
[141006bb]: https://github.com/MeguminBOT/hxscript/commit/141006bb
[a40947bb]: https://github.com/MeguminBOT/hxscript/commit/a40947bb
[f2a037d3]: https://github.com/MeguminBOT/hxscript/commit/f2a037d3
[79c8a96a]: https://github.com/MeguminBOT/hxscript/commit/79c8a96a
[00cd8111]: https://github.com/MeguminBOT/hxscript/commit/00cd8111
[d64a3e2a]: https://github.com/MeguminBOT/hxscript/commit/d64a3e2a
[f0e7f888]: https://github.com/MeguminBOT/hxscript/commit/f0e7f888
[a001dec4]: https://github.com/MeguminBOT/hxscript/commit/a001dec4
[5e5425b8]: https://github.com/MeguminBOT/hxscript/commit/5e5425b8
[9c72f844]: https://github.com/MeguminBOT/hxscript/commit/9c72f844
[95637f93]: https://github.com/MeguminBOT/hxscript/commit/95637f93
[9f22bc7c]: https://github.com/MeguminBOT/hxscript/commit/9f22bc7c
[f40e950d]: https://github.com/MeguminBOT/hxscript/commit/f40e950d
[af87d5b9]: https://github.com/MeguminBOT/hxscript/commit/af87d5b9
[50f88d7c]: https://github.com/MeguminBOT/hxscript/commit/50f88d7c
[7f450741]: https://github.com/MeguminBOT/hxscript/commit/7f450741
[f8289416]: https://github.com/MeguminBOT/hxscript/commit/f8289416
[f6b1a03b]: https://github.com/MeguminBOT/hxscript/commit/f6b1a03b
[be646edc]: https://github.com/MeguminBOT/hxscript/commit/be646edc
[91a66c5b]: https://github.com/MeguminBOT/hxscript/commit/91a66c5b
[c3f9c4ba]: https://github.com/MeguminBOT/hxscript/commit/c3f9c4ba
[b634970b]: https://github.com/MeguminBOT/hxscript/commit/b634970b
[c195efd6]: https://github.com/MeguminBOT/hxscript/commit/c195efd6
[45f7eea0]: https://github.com/MeguminBOT/hxscript/commit/45f7eea0
[7baeca6a]: https://github.com/MeguminBOT/hxscript/commit/7baeca6a
[f57b183d]: https://github.com/MeguminBOT/hxscript/commit/f57b183d
[1e2cd54e]: https://github.com/MeguminBOT/hxscript/commit/1e2cd54e
[edd3924a]: https://github.com/MeguminBOT/hxscript/commit/edd3924a
