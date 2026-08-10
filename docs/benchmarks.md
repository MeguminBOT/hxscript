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
[`XBench.run`](../test/xbench/XBench.hx) and nothing else, so the harness never touches a library's
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

<!-- BEGIN GENERATED: test/xbench/collate.py -->
### Every case, microseconds per iteration at 100,000

One row per case, and the only per-case table in this document. `kind` is which average the
row feeds: `op` and `call` are averaged separately because they differ by design rather than
by degree. `unwind` cases are in neither, being dominated by how a library implements
`continue` and `throw`, and nor are `compound` ones, which do far more than one operation per
iteration and would describe themselves rather than the interpreter.

<details>
<summary><strong>33 cases, click to expand</strong></summary>

| case | kind | **hxScript** | insanity | hscript | improved | iris | rulescript |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `noCall` | op | 0.463 | 1.058 | 0.386 | 0.626 | 0.410 | 0.521 |
| `loopPlain` | op | 0.497 | 1.123 | 0.420 | 0.641 | 0.442 | 0.561 |
| `loopCont` | unwind | 0.683 | 5.135 | 4.163 | 4.508 | 4.331 | 4.701 |
| `postIncr` | op | 0.453 | 1.055 | 0.370 | 0.518 | 0.374 | 0.474 |
| `arith` | op | 0.652 | 1.273 | 0.536 | 0.770 | 0.564 | 0.720 |
| `locals` | op | 0.575 | 1.355 | 0.466 | 0.762 | 0.508 | 0.644 |
| `blocks` | op | 0.665 | 1.644 | 0.569 | 0.985 | 0.563 | 0.762 |
| `field` | op | 0.587 | 1.346 | 0.457 | 0.712 | 0.462 | 0.606 |
| `fieldSet` | op | 0.636 | 1.227 | 0.431 | 0.746 | 0.466 | 0.581 |
| `method` | op | 1.020 | 1.695 | 0.679 | 1.064 | 0.712 | 0.894 |
| `index` | op | 0.529 | 1.192 | 0.435 | 0.674 | 0.463 | 0.600 |
| `indexSet` | op | 0.552 | 1.149 | 0.446 | 0.691 | 0.471 | 0.582 |
| `not` | op | 0.546 | 1.234 | 0.458 | 0.721 | 0.475 | 0.653 |
| `neg` | op | 0.518 | 1.168 | 0.425 | 0.688 | 0.458 | 0.587 |
| `call0` | call | 0.820 | 8.768 | 7.406 | 7.867 | 7.546 | 8.044 |
| `call1` | call | 1.198 | 9.349 | 7.695 | 8.285 | 7.806 | 8.395 |
| `call3` | call | 1.820 | 10.202 | 8.071 | 8.760 | 8.180 | 8.920 |
| `callCap20` | call | 1.210 | 12.763 | 10.039 | 8.211 | 10.130 | 10.801 |
| `forRange` | op | 0.174 | 0.321 | 0.175 | 0.266 | 0.148 | 0.216 |
| `forArray` | op | 0.184 | 0.342 | 0.186 | 0.285 | 0.159 | 0.236 |
| `arrayDecl` | op | 1.001 | 1.812 | 0.693 | 1.153 | 0.648 | 0.932 |
| `strConcat` | op | 0.826 | 1.986 | 1.156 | 1.494 | 1.246 | 1.340 |
| `ternary` | op | 0.740 | 1.472 | 0.687 | 0.978 | 0.721 | 0.916 |
| `switch` | op | 0.847 | 1.648 | 0.699 | 0.960 | 0.710 | 0.896 |
| `tryCatch` | unwind | 7.384 | 8.962 | 7.438 | 7.893 | 7.656 | 8.099 |
| `strInterp` | op | 1.004 | 1.540 | WRONG (v$n) | WRONG (v$n) | 0.742 | 0.836 |
| `mapLiteral` | op | 1.344 | 2.197 | 1.148 | 1.507 | 1.073 | 1.405 |
| `arrayCompr` | compound | 3.012 | 4.402 | 3.286 | 5.130 | 10.851 | 11.315 |
| `varTyped` | op | 0.660 | 1.046 | 0.387 | 0.622 | 0.408 | not supported |
| `fnTyped` | call | 1.657 | 9.709 | 7.660 | 8.446 | 7.954 | not supported |
| `classNew` | compound | 6.925 | 102.792 | not supported | 4.598 | not supported | not supported |
| `classCall` | call | 1.499 | not supported | not supported | 8.561 | not supported | not supported |
| `classField` | op | 0.695 | 1.469 | not supported | 0.852 | not supported | not supported |

</details>

### Summary, over the 27 cases every library ran

| | **hxScript** | insanity | hscript | improved | iris | rulescript |
| --- | --- | --- | --- | --- | --- | --- |
| us per operation (20 cases) | 0.640 | 1.315 | 0.541 | 0.812 | 0.554 | 0.706 |
| us per call (4 cases) | 1.262 | 10.271 | 8.303 | 8.281 | 8.415 | 9.040 |
| parse, ms | 0.751 | 1.235 | 0.943 | 2.611 | 0.691 | 1.212 |
| corpus total, ms | 2894 | 8588 | 5892 | 6690 | 6757 | 7440 |
| total relative to hxScript | 1.00x | 2.97x | 2.04x | 2.31x | 2.33x | 2.57x |

