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

One row per case, and the only per-case table in this document. `kind` is which average the
row feeds: `op` and `call` are averaged separately because they differ by design rather than
by degree. `unwind` cases are in neither, being dominated by how a library implements
`continue` and `throw`, and nor are `compound` ones, which do far more than one operation per
iteration and would describe themselves rather than the interpreter.

<details>
<summary><strong>43 cases, click to expand</strong></summary>

| case | kind | **hxScript** | insanity | hscript | improved | iris | rulescript |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `noCall` | op | 0.531 | 1.292 | 0.430 | 0.644 | 0.422 | 0.561 |
| `loopPlain` | op | 0.581 | 1.361 | 0.455 | 0.633 | 0.457 | 0.591 |
| `loopCont` | unwind | 0.797 | 3.947 | 2.669 | 2.922 | 2.561 | 3.318 |
| `postIncr` | op | 0.491 | 1.308 | 0.388 | 0.521 | 0.397 | 0.486 |
| `arith` | op | 0.739 | 1.660 | 0.569 | 0.805 | 0.555 | 0.733 |
| `locals` | op | 0.658 | 1.630 | 0.518 | 0.764 | 0.520 | 0.662 |
| `blocks` | op | 0.736 | 1.886 | 0.627 | 0.970 | 0.599 | 0.765 |
| `field` | op | 0.658 | 1.598 | 0.488 | 0.752 | 0.476 | 0.646 |
| `fieldSet` | op | 0.704 | 1.428 | 0.486 | 0.752 | 0.498 | 0.609 |
| `method` | op | 1.187 | 2.007 | 0.778 | 1.118 | 0.744 | 0.939 |
| `index` | op | 0.618 | 1.484 | 0.508 | 0.705 | 0.488 | 0.633 |
| `indexSet` | op | 0.613 | 1.357 | 0.480 | 0.717 | 0.514 | 0.621 |
| `not` | op | 0.598 | 1.480 | 0.504 | 0.751 | 0.517 | 0.685 |
| `neg` | op | 0.587 | 1.449 | 0.465 | 0.709 | 0.467 | 0.644 |
| `call0` | call | 0.943 | 5.338 | 3.841 | 4.203 | 3.732 | 4.371 |
| `call1` | call | 1.411 | 5.933 | 4.101 | 4.518 | 3.990 | 4.688 |
| `call3` | call | 2.072 | 7.004 | 4.501 | 5.053 | 4.400 | 5.151 |
| `callCap20` | call | 1.404 | 9.638 | 6.447 | 4.498 | 6.351 | 6.925 |
| `forRange` | op | 0.200 | 0.354 | 0.191 | 0.252 | 0.165 | 0.231 |
| `forArray` | op | 0.221 | 0.379 | 0.217 | 0.289 | 0.183 | 0.262 |
| `arrayDecl` | op | 1.122 | 2.180 | 0.793 | 1.209 | 0.724 | 0.971 |
| `strConcat` | op | 0.956 | 2.049 | 1.007 | 1.180 | 0.992 | 1.124 |
| `ternary` | op | 0.823 | 1.733 | 0.682 | 0.874 | 0.632 | 0.816 |
| `anonField` | op | 0.993 | 2.014 | 0.647 | 1.054 | 0.704 | 0.867 |
| `closureCall` | op | 1.386 | 6.736 | 4.656 | 5.043 | 4.425 | 5.480 |
| `hostMethod` | op | 1.157 | 1.931 | 0.734 | 1.075 | 0.721 | 0.929 |
| `hostStatic` | op | 1.572 | 2.261 | not supported | not supported | 0.891 | 1.105 |
| `arrayPush` | op | 1.099 | 1.820 | 0.681 | 1.006 | 0.720 | 0.852 |
| `boolLogic` | op | 0.902 | 2.011 | 0.715 | 1.029 | 0.733 | 0.938 |
| `modArith` | op | 0.875 | 1.797 | 0.682 | 0.913 | 0.635 | 0.862 |
| `switch` | op | 0.931 | 1.786 | 0.648 | 0.887 | 0.626 | 0.821 |
| `tryCatch` | unwind | 3.830 | 5.931 | 4.418 | 4.666 | 3.991 | 5.132 |
| `strInterp` | op | 1.164 | 1.919 | WRONG (v$n) | WRONG (v$n) | 0.747 | 0.843 |
| `mapLiteral` | op | 1.502 | 2.570 | 1.253 | 1.658 | 1.136 | 1.474 |
| `arrayCompr` | compound | 3.286 | 4.962 | 3.570 | 5.334 | 6.438 | 7.277 |
| `varTyped` | op | 0.709 | 1.271 | 0.418 | 0.634 | 0.431 | not supported |
| `fnTyped` | call | 1.813 | 6.133 | 4.249 | 4.568 | 4.014 | not supported |
| `classNew` | compound | 8.264 | 161.505 | not supported | 4.981 | not supported | not supported |
| `classCall` | call | 1.717 | not supported | not supported | 4.686 | not supported | not supported |
| `classField` | op | 0.780 | 1.736 | not supported | 0.836 | not supported | not supported |
| `stringSwitch` | op | 0.895 | 1.885 | 0.612 | 0.869 | 0.606 | 0.831 |
| `nullCoal` | op | 0.587 | 1.550 | 0.473 | 0.701 | 0.485 | 0.611 |
| `abstractOp` | op | 5.872 | not supported | not supported | not supported | not supported | not supported |

