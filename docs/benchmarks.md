# Comparing Haxe scripting libraries

Seven hscript-family libraries running identical scripts.

## Read this first: different, not better

**No library here is "the best one."** Split the suite in two and the two halves say different
things: on the cost of one ordinary operation hxScript and hscript-iris are level at the front, two
percent apart and inside this machine's noise, while on the cost of one function call hxScript is
first, 1.8 times ahead of hscript-insanity and more than three times ahead of the other five. Both
are in the summary below, and neither is the summary on its own.

Most of the call gap has one cause, and it is not cleverness. Five of the seven libraries unwind
`return`, `break` and `continue` by **throwing an exception**, and a thrown exception costs
microseconds on a static target. hxScript signals them with flags, and so does hscript-insanity,
which switched between the last run and this one: its per-call cost fell to less than 40% of what
it was, and it went from last on calls to second. That is also why the corpus total flatters both:
totals are dominated by the call cases, so quote the per-operation and per-call averages instead.

`callCap20` is `call1` with twenty more variables in the enclosing scope and nothing else changed, so
the pair isolates a second design difference: whether building a call frame copies the captured
scope, and so costs something per captured variable. Five of the seven pay for it, and pay about the
same 2 to 3 microseconds. That is half again on a call that throws, and nearly three times over on
hscript-insanity's, which no longer does. hxScript and hscript-improved pay nothing.

The same applies to features. hscript is small and fast and has no scripted classes.
hscript-improved has them, and hxScript both instantiates one and calls its methods several times
faster, because its classes are generated bridges with real fields and theirs are a shell over a
map. RuleScript adds imports, usings and string interpolation. hscript-iris wraps a
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
Earlier versions of this page reported that as a defect in four of the six libraries it then
covered. It was not.

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

