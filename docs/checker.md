# Static checking: a design, not an implementation

hxScript enforces types **as values pass through them**. A wrong type throws when the assignment,
argument or return actually happens, which catches the same mistakes real Haxe would, just later,
and only on lines that ran.

This page is the design for catching some of them *before* a script runs. Nothing here is built.
It exists so the open to-do item means something more than one line, and so whoever picks it up
starts from the boundary rather than rediscovering it.

hscript-insanity had a `Checker`. It was removed as dead code: it predated the compiled type table and could
not see the host's types, so it could not check the thing scripts spend most of their time touching.

## What a checker could prove

Without inferring anything, walking the parsed AST against `TypeCollection`:

| Check | Example | How it is proven |
| --- | --- | --- |
| Literal against annotation | `var x:Int = "hi";` | the literal's type is on its face |
| Unknown type in an annotation | `var y:Nope;` | `Nope` resolves in no type table |
| Unresolvable identifier | `trace(notDeclared);` | not a local, field, import or global |
| Arity on a script-declared call | `foo(1, 2, 3)` where `foo` takes 2 | the declaration is in the same AST |
| Unknown field on a script-declared type | `new Thing().nope()` | `ClassDecl.fields` is right there |
| `override` with no base method | `override function gone()` | the base is scripted, or compiled and reflectable |
| Duplicate declarations | two `var x` in one scope | scope walk |

Each of these has one property in common: **the answer does not depend on what any expression
evaluates to.** That is the whole selection rule.

## What it could not prove

Everything whose answer needs a type the interpreter does not have until the value exists:

```haxe
var z:Int = someCall();   // needs someCall's return type
var w:Int = a + b;        // needs a and b, and the + rules
var q:Int = obj.field;    // needs obj's type
```

A compiled function's parameter and return types are gone at runtime, the same erasure that makes
type-checking `using` extensions on compiled classes impossible (see [parity.md](parity.md)). A
checker could special-case script-declared functions, whose declarations survive, but then it checks
one half of a call graph and stays silent on the other, which is a confusing tool to use.

Going further means inferring: propagating types through expressions, operators, and calls. That is
a type inference engine, and every rule in it is a chance to **reject a valid script**, which is far worse
than the current behaviour, because a false positive stops a script that would have run correctly.

## Where it would hook in

`Script.start` and `Module.start` parse before they execute. A checker runs between those two steps,
over the AST, with:

- `TypeCollection.main` and the environment's types, for resolving names to compiled types;
- the module's own declarations, for script-declared types;
- `Config` (imports, blacklists, preprocessor values), so a check agrees with what the interpreter
  would actually resolve.

It reports a list rather than throwing on the first problem, because the value of a pre-run check is
seeing everything at once, and is **opt-in**. A host that loads user scripts at runtime may prefer to run
a partially-broken script and surface errors per call, which is exactly what the existing behaviour
gives it.

## Why it is not built

It is a large piece of work whose useful half (the table above) overlaps heavily with what runtime
enforcement already catches on the first run, and whose valuable half (inference) is the part that
can reject valid code. Building the cheap half first is reasonable; doing it *well enough to be
trusted* is what makes it large.

The honest summary: this would turn some runtime throws into pre-run reports. It would not turn
hxScript into a typed compiler, and a design that implies otherwise is the failure mode to avoid.
