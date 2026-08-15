# Cross-library benchmark

Runs the same scripts through six hscript-family libraries and reports what each one costs. The
results and what they mean are in [`../../docs/benchmarks.md`](../../docs/benchmarks.md); this file
is only about running it.

## Layout

| file | role |
| --- | --- |
| `BenchCases.hx` | the corpus: every case's source, iteration count and expected value |
| `XBench.hx` | the timing harness, shared by every runner |
| `RunHxScript.hx` / `RunInsanity.hx` | runners for this library and hscript-insanity (same body, different package) |
| `RunHscript.hx` | runner for hscript **and** hscript-improved (same API) |
| `RunIris.hx` / `RunRuleScript.hx` | runners for the two libraries with their own API |
| `run.sh` | builds everything and drives one process per case |
| `collate.py` | turns the raw result lines into the comparison tables |

Six binaries rather than one, because several of these libraries occupy the same package (`hscript`,
`insanity`) and cannot be linked together.

## Running

Check the libraries out side by side, then point `LIBS` at them:

```sh
mkdir xbench-libs && cd xbench-libs
git clone https://github.com/inky03/hscript-insanity insanity
git clone https://github.com/HaxeFoundation/hscript
git clone https://github.com/CodenameCrew/hscript-improved improved
git clone https://github.com/pisayesiwsi/hscript-iris iris
git clone https://github.com/Kriptel/RuleScript rulescript
# RuleScript needs an hscript predating Interp.makeKeyValueIterator
git clone https://github.com/HaxeFoundation/hscript hscript-rs && (cd hscript-rs && git checkout 609c489)
cd ..

LIBS=$PWD/xbench-libs sh test/xbench/run.sh
```

Anything missing from `LIBS` is skipped, so you can compare against a subset.

## How to read a result line

    R|<lib>|<case>|<tier>|<iterations>|<status>|<ms>|<value>

`status` is `ok`, `wrong` (ran, produced the wrong value), `unsupported` (could not parse or run) or
`crash` (the process died or was killed after 60s).

Every case ends in an expression whose value is known and checked. **Keep it that way.** A library
that parses a case and skips the work would otherwise be recorded as extremely fast, and the value
check is what caught the three behavioural differences documented in `docs/benchmarks.md`.

## Adding a case

Add it to `BenchCases.all()` with its expected value and iteration count. Keep accumulators inside
32-bit `Int` so the expected value is exact rather than depending on overflow, and use `i += 1` for
loop counters rather than `i++`. hscript-iris did not implement `++` on its released version and
looped forever on one; it does now, but the corpus stays on `i += 1` so a case does not depend on
which version of a library is checked out.

Mark a case `ext` rather than `core` when it needs a feature some library may not have.