```mermaid
xychart-beta
    title "Cost of one operation at 100,000 iterations"
    x-axis ["hscript", "iris", "hxScript", "rulescript", "improved", "insanity"]
    y-axis "microseconds" 0 --> 1.512
    bar [0.541, 0.554, 0.640, 0.706, 0.812, 1.315]
```

```mermaid
xychart-beta
    title "Cost of one call at 100,000 iterations"
    x-axis ["hxScript", "improved", "hscript", "iris", "rulescript", "insanity"]
    y-axis "microseconds" 0 --> 11
    bar [1.262, 8.281, 8.303, 8.415, 9.040, 10.271]
```

### How much script fits in one frame

The per-operation and per-call averages read as a budget. A 60Hz frame is 16.667ms;
the second pair is a 2ms slice of it, which is a more realistic allowance once
rendering and physics are paid for. Whole units, rounded down.

**Derived, not measured at this scale.** Timing a frame's worth of work directly is dominated
by noise, because a few hundred operations is far too short an interval to time on a preemptive OS.
These come from the 100,000-iteration averages above, which are stable, multiplied back out.
Read it the other way for a budget you already have in mind:

```
per-call us  x  calls per frame  x  60  =  us per second spent in script
```

| | **hxScript** | insanity | hscript | improved | iris | rulescript |
| --- | --- | --- | --- | --- | --- | --- |
| operations per 60Hz frame | 26,021 | 12,675 | 30,796 | 20,524 | 30,107 | 23,599 |
| calls per 60Hz frame | 13,204 | 1,622 | 2,007 | 2,012 | 1,980 | 1,843 |
| operations per 2ms slice | 3,122 | 1,521 | 3,695 | 2,462 | 3,612 | 2,831 |
| calls per 2ms slice | 1,584 | 194 | 240 | 241 | 237 | 221 |

### What position tracking costs the libraries that can switch it off

Not a ranking. hxScript cannot turn positions off, so the comparison above is built
with them on everywhere; this is what that decision costs the others. At 100,000.

| | hscript | improved | iris | rulescript |
| --- | --- | --- | --- | --- |
| us per operation, with | 0.541 | 0.812 | 0.554 | 0.706 |
| us per operation, without | 0.470 | 0.744 | 0.524 | 0.583 |
| cost | 15.3% | 9.1% | 5.7% | 21.1% |
| parse with, ms | 0.943 | 2.611 | 0.691 | 1.212 |
| parse without, ms | 0.515 | 2.311 | 0.535 | 0.564 |
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
| [hscript-insanity](https://github.com/inky03/hscript-insanity) ("insanity") | `f3f4099` (main) | always tracks positions |
| [hscript](https://github.com/HaxeFoundation/hscript) | `7d5eacc` (master, post-2.7.0) | built both ways |
| [hscript-improved](https://github.com/CodenameCrew/hscript-improved) | `48ec0f4` (master) | built both ways |
| [hscript-iris](https://github.com/pisayesiwsi/hscript-iris) | `62d828b` (**dev**) | built both ways |
| [RuleScript](https://github.com/Kriptel/RuleScript) | `b5b377a` (master) | built both ways; needs hscript `609c489` |

Every library is at its default branch's tip, except hscript-iris, measured on `dev`.

### The machine

| part | |
| --- | --- |
| CPU | AMD Ryzen 9 3900X, 12 cores / 24 threads |
| RAM | 32GB DDR4-3200 CL14 |
| storage | WD Black SN7100 2TB NVMe |

Every figure is single-threaded: the thread count built the binaries, it did not run the corpus.

## Reproducing

The harness is in [`../test/xbench`](../test/xbench). In short:

```sh
LIBS=/path/to/library/checkouts sh test/xbench/run.sh
```

`LIBS` wants checkouts named `insanity`, `hscript`, `improved`, `iris`, `rulescript` and
`hscript-rs` (the older hscript RuleScript needs). Anything missing is skipped, and the collator
drops absent libraries rather than emptying the shared-case set, so a subset produces a table for
that subset.

Scales default to `100000` and are settable. Passing more than one also brings back the
scale-stability table:

```sh
SCALES="25000 100000 500000" LIBS=... sh test/xbench/run.sh
```

They must be multiples of 1000, which is the array length `forArray` walks.

`DCE` defaults to `no` and should stay there; see above. `DCE=std` reproduces what a host with default
compiler flags actually gets, which is a different and also useful question.

`collate.py` writes the whole of the Results section above. Paste its output between the two
`GENERATED` markers rather than editing the tables by hand: it is one table of record plus its
summaries, so a re-run replaces all of it in one go and there is nothing to keep in sync.

Every hscript-derived library is built twice, once with
[`hscript-pos.hxml`](../test/xbench/hscript-pos.hxml) and once without. Do not drop the
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