| case | kind | **hxScript** | insanity | SScript | hscript | improved | iris | rulescript |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `noCall` | op | 0.479 | 0.833 | 0.682 | 0.428 | 0.617 | 0.484 | 0.565 |
| `loopPlain` | op | 0.487 | 1.056 | 0.637 | 0.450 | 0.643 | 0.440 | 0.605 |
| `loopCont` | unwind | 0.637 | 1.288 | 2.741 | 2.503 | 2.720 | 2.460 | 3.181 |
| `postIncr` | op | 0.442 | 0.854 | 0.504 | 0.388 | 0.579 | 0.427 | 0.567 |
| `arith` | op | 0.574 | 1.206 | 0.866 | 0.566 | 0.754 | 0.511 | 0.707 |
| `locals` | op | 0.523 | 1.056 | 0.785 | 0.498 | 0.743 | 0.486 | 0.765 |
| `blocks` | op | 0.617 | 1.040 | 0.901 | 0.599 | 0.944 | 0.560 | 0.754 |
| `field` | op | 0.544 | 0.949 | 0.755 | 0.473 | 0.781 | 0.529 | 0.623 |
| `fieldSet` | op | 0.600 | 1.048 | 0.727 | 0.473 | 0.735 | 0.460 | 0.588 |
| `method` | op | 1.024 | 1.480 | 1.085 | 0.731 | 1.173 | 0.746 | 0.952 |
| `index` | op | 0.508 | 0.965 | 0.754 | 0.481 | 0.760 | 0.466 | 0.613 |
| `indexSet` | op | 0.510 | 0.920 | 0.723 | 0.476 | 0.688 | 0.477 | 0.605 |
| `not` | op | 0.510 | 0.961 | 0.750 | 0.509 | 0.787 | 0.471 | 0.656 |
| `neg` | op | 0.476 | 0.906 | 0.759 | 0.460 | 0.660 | 0.440 | 0.689 |
| `call0` | call | 0.804 | 1.252 | 3.895 | 3.631 | 3.982 | 3.480 | 4.109 |
| `call1` | call | 1.248 | 1.589 | 4.290 | 3.905 | 4.294 | 3.784 | 4.607 |
| `call3` | call | 1.826 | 2.280 | 4.650 | 4.231 | 4.833 | 4.192 | 5.079 |
| `callCap20` | call | 1.267 | 4.353 | 7.026 | 6.075 | 4.338 | 5.964 | 6.901 |
| `forRange` | op | 0.185 | 0.211 | 0.320 | 0.179 | 0.241 | 0.157 | 0.222 |
| `forArray` | op | 0.193 | 0.223 | 0.354 | 0.205 | 0.274 | 0.173 | 0.258 |
| `arrayDecl` | op | 0.993 | 1.539 | 1.085 | 0.752 | 1.189 | 0.693 | 0.941 |
| `strConcat` | op | 0.795 | 1.576 | 0.930 | 0.936 | 1.164 | 0.942 | 1.121 |
| `ternary` | op | 0.629 | 1.284 | 0.936 | 0.631 | 0.836 | 0.592 | 0.826 |
| `anonField` | op | 0.836 | 1.341 | 1.075 | 0.638 | 1.021 | 0.627 | 0.861 |
| `closureCall` | op | 1.256 | 1.607 | 5.009 | 4.359 | 4.800 | 4.248 | 5.444 |
| `hostMethod` | op | 0.994 | 1.389 | 1.026 | 0.777 | 1.096 | 0.826 | 0.943 |
| `hostStatic` | op | 1.368 | 1.677 | 1.250 | not supported | not supported | 0.809 | 1.087 |
| `arrayPush` | op | 1.116 | 1.394 | 0.843 | 0.659 | 1.058 | 0.772 | 0.847 |
| `boolLogic` | op | 0.699 | 1.574 | 1.061 | 0.756 | 0.974 | 0.737 | 0.932 |
| `modArith` | op | 0.643 | 1.367 | 0.935 | 0.664 | 0.933 | 0.594 | 0.920 |
| `switch` | op | 0.793 | 1.454 | 1.000 | 0.612 | 0.841 | 0.562 | 0.814 |
| `tryCatch` | unwind | 3.438 | 4.655 | 4.640 | 3.947 | 4.379 | 3.765 | 5.019 |
| `strInterp` | op | 0.993 | 1.483 | 0.921 | WRONG (v$n) | WRONG (v$n) | 0.685 | 0.846 |
| `mapLiteral` | op | 1.372 | 1.876 | 1.570 | 1.210 | 1.509 | 1.052 | 1.403 |
| `arrayCompr` | compound | 2.928 | 4.076 | 4.381 | 3.653 | 5.442 | 6.046 | 7.260 |
| `varTyped` | op | 0.459 | 0.883 | 0.681 | 0.417 | 0.685 | 0.459 | not supported |
| `fnTyped` | call | 1.679 | 1.809 | 4.334 | 3.818 | 4.284 | 3.822 | not supported |
| `classNew` | compound | 2.963 | 8.300 | not supported | not supported | 4.963 | not supported | not supported |
| `classCall` | call | 1.567 | 1.815 | not supported | not supported | 4.528 | not supported | not supported |
| `classField` | op | 0.751 | 1.067 | not supported | not supported | 0.868 | not supported | not supported |
| `stringSwitch` | op | 0.782 | 1.273 | 1.038 | 0.651 | 0.884 | 0.561 | 0.960 |
| `nullCoal` | op | 0.497 | 1.045 | 0.711 | 0.496 | 0.671 | 0.456 | 0.716 |
| `abstractOp` | op | 5.519 | 5.246 | not supported | not supported | not supported | not supported | not supported |

</details>

### Summary, over the 35 cases every library ran

| | **hxScript** | insanity | SScript | hscript | improved | iris | rulescript |
| --- | --- | --- | --- | --- | --- | --- | --- |
| us per operation (28 cases), lower is faster | 0.681 | 1.158 | 0.994 | 0.716 | 0.977 | 0.696 | 0.925 |
| us per call (4 cases), lower is faster | 1.287 | 2.369 | 4.965 | 4.461 | 4.362 | 4.355 | 5.174 |
| parse, ms, lower is faster | 0.835 | 1.342 | 3.07 | 1.11 | 3.52 | 0.794 | 1.272 |
| corpus total, ms, lower is faster | 3123 | 5192 | 5944 | 4800 | 5734 | 4918 | 6205 |
| total relative to hxScript, higher is slower | 1.00x | 1.66x | 1.90x | 1.54x | 1.84x | 1.57x | 1.99x |

