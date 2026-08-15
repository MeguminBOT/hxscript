"""Collate the per-mode benchmark lines into ONE per-case list plus compact summaries.

Output goes between the GENERATED markers in `docs/mode-benchmarks.md`. What the numbers mean for
someone choosing a mode is written up separately in `docs/modes.md`, by hand.

Same shape as the cross-library collator next door, and on purpose: the two documents answer
adjacent questions and a reader moving between them should not have to learn a second table format.
One table of record at a reference scale, a summary, and the figures the decision turns on.

What differs is the last section. Across libraries the interesting question is which is faster.
Across modes it is when compiling pays for itself, so the getting-ready cost is not a footnote here,
it is half the answer.
"""
import sys, collections

PREFERRED = ["interp", "cppia", "jit"]
LABEL = {
    "interp": "interpreted",
    "cppia": "cppia",
    "jit": "cppia + JIT",
}

# case -> scale -> mode -> (status, ms, value)
rows = collections.defaultdict(lambda: collections.defaultdict(dict))
prep = {}
tier = {}
order = []
scales = []

for raw in open(sys.argv[1]):
    raw = raw.strip()
    if raw.startswith("R|"):
        _, mode, case, t, iters, status, ms, value = raw.split("|", 7)
        n = int(iters) if iters.isdigit() else 0
        if case not in tier:
            tier[case] = t
            order.append(case)
        elif t != "?":
            tier[case] = t
        if n and n not in scales:
            scales.append(n)
        rows[case][n][mode] = (status, ms, value)
    elif raw.startswith("P|"):
        parts = raw.split("|")
        prep[parts[1]] = parts[3] if len(parts) > 3 else "crash"

scales.sort()
seen = {m for c in rows for n in rows[c] for m in rows[c][n]} | set(prep)
MODES = [m for m in PREFERRED if m in seen]

# The scale everything not explicitly about scale is reported at.
REF = scales[-1] if scales else 0


def kind(case):
    """Which average a case feeds, taken from the tier the corpus itself declares."""
    return tier.get(case, "op")


def cell(rec):
    if rec is None:
        return "n/a"
    status, ms, value = rec
    if status == "ok":
        return ms
    if status == "unsupported":
        return "refused"
    if status == "crash":
        return "CRASH"
    if status == "wrong":
        return f"WRONG ({value})"
    return status


def per_iter(rec, n):
    """Microseconds per iteration, or the status text when the case did not run."""
    if rec is None or rec[0] != "ok" or not n:
        return cell(rec)
    return "%.3f" % (float(rec[1]) * 1000.0 / n)


def ok(case, n, mode):
    return rows[case][n].get(mode, ("x",))[0] == "ok"


def shared(n, modes):
    """Cases every one of `modes` ran correctly at scale `n`."""
    return [c for c in order if n in rows[c] and all(ok(c, n, m) for m in modes)]


def avg(mode, cases, n):
    vals = [float(rows[c][n][mode][1]) * 1000.0 / n for c in cases if ok(c, n, mode)]
    return sum(vals) / len(vals) if vals else 0.0


def chart(title, unit, pairs, sort=True):
    """A single-series bar chart. Mermaid's xychart-beta has no legend, so each chart plots one
    series and puts the comparison on the x-axis, where it needs no key to read."""
    pairs = [(l, v) for l, v in pairs if v is not None]
    if not pairs:
        return
    if sort:
        pairs.sort(key=lambda t: t[1])
    top = max(v for _, v in pairs)
    top = round(top * 1.15, 3) if top < 10 else int(top * 1.15)
    dec = "%.3f" if top < 20 else ("%.1f" if top < 1000 else "%.0f")
    print("")
    print("```mermaid")
    print("xychart-beta")
    print(f'    title "{title}"')
    print("    x-axis [" + ", ".join('"%s"' % l for l, _ in pairs) + "]")
    print(f'    y-axis "{unit}" 0 --> {top}')
    print("    bar [" + ", ".join(dec % v for _, v in pairs) + "]")
    print("```")


# ---------------------------------------------------------------- the list

print(f"\n### Every case, microseconds per iteration at {REF:,}\n")
print("One row per case, and the only per-case table in this document. `kind` is which average the")
print("row feeds: `op` and `call` are averaged separately because they differ by design rather than")
print("by degree. `unwind` cases are in neither, being dominated by how each mode implements")
print("`continue` and `throw`, and nor are `compound` ones, which do far more than one operation per")
print("iteration and would describe themselves rather than the mode.")
# Only worth explaining when there is one to explain. Every case in the corpus compiled on the run
# this was written for, and a paragraph about refusals beside a table containing none reads as though
# the reader missed something.
refused = sorted({c for c in order if REF in rows[c] for m in MODES if rows[c][REF].get(m, ("",))[0] == "unsupported"})
print("")
if refused:
    print("`refused` is the compiler declining a construct it does not emit. It is not a failure of the")
    print("run: nothing executed, because the module is rejected whole. Those rows are the edge of the")
    print("compiled subset: " + ", ".join("`%s`" % c for c in refused) + ".")
