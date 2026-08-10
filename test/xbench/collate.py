"""Collate the per-library benchmark lines into ONE per-case list plus compact summaries.

Deliberately one table of record. An earlier version printed the whole corpus once per scale, plus
totals, plus averages, plus a chart for each, which came to eighteen tables and eighteen charts saying
a handful of things repeatedly, which is a lot to keep consistent by hand when a single number changes. What
comes out now is one list at a reference scale, a summary, and the evidence that the ranking does not
depend on the scale. Everything else was restatement.
"""
import sys, collections

# Preferred column order. A library with no rows in the results is dropped rather than emptying the
# comparison, so running against a subset of checkouts produces a table for that subset.
PREFERRED = [
    "hxscript",
    "insanity",
    "hscript-pos",
    "hscript-improved-pos",
    "hscript-iris-pos",
    "rulescript-pos",
    "hscript",
    "hscript-improved",
    "hscript-iris",
    "rulescript",
]
LABEL = {
    "hxscript": "**hxScript**",
    "insanity": "insanity",
    "hscript-pos": "hscript",
    "hscript-improved-pos": "improved",
    "hscript-iris-pos": "iris",
    "rulescript-pos": "rulescript",
    "hscript": "hscript no-pos",
    "hscript-improved": "improved no-pos",
    "hscript-iris": "iris no-pos",
    "rulescript": "rulescript no-pos",
}
# Libraries that always track positions, so they have no separate -pos build.
NOPOS = {"hscript", "hscript-improved", "hscript-iris", "rulescript"}

# case -> scale -> lib -> (status, ms, value)
rows = collections.defaultdict(lambda: collections.defaultdict(dict))
parse = {}
tier = {}
order = []
scales = []

for raw in open(sys.argv[1]):
    raw = raw.strip()
    if raw.startswith("R|"):
        _, lib, case, t, iters, status, ms, value = raw.split("|", 7)
        n = int(iters) if iters.isdigit() else 0
        if case not in tier:
            tier[case] = t
            order.append(case)
        elif t != "?":
            tier[case] = t
        if n and n not in scales:
            scales.append(n)
        rows[case][n][lib] = (status, ms, value)
    elif raw.startswith("P|"):
        parts = raw.split("|")
        parse[parts[1]] = parts[3] if len(parts) > 3 else "crash"

scales.sort()
seen = {lib for c in rows for n in rows[c] for lib in rows[c][n]} | set(parse)
LIBS = [l for l in PREFERRED if l in seen]
MAIN = [l for l in LIBS if l not in NOPOS]

# The scale everything not explicitly about scale is reported at.
REF = scales[-1] if scales else 0

CALLS = ["call0", "call1", "call3", "callCap20", "fnTyped", "classCall"]
UNWIND = ["loopCont", "tryCatch"]

# Cases that do materially more than one operation per iteration, so averaging them beside ones that
# do not says nothing. `arrayCompr` runs a nested five-iteration loop per outer iteration, and
# `classNew` builds an object and an interpreter. Both are 5-100x the cost of anything else measured
# here, so a mean including them describes the outlier rather than the interpreter: `arrayCompr` alone
# moved hscript-iris's per-operation average from 0.53us to 1.02us, which would have reported it as
# twice as slow as it is. Kept in the list, out of the averages.
COMPOUND = ["arrayCompr", "classNew"]


def kind(case):
    """Which average a case feeds, which is also why a reader should or should not compare it."""
    if case in CALLS:
        return "call"
    if case in UNWIND:
        return "unwind"
    if case in COMPOUND:
        return "compound"
    return "op"


def cell(rec):
    if rec is None:
        return "n/a"
    status, ms, value = rec
    if status == "ok":
        return ms
    if status == "unsupported":
        return "not supported"
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


def ok(case, n, lib):
    return rows[case][n].get(lib, ("x",))[0] == "ok"


def shared(n, libs):
    """Cases every one of `libs` ran correctly at scale `n`."""
    return [c for c in order if n in rows[c] and all(ok(c, n, l) for l in libs)]


def avg(lib, cases, n):
    vals = [float(rows[c][n][lib][1]) * 1000.0 / n for c in cases if ok(c, n, lib)]
    return sum(vals) / len(vals) if vals else 0.0