```mermaid
xychart-beta
    title "Cost of one operation at 100,000 iterations"
    x-axis ["hxScript", "iris", "hscript", "rulescript", "improved", "SScript", "insanity"]
    y-axis "microseconds" 0 --> 1.332
    bar [0.681, 0.696, 0.716, 0.925, 0.977, 0.994, 1.158]
```

```mermaid
xychart-beta
    title "Cost of one call at 100,000 iterations"
    x-axis ["hxScript", "insanity", "iris", "improved", "hscript", "SScript", "rulescript"]
    y-axis "microseconds" 0 --> 5.95
    bar [1.287, 2.369, 4.355, 4.362, 4.461, 4.965, 5.174]
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

| | **hxScript** | insanity | SScript | hscript | improved | iris | rulescript |
| --- | --- | --- | --- | --- | --- | --- | --- |
| operations per 60Hz frame | 24,461 | 14,391 | 16,774 | 23,267 | 17,059 | 23,945 | 18,020 |
| calls per 60Hz frame | 12,954 | 7,036 | 3,356 | 3,736 | 3,820 | 3,826 | 3,221 |
| operations per 2ms slice | 2,935 | 1,726 | 2,012 | 2,792 | 2,047 | 2,873 | 2,162 |
| calls per 2ms slice | 1,554 | 844 | 402 | 448 | 458 | 459 | 386 |

### What position tracking costs the libraries that can switch it off

Not a ranking. hxScript cannot turn positions off, so the comparison above is built
with them on everywhere; this is what that decision costs the others. At 100,000.

| | hscript | improved | iris | rulescript |
| --- | --- | --- | --- | --- |
| us per operation, with | 0.716 | 0.977 | 0.696 | 0.925 |
| us per operation, without | 0.622 | 0.886 | 0.688 | 0.771 |
| cost | 15.2% | 10.3% | 1.1% | 20.0% |
| parse with, ms | 1.11 | 3.52 | 0.794 | 1.272 |
| parse without, ms | 0.582 | 2.729 | 0.71 | 0.642 |

### The same corpus through each library's own front door, at 1,000

Every table above hoists parsing out of the timing so the interpreters can be compared.
This one hoists nothing: each library is driven through its own one-call entry point, so
construction, parsing and any work it repeats internally are all inside the number.

Totals over the 35 cases every library completed this way, at a much lower scale than
the tables above, because a call that reparses every time is not one a host makes a
hundred thousand times.

| | **hxScript** | insanity | SScript | hscript | improved | iris | rulescript |
| --- | --- | --- | --- | --- | --- | --- | --- |
| corpus through the front door, ms, lower is faster | 37.3 | 63.9 | 132.1 | 54.0 | 64.0 | 55.0 | 68.5 |
| relative to hxScript, higher is slower | 1.00x | 1.71x | 3.54x | 1.45x | 1.72x | 1.48x | 1.84x |
| parse alone, ms, from the table above | 0.835 | 1.342 | 3.07 | 1.11 | 3.52 | 0.794 | 1.272 |

```mermaid
xychart-beta
    title "Whole corpus through the front door (lower is better)"
    x-axis ["hxScript", "hscript", "iris", "insanity", "improved", "rulescript", "SScript"]
    y-axis "ms" 0 --> 151
    bar [37.3, 54.0, 55.0, 63.9, 64.0, 68.5, 132.1]