</details>

### Summary, over the 35 cases every library ran

| | **hxScript** | insanity | hscript | improved | iris | rulescript |
| --- | --- | --- | --- | --- | --- | --- |
| us per operation (28 cases) | 0.798 | 1.812 | 0.739 | 0.996 | 0.719 | 0.916 |
| us per call (4 cases) | 1.458 | 6.978 | 4.723 | 4.568 | 4.618 | 5.284 |
| parse, ms | 0.853 | 1.48 | 1.183 | 3.248 | 0.817 | 1.332 |
| corpus total, ms | 3609 | 9349 | 5024 | 5907 | 5161 | 6251 |
| total relative to hxScript | 1.00x | 2.59x | 1.39x | 1.64x | 1.43x | 1.73x |

```mermaid
xychart-beta
    title "Cost of one operation at 100,000 iterations"
    x-axis ["iris", "hscript", "hxScript", "rulescript", "improved", "insanity"]
    y-axis "microseconds" 0 --> 2.084
    bar [0.719, 0.739, 0.798, 0.916, 0.996, 1.812]
```

```mermaid
xychart-beta
    title "Cost of one call at 100,000 iterations"
    x-axis ["hxScript", "improved", "iris", "hscript", "rulescript", "insanity"]
    y-axis "microseconds" 0 --> 8.025
    bar [1.458, 4.568, 4.618, 4.723, 5.284, 6.978]
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
| operations per 60Hz frame | 20,881 | 9,198 | 22,556 | 16,740 | 23,168 | 18,198 |
| calls per 60Hz frame | 11,434 | 2,388 | 3,529 | 3,648 | 3,608 | 3,154 |
| operations per 2ms slice | 2,505 | 1,103 | 2,706 | 2,008 | 2,780 | 2,183 |
| calls per 2ms slice | 1,372 | 286 | 423 | 437 | 433 | 378 |

### What position tracking costs the libraries that can switch it off

Not a ranking. hxScript cannot turn positions off, so the comparison above is built
with them on everywhere; this is what that decision costs the others. At 100,000.

| | hscript | improved | iris | rulescript |
| --- | --- | --- | --- | --- |
| us per operation, with | 0.739 | 0.996 | 0.719 | 0.916 |
| us per operation, without | 0.650 | 0.876 | 0.695 | 0.767 |
| cost | 13.7% | 13.6% | 3.4% | 19.3% |
| parse with, ms | 1.183 | 3.248 | 0.817 | 1.332 |
| parse without, ms | 0.604 | 2.702 | 0.584 | 0.608 |

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
| [hscript-insanity](https://github.com/inky03/hscript-insanity) ("insanity") | `c6f115e` (main) | always tracks positions |
| [hscript](https://github.com/HaxeFoundation/hscript) | `7d5eacc` (master, post-2.7.0) | built both ways |
| [hscript-improved](https://github.com/CodenameCrew/hscript-improved) | `48ec0f4` (master) | built both ways |
| [hscript-iris](https://github.com/pisayesiwsi/hscript-iris) | `62d828b` (**dev**) | built both ways |
| [RuleScript](https://github.com/Kriptel/RuleScript) | `b5b377a` (master) | built both ways; needs hscript `609c489` |

Every library is at its default branch's tip, except hscript-iris, measured on `dev`.

**Only insanity moved since the previous run**, by 38 commits, nearly all of them abstracts and
operator overloading. hscript, hscript-improved, hscript-iris and RuleScript are at the same commits
as before. Their numbers still differ from the previous table, and that is the machine and the corpus
rather than the libraries: ten cases were added, so the per-operation average is over a different and
heavier set. Read a column against the others in ITS OWN table, never against a number from an
earlier run.

**RuleScript's figures are new rather than changed.** Its build had been failing, and the runner was
silently falling back to binaries left behind by an earlier run: they answered the cases the corpus
held when they were built and reported everything added since as `crash`. Both halves are fixed —
the build parameters named `hscript.Ast`, a module neither hscript checkout declares, where
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