def chart(title, unit, pairs, sort=True):
    """A single-series bar chart. Mermaid's xychart-beta has no legend, so every chart here plots one
    series and puts the comparison on the x-axis, where it needs no key to read.

    Used twice in the whole document, for the two figures the trade-off turns on. A chart of a number
    already in a table beside it is duplication, not illustration."""
    # Mermaid takes an axis label as a literal string, so the emphasis that makes this library stand
    # out in the tables would show up here as a pair of asterisks around the name.
    pairs = [(l.replace("*", ""), v) for l, v in pairs if v is not None]
    if not pairs:
        return
    if sort:
        pairs.sort(key=lambda t: t[1])
    top = max(v for _, v in pairs)
    top = round(top * 1.15, 3) if top < 10 else int(top * 1.15)
    # Decimals follow the VALUES, not the axis top. Keying them off the top rounded a chart whose
    # axis happened to reach 11 down to whole numbers, turning 1.391 and 8.467 into 1 and 8.
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
print("by degree. `unwind` cases are in neither, being dominated by how a library implements")
print("`continue` and `throw`, and nor are `compound` ones, which do far more than one operation per")
print("iteration and would describe themselves rather than the interpreter.")
print("")
# Folded away by default: it is the table of record and worth having, but it is thirty-odd rows and
# the summary underneath is what answers the question. GitHub renders <details> in Markdown; it does
# NOT support sortable tables, since it strips scripts, so the order here is the corpus order.
print("<details>")
print(f"<summary><strong>{sum(1 for c in order if REF in rows[c])} cases, click to expand</strong></summary>")
print("")
print("| case | kind | " + " | ".join(LABEL[l] for l in MAIN) + " |")
print("| --- | --- |" + " --- |" * len(MAIN))
for c in order:
    if REF not in rows[c]:
        continue
    print(f"| `{c}` | {kind(c)} | " + " | ".join(per_iter(rows[c][REF].get(l), REF) for l in MAIN) + " |")
print("")
print("</details>")

# ---------------------------------------------------------------- summary

sh = shared(REF, MAIN)
perop = [c for c in sh if kind(c) == "op"]
callc = [c for c in sh if kind(c) == "call"]
tot = {l: sum(float(rows[c][REF][l][1]) for c in sh) for l in MAIN}
base = tot["hxscript"] if tot.get("hxscript") else 1.0

print(f"\n### Summary, over the {len(sh)} cases every library ran\n")
print("| | " + " | ".join(LABEL[l] for l in MAIN) + " |")
print("| --- |" + " --- |" * len(MAIN))
print(f"| us per operation ({len(perop)} cases) | " + " | ".join("%.3f" % avg(l, perop, REF) for l in MAIN) + " |")
print(f"| us per call ({len(callc)} cases) | " + " | ".join("%.3f" % avg(l, callc, REF) for l in MAIN) + " |")
print("| parse, ms | " + " | ".join(str(parse.get(l, "n/a")) for l in MAIN) + " |")
print("| corpus total, ms | " + " | ".join("%.0f" % tot[l] for l in MAIN) + " |")
print("| total relative to hxScript | " + " | ".join("%.2fx" % (tot[l] / base) for l in MAIN) + " |")

chart(f"Cost of one operation at {REF:,} iterations", "microseconds", [(LABEL[l], avg(l, perop, REF)) for l in MAIN])
chart(f"Cost of one call at {REF:,} iterations", "microseconds", [(LABEL[l], avg(l, callc, REF)) for l in MAIN])

# ---------------------------------------------------------------- frame budget

# The same averages read as a budget, which is the shape a game actually needs: not "how many
# microseconds does this cost" but "how much script fits in a frame". A 60Hz frame is 16.667ms, and
# no game gives scripts all of it. 2ms is a realistic slice with rendering and physics to pay for.
FRAME_US = 1000000.0 / 60.0
SLICE_MS = 2.0

print("\n### How much script fits in one frame\n")
print(f"The per-operation and per-call averages read as a budget. A 60Hz frame is {FRAME_US / 1000:.3f}ms;")
print(f"the second pair is a {SLICE_MS:.0f}ms slice of it, which is a more realistic allowance once")
print("rendering and physics are paid for. Whole units, rounded down.\n")
print("**Derived, not measured at this scale.** Timing a frame's worth of work directly is dominated")
print("by noise, because a few hundred operations is far too short an interval to time on a preemptive OS.")
print(f"These come from the {REF:,}-iteration averages above, which are stable, multiplied back out.")
print("Read it the other way for a budget you already have in mind:\n")
print("```")
print("per-call us  x  calls per frame  x  60  =  us per second spent in script")
print("```\n")
print("| | " + " | ".join(LABEL[l] for l in MAIN) + " |")
print("| --- |" + " --- |" * len(MAIN))