```

Left out of the totals, since not every library completed them this way: `hostStatic`, `strInterp`, `varTyped`, `fnTyped`, `classNew`, `classCall`, `classField`, `abstractOp`.

<!-- END GENERATED -->

## Behavioural differences found

These came out of the value checking, not the timing, and matter more than any of the numbers above
if you are choosing a library. All were reproduced directly, outside the harness.

**`for (i in 0...n)` works everywhere, and a previous version of this page said otherwise.** It was
recorded as broken on hxcpp in hscript, hscript-improved, RuleScript and hscript-insanity, blamed on
`IntIterator.hasNext`/`next` being `inline` and having no runtime form. Both halves were wrong. They
have a runtime form; `-dce std` removes it because every call site inlines them, so nothing references
them. Build with `-dce no` and all seven libraries run `forRange` and `arrayCompr` correctly. The whole
`CRASH` column this page used to carry is gone, and so are the nine timeouts behind it.

Worth stating plainly because the failure looks exactly like a library defect from the outside: a
script gets `Cannot call null`, or on a build without position tracking it silently abandons the rest
of the program. Neither points at the host's own compiler flags, which is where the cause is. See
[`embedding.md`](embedding.md#dead-code-elimination) for what else DCE takes with it.

**`++` works in all seven**, and every loop counter in this suite still uses `i += 1`, which is equally
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
| [hscript-insanity](https://github.com/inky03/hscript-insanity) ("insanity") | `f2a3584` (main) | always tracks positions |
| [SScript](https://github.com/ThomasDarkson/SScript) | `bd91590` (main, 23.0.0) | always tracks positions |
| [hscript](https://github.com/HaxeFoundation/hscript) | `7d5eacc` (master, post-2.7.0) | built both ways |
| [hscript-improved](https://github.com/CodenameCrew/hscript-improved) | `48ec0f4` (master) | built both ways |
| [hscript-iris](https://github.com/pisayesiwsi/hscript-iris) | `62d828b` (**dev**) | built both ways |
| [RuleScript](https://github.com/Kriptel/RuleScript) | `b5b377a` (master) | built both ways; needs hscript `609c489` |

Every library is at its default branch's tip, except hscript-iris, measured on `dev`.

**SScript is measured through its parser and interpreter directly.** It is a class-oriented fork,
and two things about measuring it are worth stating rather than leaving in the runner. Its
`execute()` reparses the source on every call, so using it would have put parse cost inside the
timed section where every other library has only execution there; its `parser` and `interp` are
both public, so the runner parses once and runs the tree, which is what the RuleScript runner does
for the same reason. And its `Expr` carries `pmin`, `pmax` and `line` unconditionally, so like
hxScript and insanity it is built once rather than both ways. Version 23 added two interpreter
options, compiling a function's body on its first call and caching locals in that compiled code (the
second on C++ only), and turned both on by default. The runner leaves them there, so what is measured
is the library as it ships.

**Two libraries moved this run, and the other five are the control.** hscript-insanity went from its
pinned commit to the tip of `main`, and SScript from 22.4.1 to 23.0.0. Everything else is at the
commit it was measured at last time, the corpus is unchanged, and the shared set is the same 35
cases, so those five can be read against the previous table:

| lower is faster | previous | this run | change |
| --- | --- | --- | --- |
| hscript, us per operation | 0.709 | 0.716 | +1% |
| hscript-improved | 0.968 | 0.977 | +1% |
| hscript-iris | 0.673 | 0.696 | +3% |
| RuleScript | 0.889 | 0.925 | +4% |
| **hxScript** | **0.671** | **0.681** | **+1%** |

All five moved the same way, by 1% to 4%. That is drift in the machine rather than in any of the
code, inside the 5% noise floor, and it is why the caveats below say to read the ratios and not the
microseconds. hxScript's one source change since the last run is in `setup/Autowire.hx`, which runs
at compile time and not in the interpreter. The two libraries that did move, moved by far more than
that:

| lower is faster | previous | this run | change |
| --- | --- | --- | --- |
| insanity, us per operation | 1.412 | 1.158 | -18% |
| insanity, us per call | 6.054 | 2.369 | -61% |
| insanity, parse, ms | 1.019 | 1.342 | +32% |
| SScript, us per operation | 1.326 | 0.994 | -25% |
| SScript, us per call | 4.943 | 4.965 | 0% |
| SScript, parse, ms | 2.464 | 3.07 | +25% |

The rule still stands: read a column against the others in ITS OWN table, never against a number
from an earlier run. The table above does not break that rule: it compares each library only with
itself, and it means something only because the five that did not move show the machine held still.

**insanity is measured at its tip again.** It had been pinned to `ad67b16` because on its `main` a
script that declares a class failed with `Null Function Pointer`. That is fixed: `classNew`,
`classCall` and `classField` all run and return the expected values. They are also where the library
changed most. `classNew` is eight times cheaper than at the pinned commit and `classCall` three
times. The call cases are between 1.8 and 3.8 times cheaper, and `loopCont`, one `continue` per
iteration, costs about a third of what it did, because commit `21b3469` replaced the exception it
threw to unwind `return`, `break` and `continue` with flags. Ordinary operations are a median 10%
cheaper. `abstractOp` halved and is now 5% under hxScript's, which is at this suite's noise floor
rather than a result. Parsing is the one thing that got slower, by about a third.

**SScript 23 went two ways at once, and its average hides it.** The per-operation average fell by a
quarter, but that is four cases that had been far out of line with the rest of SScript's own column
coming back into it: `indexSet` is 11 times cheaper than on 22.4.1, `index` and `arrayPush` nearly 4
times, and `mapLiteral` twice. `strInterp`, outside the shared set, is 4 times cheaper as well. The
other 24 cases in that average got a median 29% dearer, up to 47% on `forRange`, and only `strConcat`
got cheaper. The call cases did not move, which is consistent with the new compiled functions still
unwinding `return` by throwing. Parsing is a quarter slower.

**hscript-improved is built with its own macros now, and was not before.** `-cp` does not read a
library's `extraParams.hxml`, and hscript-improved's carries `UsingHandler.init()` and
`ClassExtendMacro.init()`. It builds without them, which is why this went unnoticed: what was
measured was the library minus two of its features. Both are passed now, in
`improved-params.hxml`, the same way RuleScript's have always been. It cost that column 1%, so the
correction is to what was being described rather than to any number.

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

`LIBS` wants checkouts named `insanity`, `hscript`, `improved`, `iris`, `rulescript`, `sscript` and
`hscript-rs` (the older hscript RuleScript needs). Anything missing is skipped, and the collator
drops absent libraries rather than emptying the shared-case set, so a subset produces a table for
that subset.

Two things about those checkouts are easy to get wrong and neither announces itself:

- **`iris` is measured on `dev`, not on its default branch.** `master` carries a commit that removes
  string interpolation and breaks `postIncr`, so checking out the default branch quietly changes
  what is being compared and reports the difference as though the library had regressed.
- **A library's own `extraParams.hxml` is not read by `-cp`, only by `-lib`.** Three libraries need
  theirs replayed, and `run.sh` does it two ways. insanity gets the checkout's own file passed
  straight through, because it moved its macro from `insanity.backend.macro` to `insanity.macro`
  between two commits measured here and a copy would have gone on naming the old path, setting
  nothing up while appearing to work. hscript-improved and RuleScript get hand-written copies,
  [`improved-params.hxml`](../test/bench/xbench/improved-params.hxml) and
  [`rulescript-params.hxml`](../test/bench/xbench/rulescript-params.hxml), the latter because its
  own file opens with `-lib hscript` and would pull an hscript it cannot build against. Without any
  of this, insanity does not build and hscript-improved builds without two of its features, which
  is worse, because it looks like it worked.

Scales default to `100000` and are settable. Passing more than one also brings back the
scale-stability table:

```sh
SCALES="25000 100000 500000" LIBS=... sh test/bench/xbench/run.sh
```

They must be multiples of 1000, which is the array length `forArray` walks.

The front-door pass runs at `FRONT`, which defaults to `1000` and is separate from `SCALES` because
it measures a different thing. Each library is driven there through its own one-call entry point,
so nothing in that table shares code with the runners the other tables use.

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
