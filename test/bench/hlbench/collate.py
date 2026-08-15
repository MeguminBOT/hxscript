"""Collate the HashLink benchmark lines into one per-case table and the ratios that matter.

Output goes between the GENERATED markers in `docs/hl-benchmarks.md`.

Same table shape as the two collators next door, on purpose: the three documents are read together
and a reader moving between them should not have to learn a third format.

What differs is what the columns ARE. The other two suites compare things of one kind: six
interpreters, or one library's three modes. This one compares a script against the program it would
have been if you had not scripted it, so two of its four columns are Haxe with no library in them at
all. The interesting numbers here are therefore ratios against a floor rather than against each
other: what running on the VM costs against a native binary, and what putting the code in a script
costs on top of that.
"""
import sys, collections

# Slowest last, which is also the order the document reads them in: the floor first, then what sits
# on it.
PREFERRED = ["hashlink/c", "hashlink/vm", "hxscript-hl/c", "hxscript-interp"]
LABEL = {
    "hashlink/c": "hashlink/c",
    "hashlink/vm": "hashlink/vm",
    "hxscript-hl/c": "hxscript hl/c",
    "hxscript-interp": "hxscript interp",
}

# case -> column -> (status, ms, value)
rows = collections.defaultdict(dict)
prep = {}
tier = {}
order = []
scale = 0

for raw in open(sys.argv[1]):
    raw = raw.strip()
    if raw.startswith("R|"):
        _, col, case, t, iters, status, ms, value = raw.split("|", 7)
        if iters.isdigit():
            scale = max(scale, int(iters))
        if case not in tier:
            tier[case] = t
            order.append(case)
        elif t != "?":
            tier[case] = t
        rows[case][col] = (status, ms, value)
    elif raw.startswith("P|"):
        parts = raw.split("|")
        prep[parts[1]] = parts[2] if len(parts) > 2 else "crash"

seen = {c for case in rows for c in rows[case]} | set(prep)
COLS = [c for c in PREFERRED if c in seen]


# Below this many microseconds per iteration, Haxe removed the loop rather than running it. Noted in
# the table so a reader knows why a native column can read ~0, and NOT excluded from anything: what
# this suite is for is the difference between a script and the program you would otherwise have
# shipped, and the program you would otherwise have shipped is the optimised one.
FOLD_LIMIT = 0.0005


def ok(case, col):
    return rows[case].get(col, ("x",))[0] == "ok"


def folded(case, col):
    """Whether the compiler removed this case's loop rather than running it."""
    if not ok(case, col) or not scale:
        return False
    return float(rows[case][col][1]) * 1000.0 / scale < FOLD_LIMIT


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
        return "WRONG (%s)" % value
    return status


def per_iter(case, col):
    """Microseconds per iteration, the status text, or `folded` when no loop was emitted."""
    rec = rows[case].get(col)
    if rec is None or rec[0] != "ok" or not scale:
        return cell(rec)
    v = float(rec[1]) * 1000.0 / scale
    # Marked rather than dropped, so the row still carries its time and the reader still knows the
    # native side did not have to run it.
    return ("%.4f (folded)" % v) if folded(case, col) else ("%.4f" % v)


def shared(cols, kinds=None):
    """Cases every one of `cols` ran correctly, optionally restricted to some tiers."""
    return [c for c in order
            if all(ok(c, col) for col in cols)
            and (kinds is None or tier.get(c) in kinds)]


def ratio(v, base):
    """`v` against `base`, which is not a number when the compiler removed the base's loop."""
    if base <= 0:
        return "1.0x" if v <= 0 else "vs ~0"
    return "%.1fx" % (v / base)