def budget(cases, us):
    out = []
    for l in MAIN:
        a = avg(l, cases, REF)
        out.append("{:,}".format(int(us / a)) if a else "n/a")
    return out


print("| operations per 60Hz frame | " + " | ".join(budget(perop, FRAME_US)) + " |")
print("| calls per 60Hz frame | " + " | ".join(budget(callc, FRAME_US)) + " |")
print(f"| operations per {SLICE_MS:.0f}ms slice | " + " | ".join(budget(perop, SLICE_MS * 1000)) + " |")
print(f"| calls per {SLICE_MS:.0f}ms slice | " + " | ".join(budget(callc, SLICE_MS * 1000)) + " |")

# ---------------------------------------------------------------- scale

# Only meaningful with more than one scale. With one it printed a table restating the summary and a
# spread row reading 0.0% for every library, which says nothing.
def spread(kind_name):
    out = []
    for l in MAIN:
        vals = []
        for n in scales:
            s = shared(n, MAIN)
            cs = [c for c in s if kind(c) == kind_name]
            vals.append(avg(l, cs, n))
        vals = [v for v in vals if v]
        out.append("%.1f%%" % ((max(vals) - min(vals)) / min(vals) * 100.0) if vals else "n/a")
    return out


if len(scales) > 1:
    print("\n### The ranking does not depend on the scale\n")
    print("The whole corpus at each scale. If a difference only showed up at one size it would be a")
    print("warm-up or fixed-setup artefact rather than a property of the interpreter.\n")
    print("| | " + " | ".join(LABEL[l] for l in MAIN) + " |")
    print("| --- |" + " --- |" * len(MAIN))
    for n in scales:
        s = shared(n, MAIN)
        cs = [c for c in s if kind(c) == "op"]
        print(f"| us per operation, {n:,} | " + " | ".join("%.3f" % avg(l, cs, n) for l in MAIN) + " |")
    for n in scales:
        s = shared(n, MAIN)
        cs = [c for c in s if kind(c) == "call"]
        print(f"| us per call, {n:,} | " + " | ".join("%.3f" % avg(l, cs, n) for l in MAIN) + " |")
    print("| spread, operations | " + " | ".join(spread("op")) + " |")
    print("| spread, calls | " + " | ".join(spread("call")) + " |")

# ---------------------------------------------------------------- no-pos

if any(l in seen for l in NOPOS):
    pairs = [("hscript-pos", "hscript"), ("hscript-improved-pos", "hscript-improved"),
             ("hscript-iris-pos", "hscript-iris"), ("rulescript-pos", "rulescript")]
    pairs = [(a, b) for a, b in pairs if a in seen and b in seen]
    if pairs:
        print("\n### What position tracking costs the libraries that can switch it off\n")
        print("Not a ranking. hxScript cannot turn positions off, so the comparison above is built")
        print(f"with them on everywhere; this is what that decision costs the others. At {REF:,}.\n")
        s = shared(REF, [l for p in pairs for l in p])
        op = [c for c in s if kind(c) == "op"]
        print("| | " + " | ".join(LABEL[a] for a, _ in pairs) + " |")
        print("| --- |" + " --- |" * len(pairs))
        print("| us per operation, with | " + " | ".join("%.3f" % avg(a, op, REF) for a, _ in pairs) + " |")
        print("| us per operation, without | " + " | ".join("%.3f" % avg(b, op, REF) for _, b in pairs) + " |")
        print("| cost | " + " | ".join(
            ("%.1f%%" % ((avg(a, op, REF) / avg(b, op, REF) - 1) * 100.0)) if avg(b, op, REF) else "n/a"
            for a, b in pairs) + " |")
        print("| parse with, ms | " + " | ".join(str(parse.get(a, "n/a")) for a, _ in pairs) + " |")
        print("| parse without, ms | " + " | ".join(str(parse.get(b, "n/a")) for _, b in pairs) + " |")
