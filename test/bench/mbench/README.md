# Execution-mode benchmark

The same corpus run three ways: interpreted, compiled to cppia, and cppia with the JIT enabled.
Writes the results section of [`docs/mode-benchmarks.md`](../../docs/mode-benchmarks.md).
What they mean for someone choosing a mode is [`docs/modes.md`](../../docs/modes.md),
which is written by hand.

```sh
sh test/mbench/run.sh
```

```sh
SCALES="25000 100000 500000" sh test/mbench/run.sh
```

Scales must be multiples of 1000, which is the array length `forArray` walks.

## Why it is a separate suite from `xbench`

[`xbench`](../xbench) compares this library against other hscript-family libraries, so its corpus is
loose expressions: that is the only shape every library there accepts. The compiler takes class
declarations, so a bare `var i = 0; ... i;` has nowhere to go. The corpus here is therefore one class
with a static `run` per case, which cannot be shared with the cross-library suite.

Read the two together but do not compare their numbers directly. Same rules, same scale, different
corpus shape.

## Files

| file | what it is |
| --- | --- |
| `ModeCases.hx` | the corpus, scaled by iteration count, with an expected value per case |
| `MBench.hx` | the harness: prepare untimed, exec timed, median of five, value checked |
| `run.sh` | builds once, runs every case in its own process in each mode, then collates |
| `collate.py` | reads the result lines and writes the generated section of the doc |

## The three modes

Selected by the binary's first argument.

- `interp` builds an `Environment` and a `Module` and calls the static through the scripted class.
- `cppia` parses, calls `Cppia.compile`, boots the resulting module and calls the static through
  `Reflect.field`.
- `jit` is `cppia` with `cpp.cppia.Host.enableJit(true)` first.

The JIT is a process-wide switch, so it cannot share a process with the mode it is measured against.
One process per case was already the rule, for the same reason it is in `xbench`.

## Build settings

Built with `-D scriptable`, `-D hxscript_cppia` and `-dce no`, all three required rather than
chosen. `-D scriptable` makes the host's types reachable from bytecode, `-D hxscript_cppia` compiles
the emitter into the library at all, and `-dce no` keeps what a script resolves by name from being
eliminated. `xbench` is built the same way for the last of those, so the two documents describe the
same build.