def avg(col, cases):
    vals = [float(rows[c][col][1]) * 1000.0 / scale for c in cases if ok(c, col)]
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
    top = round(top * 1.15, 4) if top < 10 else int(top * 1.15)
    dec = "%.4f" if top < 1 else ("%.3f" if top < 20 else ("%.1f" if top < 1000 else "%.0f"))
    print("")
    print("```mermaid")
    print("xychart-beta")
    print('    title "%s"' % title)
    print("    x-axis [" + ", ".join('"%s"' % l for l, _ in pairs) + "]")
    print('    y-axis "%s" 0 --> %s' % (unit, top))
    print("    bar [" + ", ".join(dec % v for _, v in pairs) + "]")
    print("```")


# ---------------------------------------------------------------- the summary

print("\n### What a script costs against the same program compiled\n")

base = "hashlink/c"
ops = shared(COLS, {"op"})
calls = shared(COLS, {"call"})

if base in COLS and ops:
    print("Averaged over the %d `op` cases and the %d `call` cases every column ran correctly, at"
          % (len(ops), len(calls)))
    print("%s iterations each. `x` is against `hashlink/c`, the native binary, which is the floor:" % format(scale, ","))
    print("what the language costs once Haxe has seen the code.\n")
    print("| column | op, us/iter | x | call, us/iter | x | getting ready |")
    print("| --- | --- | --- | --- | --- | --- |")
    b_op = avg(base, ops)
    b_call = avg(base, calls)
    for col in COLS:
        o = avg(col, ops)
        c = avg(col, calls)
        ro = ratio(o, b_op)
        rc = ratio(c, b_call)
        ready = prep.get(col, "-")
        if ready not in ("-", "crash", "compiled into the binary"):
            ready = "%s ms" % ready
        print("| `%s` | %.4f | %s | %.4f | %s | %s |" % (LABEL.get(col, col), o, ro, c, rc, ready))

    chart("Ordinary operations, microseconds per iteration (lower is better)", "us/iter",
          [(LABEL.get(c, c), avg(c, ops)) for c in COLS])
    chart("Calls, microseconds per iteration (lower is better)", "us/iter",
          [(LABEL.get(c, c), avg(c, calls)) for c in COLS])

    gone = sorted({c for c in order for col in COLS if folded(c, col)})
    if gone:
        print("")
        print("%d of those cases are marked `folded` below, meaning Haxe proved the answer and emitted no" % len(gone))
        print("loop at all: " + ", ".join("`%s`" % c for c in gone) + ".")
        print("")
        print("They are counted anyway, and that is the point rather than a caveat. What a host is")
        print("deciding is whether to put this logic in a script or leave it as Haxe, and if it is left as")
        print("Haxe the optimiser is part of what it gets. `vs ~0` in the table above is that answer taken")
        print("to its limit: the native side did not run at all, and the scripted side ran every iteration.")

# ---------------------------------------------------------------- the list

print("\n### Every case, microseconds per iteration at %s\n" % format(scale, ","))
print("`kind` is which average the row feeds. `op` and `call` are averaged separately because they")
print("differ by design rather than by degree; `unwind` and `compound` rows are in neither, being")
print("dominated by how a mode implements `continue` and `throw`, or by doing far more than one")
print("thing per iteration.\n")

refused = sorted({c for c in order for col in COLS if rows[c].get(col, ("",))[0] == "unsupported"})
if refused:
    print("`refused` is a compiler declining a construct it does not emit: nothing ran, because the")
    print("module is rejected whole. Those rows are the edge of the compiled subset: "
          + ", ".join("`%s`" % c for c in refused) + ".\n")

print("<details>")
print("<summary><strong>%d cases, click to expand</strong></summary>\n" % len(order))
print("| case | kind | " + " | ".join("`%s`" % LABEL.get(c, c) for c in COLS) + " |")
print("| --- | --- | " + " | ".join("---" for _ in COLS) + " |")
for case in order:
    cells = " | ".join(str(per_iter(case, col)) for col in COLS)
    print("| `%s` | %s | %s |" % (case, tier.get(case, "?"), cells))
print("\n</details>")