else:
    print("Every case compiled. Nothing in this corpus falls outside what the compiler emits, which is")
    print("a statement about the corpus as much as about the compiler, since it is built from the")
    print("constructs a hot script actually uses, not from the language's edges.")
print("")
print("<details>")
print(f"<summary><strong>{sum(1 for c in order if REF in rows[c])} cases, click to expand</strong></summary>")
print("")
print("| case | kind | " + " | ".join(LABEL[m] for m in MODES) + " |")
print("| --- | --- |" + " --- |" * len(MODES))
for c in order:
    if REF not in rows[c]:
        continue
    print(f"| `{c}` | {kind(c)} | " + " | ".join(per_iter(rows[c][REF].get(m), REF) for m in MODES) + " |")
print("")
print("</details>")

# ---------------------------------------------------------------- summary

sh = shared(REF, MODES)
perop = [c for c in sh if kind(c) == "op"]
callc = [c for c in sh if kind(c) == "call"]
tot = {m: sum(float(rows[c][REF][m][1]) for c in sh) for m in MODES}
base = tot.get("interp") or 1.0

print(f"\n### Summary, over the {len(sh)} cases every mode ran\n")
print("| | " + " | ".join(LABEL[m] for m in MODES) + " |")
print("| --- |" + " --- |" * len(MODES))
print(f"| us per operation ({len(perop)} cases) | " + " | ".join("%.3f" % avg(m, perop, REF) for m in MODES) + " |")
print(f"| us per call ({len(callc)} cases) | " + " | ".join("%.3f" % avg(m, callc, REF) for m in MODES) + " |")

# Ratios per kind, not a ratio of totals. A total is a sum over cases of wildly different cost, so
# whichever case is slowest in a given mode decides it: `tryCatch` alone is most of the cppia total,
# which would report the JIT as several times faster than it is on everything else.
def ratio(m, cases):
    a, b = avg("interp", cases, REF), avg(m, cases, REF)
    return "%.1fx" % (a / b) if b else "n/a"


print("| operation, vs interpreted | " + " | ".join(ratio(m, perop) for m in MODES) + " |")
print("| call, vs interpreted | " + " | ".join(ratio(m, callc) for m in MODES) + " |")
print("| corpus total, ms | " + " | ".join("%.0f" % tot[m] for m in MODES) + " |")

# Name what the total is made of, so nobody quotes it as a speedup.
worst = {}
for m in MODES:
    if not tot[m]:
        continue
    c = max(sh, key=lambda c: float(rows[c][REF][m][1]))
    worst[m] = (c, 100.0 * float(rows[c][REF][m][1]) / tot[m])

if worst:
    print("")
    print("The total row is a sum over cases of very different cost, so it is not a speedup and should")
    print("not be quoted as one. The single largest case in each column takes " + ", ".join(
        "%.0f%% (`%s`) of %s" % (pct, c, LABEL[m]) for m, (c, pct) in worst.items()) + ". The two")
    print("ratio rows above are the comparable figures.")

chart(f"Cost of one operation at {REF:,} iterations", "microseconds", [(LABEL[m], avg(m, perop, REF)) for m in MODES])
chart(f"Cost of one call at {REF:,} iterations", "microseconds", [(LABEL[m], avg(m, callc, REF)) for m in MODES])

# ---------------------------------------------------------------- break-even

print("\n### What getting ready costs, and when it is repaid\n")
print("The only place preparing is timed. One source of 80 small functions, median of 5, no")
print("execution: parsing and building an environment for the interpreter, and parsing, emitting")
print("bytecode and booting a module for the other two.")
print("")
print("Compiling is a cost paid once against a saving paid per iteration, so the break-even column")
print("is the number that decides whether to do it at all. Below that many operations in the life of")
print("a module, interpreting finishes first.")
print("")
print("| | " + " | ".join(LABEL[m] for m in MODES) + " |")
print("| --- |" + " --- |" * len(MODES))
print("| prepare, ms | " + " | ".join(str(prep.get(m, "n/a")) for m in MODES) + " |")

interp_op = avg("interp", perop, REF) if "interp" in MODES else 0.0
row = []
for m in MODES:
    if m == "interp" or not prep.get(m, "").replace(".", "").isdigit():
        row.append("n/a")
        continue
    extra_ms = float(prep[m]) - float(prep.get("interp", 0) or 0)
    saved_us = interp_op - avg(m, perop, REF)
    row.append("%s" % f"{int(extra_ms * 1000.0 / saved_us):,}" if saved_us > 0 else "never")
print("| break-even, operations | " + " | ".join(row) + " |")
