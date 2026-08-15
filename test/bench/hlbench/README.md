# HashLink benchmark

Runs the same corpus four ways on HashLink and reports what each costs. The results and what they
mean are in [`../../../docs/hl-benchmarks.md`](../../../docs/hl-benchmarks.md); this file is only
about running it.

The other two suites compare things of one kind: `xbench` puts six interpreters beside each other,
`mbench` puts one library's three hxcpp modes beside each other. Neither answers the question a host
asks before moving logic into a script, which is what it costs against not scripting it at all. This
one does.

| column | what it is |
| --- | --- |
| `hashlink/c` | the corpus written as Haxe, compiled to C, linked as a native binary |
| `hashlink/vm` | the same Haxe, compiled to `.hl`, run by the HashLink VM |
| `hxscript hl/c` | the corpus as scripts, compiled to HashLink bytecode at run time |
| `hxscript interp` | the same scripts, walked as a tree |

## Layout

| file | role |
| --- | --- |
| `GenNative.hx` | writes the corpus out as ordinary Haxe, for the compiler to compile |
| `HlBench.hx` | the harness; one binary serves three of the four columns |
| `run.sh` | generates, builds both binaries, drives one process per case |
| `collate.py` | turns the raw result lines into the comparison tables |

The corpus itself is [`../mbench/ModeCases.hx`](../mbench/ModeCases.hx), shared with the
execution-mode benchmark. It is not copied: `GenNative` reads it and writes the Haxe half, because a
corpus maintained twice is two corpora, and then the suite measures the difference between them
rather than between two ways of running one.

Three of the four columns come out of one binary on purpose, so the compiled Haxe and the scripts are
measured in the same process, by the same clock, against the same allocator. Only the VM column is a
second build, since running on the VM is the thing it measures. That build carries no library at all:
`HlBench` guards its scripted half behind `#if hxscript_hl`, so the column is the language on its
own and nobody has to wonder whether linking the compiler in changed the number.

## Running

```sh
sh test/bench/hlbench/run.sh
SCALE=200000 sh test/bench/hlbench/run.sh
```

Needs HashLink and a C compiler. `HLPATH` points at the HashLink to build against, defaulting to the
one the conformance suite uses.

**The scale is compiled into the native half.** A case's loop bound is written into its source when
the corpus is generated, so a natively compiled case cannot take it at run time the way a script can.
`run.sh` regenerates both halves together and the harness refuses to run at any other scale, because
two columns measured at two scales is not a comparison.

## What the optimiser does to a synthetic corpus

Haxe compiles the native columns for real, and a real compiler handed a loop whose result it can
prove emits no loop at all. The bound is read through a mutable static the optimiser cannot see the
value of, so it cannot fold on the count alone, but a body it can hoist still goes. Those cases are
marked `folded` in the table.

They are counted anyway, and that is deliberate. What a host is deciding is whether to put some
logic in a script or leave it as Haxe, and if it is left as Haxe the optimiser is part of what it
gets: a fair comparison includes it rather than handicapping it. `vs ~0` in the summary is that taken
to its limit, where the native side did not run and the scripted side ran every iteration.

For the same reason the native columns are NOT built with `--no-inline`. That would keep every case
in the averages, and would also make the thing this library is compared against slower than the code
a host actually ships, which flatters the scripted columns for free.

## How to read a result line

    R|<column>|<case>|<tier>|<iterations>|<status>|<median ms>|<value>

`status` is `ok`, `wrong` (ran, produced the wrong value), `unsupported` (the compiler declined it,
or Haxe would not compile the native half) or `crash`.

Every case ends in a value the harness checks. Keep it that way: a column that skipped the work
would otherwise be recorded as extremely fast, and here that would be the headline.

## Adding a case

Add it to [`../mbench/ModeCases.hx`](../mbench/ModeCases.hx) and both suites get it. Keep
accumulators inside 32-bit `Int` at every scale so the expected value is exact rather than depending
on overflow, and prefer a case whose result depends on every iteration: those are the ones the
optimiser cannot fold, and so the ones that produce a comparison rather than a `folded`.

A case Haxe itself will not compile goes in `GenNative.SKIP` with the reason, which the native
columns then report instead of a time.
