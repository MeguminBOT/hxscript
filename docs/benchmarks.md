# Comparing Haxe scripting libraries

Six hscript-family libraries running identical scripts.

## Read this first: different, not better

**No library here is "the best one."** Split the suite in two and the ranking inverts: hxScript is
mid-table on the cost of one ordinary operation and first by a wide margin on the cost of one
function call. Both are in the summary below, and neither is the summary on its own.

The call gap has one cause, and it is not cleverness. Every other library unwinds `return`, `break`
and `continue` by **throwing an exception**, and a thrown exception costs microseconds on a static
target. hxScript signals them with flags. That is also why the corpus total flatters it: totals are
dominated by the call cases, so quote the per-operation and per-call averages instead.

`callCap20` is `call1` with twenty more variables in the enclosing scope and nothing else changed, so
the pair isolates a second design difference: whether building a call frame copies the captured
scope, and so costs something per captured variable. Four of the six pay about 30% for it. hxScript
and hscript-improved pay nothing.

The same applies to features. hscript is small and fast and has no scripted classes.
hscript-improved has them and instantiates one faster than hxScript does, while hxScript calls
their methods several times faster, because its classes are generated bridges with real fields and theirs are
a shell over a map. RuleScript adds imports, usings and string interpolation. hscript-iris wraps a
fast interpreter in a friendlier host API. hxScript and hscript-insanity carry the largest language
surface (abstracts, modules, typedefs, properties, typed mode) and pay for it per operation.

Pick the one whose trade-off matches your workload. If you are choosing, run this suite with cases
that look like *your* scripts rather than trusting a total.

## What was measured

Every library is driven through its own public API, with the **same** script sources. Parsing is
untimed and separated from execution, so the numbers are interpreter speed rather than setup.

Every case ends in an expression whose value is known, and the harness checks it. A library that
parses and "runs" a case without doing the work is reported as `WRONG`, not as infinitely fast. That
check earned its place: it caught two mistakes in the expected values, and three genuine behavioural
differences between libraries that timings alone would have hidden.

### How a case is run

A case is a source string, an iteration count, and the value the source must evaluate to. The loop is
written **into the script**, not around it, so what is timed is the interpreter running a loop rather
than the host calling into it N times:

```haxe
// `call1`, at 100,000 iterations, expected value "7"
function f(a) return a;
var i = 0; var s = 0;
while (i < 100000) { s = f(7); i += 1; }
s;
```

Each library supplies two closures to
[`XBench.run`](../test/bench/xbench/XBench.hx) and nothing else, so the harness never touches a library's
internals:

- **`prepare(src)`** parses and builds whatever that library needs, and is **untimed**.
- **`exec(handle)`** runs the prepared program and returns its value, and is **timed**.

Per case the harness then:

1. calls `prepare` once; if it throws or returns null the case is `not supported` for that library and
   nothing is timed
2. runs 5 reps. Each rep calls `prepare` **again**, then times `exec` alone. Re-preparing every rep
   matters for fairness: a library that mutates its program in place or caches state on the
   interpreter would otherwise look faster on reps 2-5 than one that does not
3. takes the **median** of the 5 timings
4. compares the returned value against the expected one, and records `ok` or `wrong`

Expected values are derived from the iteration count (`call1` expects `7`, `loopPlain` expects the
count itself), so the same corpus and the same checking work at any scale.

The median rather than the fastest run: best-of-N answers "how fast can this go when nothing
interferes", which flatters whichever library got the quietest slice of the machine. The median
answers "what does this usually cost", which is what a host budgeting a frame needs, and an unlucky
scheduler spike moves it no more than a lucky one does.

Each case runs in its **own process**, with a 300-second timeout, because some libraries hang or
crash outright on some inputs and would otherwise take the rest of the run down with them. Each
emits one machine-readable line:

```
R|<lib>|<case>|<tier>|<iterations>|<status>|<median ms>|<value>
```

`tier` is `core` or `ext`, recording whether the case uses only constructs every library is expected to have.
It is not the `kind` column in the per-case table below, which `collate.py` derives from the case
name to decide which average the row feeds.

`collate.py` reads those lines and divides: microseconds per iteration is
`median ms x 1000 / iterations`. Nothing in the tables is a raw timing, which is why they stay
comparable across scales.

Parse throughput is measured separately, and is the only place `prepare` is timed: one 11.6KB source
of 80 small functions, median of 5, no execution.

### Built with `-dce no`, and that is a correctness setting

Under hxcpp's default `-dce std` the compiler eliminates `IntIterator.hasNext` and `next`: every call
site inlines them, so nothing references them statically. An interpreter reaching them by reflection
then finds a null field, and `for (i in 0...n)` fails, **in the host's build, not in the library**.
Earlier versions of this page reported that as a defect in four of the six libraries. It was not.

Everything here is therefore built with `-dce no`, which measures the libraries rather than the build
settings. A probe over 83 commonly-scripted standard-library members found **42 unreachable** under
`-dce std` against 3 under `-dce no`; the catalogue is in
[`embedding.md`](embedding.md#dead-code-elimination), and it is worth reading before
concluding that any scripting library "cannot do" something.

### Every library is built with position tracking

hscript's `Expr` is `typedef ExprDef = Expr` unless it is built with `-D hscriptPos`: without that
define it records no source positions **at all**. hscript-improved, hscript-iris and RuleScript
inherit the same switch.

hxScript cannot turn positions off, because error reporting, `posInfos` and call-stack traces depend
on them. Comparing against a build that records nothing would not be measuring the same job, so every
library in the comparison is built **with** them. What the switch costs the libraries that have it is
reported separately at the end, where it reads as the price of a feature rather than a ranking.

### One scale

The corpus runs at 100,000 iterations. Three scales spanning 20x were used to establish that the
ranking is a property of the interpreters rather than a warm-up or fixed-setup artefact; it held,
moving by at most a few percent, so re-establishing it on every run is not worth three times the wall
time. `SCALES="25000 100000 500000"` checks it again after a change that could plausibly disturb it.

## Results

<!-- BEGIN GENERATED: test/bench/xbench/collate.py -->

### Every case, microseconds per iteration at 100,000

**Lower is faster.** Every number on this page is a cost, in microseconds or milliseconds,
so a smaller one is better. Two places invert that and say so where they appear: the
`relative` row, where a bigger multiple means slower, and the frame-budget table, where a
bigger count means more script fits.

One row per case, and the only per-case table in this document. `kind` is which average the
row feeds: `op` and `call` are averaged separately because they differ by design rather than
by degree. `unwind` cases are in neither, being dominated by how a library implements
`continue` and `throw`, and nor are `compound` ones, which do far more than one operation per
iteration and would describe themselves rather than the interpreter.

<details>
<summary><strong>43 cases, click to expand</strong></summary>

| case | kind | **hxScript** | insanity | hscript | improved | iris | rulescript |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `noCall` | op | 0.421 | 0.989 | 0.413 | 0.639 | 0.423 | 0.542 |
| `loopPlain` | op | 0.475 | 1.140 | 0.439 | 0.606 | 0.462 | 0.592 |
| `loopCont` | unwind | 0.636 | 3.645 | 2.648 | 2.816 | 2.538 | 3.362 |
| `postIncr` | op | 0.445 | 0.978 | 0.384 | 0.521 | 0.395 | 0.485 |
| `arith` | op | 0.580 | 1.368 | 0.562 | 0.802 | 0.569 | 0.714 |
| `locals` | op | 0.510 | 1.259 | 0.498 | 0.751 | 0.538 | 0.661 |
| `blocks` | op | 0.638 | 1.270 | 0.564 | 0.964 | 0.582 | 0.772 |
| `field` | op | 0.551 | 1.170 | 0.451 | 0.723 | 0.470 | 0.625 |
| `fieldSet` | op | 0.582 | 1.088 | 0.453 | 0.783 | 0.494 | 0.600 |
| `method` | op | 1.037 | 1.583 | 0.720 | 1.168 | 0.741 | 0.925 |
| `index` | op | 0.485 | 1.127 | 0.474 | 0.752 | 0.492 | 0.641 |
| `indexSet` | op | 0.467 | 1.017 | 0.482 | 0.698 | 0.512 | 0.633 |
| `not` | op | 0.502 | 1.142 | 0.507 | 0.803 | 0.511 | 0.673 |
| `neg` | op | 0.459 | 1.053 | 0.450 | 0.673 | 0.470 | 0.592 |
| `call0` | call | 0.838 | 4.731 | 3.689 | 4.181 | 3.661 | 4.345 |
| `call1` | call | 1.256 | 5.166 | 4.073 | 4.497 | 3.991 | 4.719 |
| `call3` | call | 1.826 | 6.037 | 4.458 | 4.883 | 4.511 | 5.077 |
| `callCap20` | call | 1.243 | 8.636 | 6.216 | 4.460 | 6.247 | 7.197 |
| `forRange` | op | 0.185 | 0.315 | 0.188 | 0.243 | 0.164 | 0.261 |
| `forArray` | op | 0.184 | 0.317 | 0.212 | 0.282 | 0.177 | 0.255 |
| `arrayDecl` | op | 0.957 | 1.610 | 0.722 | 1.224 | 0.702 | 0.973 |
| `strConcat` | op | 0.777 | 1.789 | 0.967 | 1.172 | 0.963 | 1.159 |
| `ternary` | op | 0.639 | 1.484 | 0.623 | 0.870 | 0.633 | 0.839 |
| `anonField` | op | 0.817 | 1.433 | 0.634 | 1.116 | 0.671 | 0.862 |
| `closureCall` | op | 1.204 | 5.754 | 4.421 | 4.979 | 4.495 | 5.516 |
| `hostMethod` | op | 0.992 | 1.559 | 0.715 | 1.044 | 0.716 | 0.971 |
| `hostStatic` | op | 1.375 | 1.785 | not supported | not supported | 0.865 | 1.143 |
| `arrayPush` | op | 1.015 | 1.425 | 0.674 | 0.974 | 0.695 | 0.849 |
| `boolLogic` | op | 0.685 | 1.733 | 0.714 | 1.000 | 0.729 | 0.943 |
| `modArith` | op | 0.623 | 1.506 | 0.663 | 0.887 | 0.620 | 0.871 |
| `switch` | op | 0.819 | 1.486 | 0.629 | 0.864 | 0.627 | 0.831 |
| `tryCatch` | unwind | 3.575 | 4.939 | 4.163 | 4.549 | 3.985 | 5.225 |
| `strInterp` | op | 0.961 | 1.556 | WRONG (v$n) | WRONG (v$n) | 0.730 | 0.849 |
| `mapLiteral` | op | 1.329 | 2.115 | 1.210 | 1.524 | 1.103 | 1.481 |
| `arrayCompr` | compound | 2.977 | 4.507 | 3.386 | 5.351 | 6.494 | 7.290 |
| `varTyped` | op | 0.449 | 1.001 | 0.410 | 0.658 | 0.412 | not supported |
| `fnTyped` | call | 1.761 | 5.428 | 3.961 | 4.435 | 3.979 | not supported |
| `classNew` | compound | 2.849 | 73.335 | not supported | 4.920 | not supported | not supported |
| `classCall` | call | 1.564 | 5.520 | not supported | 4.651 | not supported | not supported |
| `classField` | op | 0.659 | 1.261 | not supported | 0.897 | not supported | not supported |
| `stringSwitch` | op | 0.807 | 1.391 | 0.605 | 0.855 | 0.610 | 0.808 |
| `nullCoal` | op | 0.435 | 1.174 | 0.466 | 0.681 | 0.497 | 0.645 |
| `abstractOp` | op | 5.543 | 10.848 | not supported | not supported | not supported | not supported |

</details>

### Summary, over the 35 cases every library ran

| | **hxScript** | insanity | hscript | improved | iris | rulescript |
| --- | --- | --- | --- | --- | --- | --- |
| us per operation (28 cases), lower is faster | 0.665 | 1.438 | 0.709 | 0.986 | 0.716 | 0.919 |
| us per call (4 cases), lower is faster | 1.291 | 6.143 | 4.609 | 4.505 | 4.603 | 5.334 |
| parse, ms, lower is faster | 0.879 | 1.21 | 1.193 | 3.297 | 0.851 | 1.395 |
| corpus total, ms, lower is faster | 3097 | 7794 | 4847 | 5834 | 5149 | 6293 |
| total relative to hxScript, higher is slower | 1.00x | 2.52x | 1.57x | 1.88x | 1.66x | 2.03x |

```mermaid
xychart-beta
    title "Cost of one operation at 100,000 iterations"
    x-axis ["hxScript", "hscript", "iris", "rulescript", "improved", "insanity"]
    y-axis "microseconds" 0 --> 1.654
    bar [0.665, 0.709, 0.716, 0.919, 0.986, 1.438]
```

```mermaid
xychart-beta
    title "Cost of one call at 100,000 iterations"
    x-axis ["hxScript", "improved", "iris", "hscript", "rulescript", "insanity"]
    y-axis "microseconds" 0 --> 7.064
    bar [1.291, 4.505, 4.603, 4.609, 5.334, 6.143]
```

### How much script fits in one frame

The per-operation and per-call averages read as a budget. A 60Hz frame is 16.667ms;
the second pair is a 2ms slice of it, which is a more realistic allowance once
rendering and physics are paid for. Whole units, rounded down.

**Higher is better here**, unlike everywhere else on this page: these are how much
script fits, not what it costs.

**Derived, not measured at this scale.** Timing a frame's worth of work directly is dominated
by noise, because a few hundred operations is far too short an interval to time on a preemptive OS.
These come from the 100,000-iteration averages above, which are stable, multiplied back out.
Read it the other way for a budget you already have in mind:

```
per-call us  x  calls per frame  x  60  =  us per second spent in script
```

| | **hxScript** | insanity | hscript | improved | iris | rulescript |
| --- | --- | --- | --- | --- | --- | --- |
| operations per 60Hz frame | 25,060 | 11,586 | 23,521 | 16,909 | 23,264 | 18,145 |
| calls per 60Hz frame | 12,913 | 2,713 | 3,615 | 3,699 | 3,621 | 3,124 |
| operations per 2ms slice | 3,007 | 1,390 | 2,822 | 2,029 | 2,791 | 2,177 |
| calls per 2ms slice | 1,549 | 325 | 433 | 443 | 434 | 374 |

### What position tracking costs the libraries that can switch it off

Not a ranking. hxScript cannot turn positions off, so the comparison above is built
with them on everywhere; this is what that decision costs the others. At 100,000.

| | hscript | improved | iris | rulescript |
| --- | --- | --- | --- | --- |
| us per operation, with | 0.709 | 0.986 | 0.716 | 0.919 |
| us per operation, without | 0.639 | 0.888 | 0.707 | 0.759 |
| cost | 10.9% | 11.0% | 1.3% | 21.1% |
| parse with, ms | 1.193 | 3.297 | 0.851 | 1.395 |
| parse without, ms | 0.595 | 2.828 | 0.563 | 0.647 |

<!-- END GENERATED -->

## Behavioural differences found

These came out of the value checking, not the timing, and matter more than any of the numbers above
if you are choosing a library. All were reproduced directly, outside the harness.

**`for (i in 0...n)` works everywhere, and a previous version of this page said otherwise.** It was
recorded as broken on hxcpp in hscript, hscript-improved, RuleScript and hscript-insanity, blamed on
`IntIterator.hasNext`/`next` being `inline` and having no runtime form. Both halves were wrong. They
have a runtime form; `-dce std` removes it because every call site inlines them, so nothing references
them. Build with `-dce no` and all six libraries run `forRange` and `arrayCompr` correctly. The whole
`CRASH` column this page used to carry is gone, and so are the nine timeouts behind it.

Worth stating plainly because the failure looks exactly like a library defect from the outside: a
script gets `Cannot call null`, or on a build without position tracking it silently abandons the rest
of the program. Neither points at the host's own compiler flags, which is where the cause is. See
[`embedding.md`](embedding.md#dead-code-elimination) for what else DCE takes with it.

**`++` works in all six**, and every loop counter in this suite still uses `i += 1`, which is equally
fair to all of them and does not depend on which version of a library is checked out. `postIncr`
isolates the construct.

**RuleScript does not build against current hscript.** It needs an hscript predating
`Interp.makeKeyValueIterator` and `resolveType`; it was pinned to hscript `609c489` here. Its
`extraParams.hxml` also has to be passed by hand when using `-cp` instead of haxelib, since it patches
hscript's enums at compile time.

**Single-quote string interpolation** (`'v$n'`) is absent in hscript and hscript-improved, which
return the literal text. hxScript, hscript-insanity, hscript-iris and RuleScript interpolate.

## What was tested

Haxe 4.3.7, hxcpp, `-dce no`, Windows, single machine, one sitting, 24-thread build.

| library | version | notes |
| --- | --- | --- |
| hxScript | working tree | always tracks positions |
| [hscript-insanity](https://github.com/inky03/hscript-insanity) ("insanity") | `ad67b16` (main) | always tracks positions |
| [hscript](https://github.com/HaxeFoundation/hscript) | `7d5eacc` (master, post-2.7.0) | built both ways |
| [hscript-improved](https://github.com/CodenameCrew/hscript-improved) | `48ec0f4` (master) | built both ways |
| [hscript-iris](https://github.com/pisayesiwsi/hscript-iris) | `62d828b` (**dev**) | built both ways |
| [RuleScript](https://github.com/Kriptel/RuleScript) | `b5b377a` (master) | built both ways; needs hscript `609c489` |

Every library is at its default branch's tip, except hscript-iris, measured on `dev`.

**Only insanity moved since the previous run**, by 28 commits to the tip of `main`. hscript,
hscript-improved, hscript-iris and RuleScript are at the same commits as before, and the corpus is
the same too, so for once this table and the previous one can be read against each other.

That makes the four unchanged libraries a control, and a useful one:

| lower is faster | previous | this run | change |
| --- | --- | --- | --- |
| hscript, us per operation | 0.739 | 0.709 | -4% |
| hscript-improved | 0.996 | 0.986 | -1% |
| hscript-iris | 0.719 | 0.716 | 0% |
| RuleScript | 0.916 | 0.919 | 0% |
| **hxScript** | **0.798** | **0.665** | **-17%** |
| insanity, which did move | 1.812 | 1.438 | -21% |

Four libraries whose code did not change moved by at most 4%, which is what this machine's noise
looks like. hxScript moved by 17% and its corpus total by 14%, from operator dispatch, instance
construction and typed writes; see [performance.md](performance.md). Ordinarily the rule stands:
read a column against the others in ITS OWN table, never against a number from an earlier run.

**RuleScript's figures are new rather than changed.** Its build had been failing, and the runner was
silently falling back to binaries left behind by an earlier run: they answered the cases the corpus
held when they were built and reported everything added since as `crash`. Both halves are fixed.
The build parameters named `hscript.Ast`, a module neither hscript checkout declares, where
RuleScript's own `extraParams.hxml` names `hscript.Tools`; and `run.sh` now removes a binary before
rebuilding it, so a failed build can no longer leave a usable one behind.

### The machine

| part | |
| --- | --- |
| CPU | AMD Ryzen 9 3900X, 12 cores / 24 threads |
| RAM | 32GB DDR4-3200 CL14 |
| storage | WD Black SN7100 2TB NVMe |

Every figure is single-threaded: the thread count built the binaries, it did not run the corpus.

## Reproducing

The harness is in [`../test/bench/xbench`](../test/bench/xbench). In short:

```sh
LIBS=/path/to/library/checkouts sh test/bench/xbench/run.sh
```

`LIBS` wants checkouts named `insanity`, `hscript`, `improved`, `iris`, `rulescript` and
`hscript-rs` (the older hscript RuleScript needs). Anything missing is skipped, and the collator
drops absent libraries rather than emptying the shared-case set, so a subset produces a table for
that subset.

Scales default to `100000` and are settable. Passing more than one also brings back the
scale-stability table:

```sh
SCALES="25000 100000 500000" LIBS=... sh test/bench/xbench/run.sh
```

They must be multiples of 1000, which is the array length `forArray` walks.

`DCE` defaults to `no` and should stay there; see above. `DCE=std` reproduces what a host with default
compiler flags actually gets, which is a different and also useful question.

`collate.py` writes the whole of the Results section above. Paste its output between the two
`GENERATED` markers rather than editing the tables by hand: it is one table of record plus its
summaries, so a re-run replaces all of it in one go and there is nothing to keep in sync.

Every hscript-derived library is built twice, once with
[`hscript-pos.hxml`](../test/bench/xbench/hscript-pos.hxml) and once without. Do not drop the
position-tracking builds when comparing against hxScript: without that define those libraries record
no source positions at all, and hxScript cannot work that way.

## Caveats

**Read the ratios, not the numbers.** Absolute microseconds drift with machine state by well over
10%, which is more than most of the differences between neighbouring libraries here. Rebuild and
re-run everything in one sitting before comparing anything, and never merge a re-run of one library
into a table measured in another sitting.

**The noise floor of this suite is about 5%.** Running the whole thing twice on the same machine,
median of 5 at 100,000 iterations, moved the per-operation averages by at most 2.4% and the per-call
averages by at most 5.0% (hscript-iris; every other library stayed inside 2.4%). Rankings and ratios
did not change. So treat a gap under roughly 5% as unresolved by this suite rather than as a
difference, and re-run before believing one.

**The shared-case set excludes the cases some library cannot run**, so the totals and averages
describe a common subset and say nothing about the features that subset leaves out: `postIncr` (iris
has no `++`), `strInterp` (three libraries return the literal text), `varTyped` and `fnTyped`
(RuleScript rejects type annotations), and `classNew`/`classCall`/`classField` (only some libraries
have scripted classes). Excluding them is generous to the libraries that fail them. The per-case list
is where those live.

**`arrayCompr` and `classNew` are excluded from the averages too**, for a different reason: they do
far more than one operation per iteration, so a mean including them describes the outlier. Leaving
`arrayCompr` in moved hscript-iris's per-operation figure from 0.53us to 1.02us on this run, which
would have reported it as twice as slow as it is.

**A micro-benchmark is not an application.** These cases isolate single operations on purpose, so
they overstate interpreter differences relative to a real script that also touches the host's own
code. Use them to understand *where* libraries differ, then measure your own workload.
