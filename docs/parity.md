# Haxe parity: what is and isn't supported

hxScript is a **tree-walking interpreter**, not a compiler. It parses Haxe-shaped source
and evaluates it directly, so it reaches a large slice of the language, classes, interfaces,
enums, typedefs, `using`, closures, comprehensions. It also runs **typed by default**: declared
types on variables, parameters, returns, and `cast(x, T)` are enforced at runtime (see section 1).
What it still cannot do is any *compile-time* work, no inference, no overload resolution, no
static errors. This page is the reference for those gaps: the things regular Haxe can do that a
script here cannot (or does differently).

> [!NOTE]
> This complements the checklist in the [README TO-DO](../README.md#to-do). The README tracks
> feature completion; this page explains the *boundaries* and *why* they exist, with pointers into
> the source.

For putting the library into a project in the first place, see the
[embedding guide](embedding.md).

## At a glance

| Works with parity | Erases / weakened | Not available |
| --- | --- | --- |
| classes, `extends`, `override` | type parameters (erased) | macros / `@:build` / reification |
| scripted + native interfaces | structural typedefs (values, not literals) | |
| enums (+ params, `switch` extraction, guards, `\|`) | | `@:structInit`, `@:multiType` |
| abstracts, scripted and native: `@:op`, `@:arrayAccess`, `from`/`to` | | |
| typedef aliases | custom metadata (mostly inert) | compile-time type errors / inference |
| static / instance / `private` / getters-setters | `private` enforcement (opt-in, explicit only) | overload resolution |
| `using` (typed on scripted classes), `import` (`as` / `.*` / single field) | typed metadata / `untyped` (no-op) | overriding native `inline`/`final`/`@:generic` methods |
| string interpolation, comprehensions | | interface default methods |
| optional/default/rest args | | compile-time inlining / DCE |
| typed multi-catch, closures, `#if` | | |
| **runtime type enforcement** (`cast`/`is`/var/param/return) | | |
| **`Int`/`Float` correctness** | | type-checking `using` on compiled classes |

---

## 1. Typed by default, with a dynamic escape hatch

Type annotations are **enforced at runtime**, not just parsed. This is gated by `Config.typedMode`,
which defaults on (`-D hxscript_dynamic` flips the default off, and a host may set it per script
world). Enforcement flows through a single point, `tryCast` in
[`src/hxscript/runtime/Interp.hx`](../src/hxscript/runtime/Interp.hx), reached at variable declarations,
**every later write to an annotated variable**, function arguments, function returns, `(e : T)`,
`cast(x, T)`, and class and static field initialization:

- **`cast(x, T)` is a real checked cast.** In typed mode it throws when `x` is not a `T`, like Haxe's
  safe cast. `x is T` / `Std.isOfType(x, T)` also work for classes, interfaces, scripted enums, and
  the primitives.
- **Assignments are checked, Haxe-strict.** `var x:Int = aFloat`, a wrong-typed argument, or a return
  that doesn't match its declared type throws (surfaced through the script-error funnel). The
  declared type sticks to the variable, so a later `x = 'hi'` or `x += 'hi'` throws too rather than
  quietly retyping it. `Int` widens to `Float` where Haxe allows it, and an annotated variable
  applies its abstract's `from` cast on assignment the way it does at declaration. Containers (`Array`, `Map`) and function types (a callable
  is required for `f:Int->Void`) are checked; structural typedefs are checked by field presence, and
  `private` members are access-checked. A **class or static field** declared with a type binds
through the same path a local does (`Interp.bindDeclared`), so an abstract-typed field boxes and
records its type rather than storing the bare underlying value.
- **`Int` and `Float` are correct.** Integer arithmetic stays `Int` (so `is Int`, integer map keys,
  and array indices behave), and `/` is always `Float`. One platform caveat: on hxcpp a
  whole-number `Float` boxed in a `Dynamic` reads back as `Int` (`Type.typeof(10/2)` is `TInt`).
  That is harmless, and unavoidable in a `Dynamic` interpreter.

What is still missing is everything that needs the *compiler*:

- **No compile-time type errors and no inference.** Mismatches surface as runtime throws, not
  editor/compile errors. There is no static checker in the library (hscript-insanity's was removed as
  dead code). [checker.md](checker.md) is the design for one: what it could prove without
  inference, what it could not, and why the boundary sits there.
- **No overload resolution.** Haxe's method overloading and implicit conversions at call boundaries
  don't exist.
- **`untyped` is a no-op**, there is nothing to suppress.

Setting `Config.typedMode = false` (or `-D hxscript_dynamic`) reverts to fully-dynamic behavior:
annotations are ignored and only abstract `from`/`to` casts apply.

## 2. Type parameters and structural types erase

- **Generics are erased.** `class Pool<T>` parses and runs, but parameter *names* are kept and
  *constraints are dropped*; every `T` resolves to `Dynamic`. See the note on
  `params:Array<String>` in [`src/hxscript/syntax/Expr.hx`](../src/hxscript/syntax/Expr.hx). There is no
  generic type safety.
- **Anonymous-structure typedefs are checked by shape *and* by field type.** `typedef Foo = {x:Int}`
  (named or inline `{x:Int}`) works for `is`, `cast`, and variable/argument annotations. A value has
  to carry every field the structure declares, and each field has to satisfy its own annotation,
  recursively for nested structures (`ScriptedTypedef.matchesStructure` and `Interp.matchesType`).
  Optional fields are supported in both spellings, `?x:Int` and `@:optional x:Int`, and may be
  absent; when present they are still type-checked.

  Two differences from Haxe remain. **Extra fields are accepted**: Haxe rejects a *literal* carrying
  fields the expected type does not declare, but this is a check on a runtime value, and a value with
  more fields than required still satisfies the structure. And **generic field types erase with
  everything else**, so `{items:Array<Int>}` only checks that the field is an `Array`.

  **Function typedefs** (`typedef F = Int->Void`) have no matchable shape; a value only has to be
  callable.

## 3. Abstracts

A script may declare `abstract` and `enum abstract`, and both work.

A scripted `abstract` boxes a value of its underlying type. Its constructor, methods, properties,
statics, `@:op` operators, `@:arrayAccess`, and `@:from` / `@:to` conversions all run, and an
annotation (`var m:Meters = 2.5`) boxes implicitly, as does `cast(x, Meters)`. `is` tells values of
one abstract from another. An `enum abstract` stays what it always was, a set of constants, reachable
qualified or bare.

The implementation is the one Haxe itself uses: every method becomes a static taking the boxed value
as its first argument, named `this` (`ScriptedAbstract` in
[`src/hxscript/types/ScriptedAbstract.hx`](../src/hxscript/types/ScriptedAbstract.hx)). That makes `this` an
ordinary parameter, so argument binding, scoping and `return` all behave, and a constructor's
`this = v` is just a write to it.

Limits worth knowing:

- **Inside an abstract's own methods, a parameter of the abstract's own type arrives as the
  underlying value**, exactly like `this`. This is what Haxe does too, and it is what makes
  `this + rhs` arithmetic rather than an endless re-dispatch into the operator that is running. The
  consequence is that `rhs.someMethod()` will not work inside the body; call it through the abstract
  or re-box.
- **`this = v` outside the constructor does not propagate.** It writes the parameter, so the caller's
  value is unchanged.
- **A missing `from` is not an error.** Haxe requires a matching `from` for an implicit conversion;
  a value with no matching `@:from` is boxed directly instead of being rejected.
- **No `@:multiType`**, and type parameters erase as everywhere else. `@:forward` does work on a
  scripted abstract, bare (every field of the boxed value) or with a list of names.

Native (compiled) abstracts *are* bridged via
[`src/hxscript/macro/Abstract.hx`](../src/hxscript/macro/Abstract.hx): static and instance fields,
`from`/`to` casts, and operator overloading all work. The build macro records which method serves
each operator and the interpreter dispatches `a + b` to it, so scripts get the same results the
compiled code does. `@:forward` is the exception: it is honoured on a scripted abstract but not on a
compiled one, so a forwarded field of a native abstract is not reachable. Three further limits:

- **Binary, unary and array-access operators dispatch.** `@:op(A + B)` and friends, including `==`
  and the ordering operators; `@:op(-A)`, `@:op(!A)` and `@:op(~A)`; and `@:arrayAccess` getters and
  setters for `a[i]` and `a[i] = v`. `a++` is the exception: it goes through the increment path,
  which applies `+ 1` to whatever the operand is.
- **The left operand is tried first**, and the right one only for `+` and `*`, so `1 + vec`
  dispatches (as `@:commutative` does in Haxe) while `1 - vec` falls back to the boxed values rather
  than applying a non-commutative operator the wrong way round. The `@:commutative` metadata itself
  is not required, or read.
- **`!=` is derived from `==`**, so an `@:op(A != B)` that is not the negation of `@:op(A == B)` is
  ignored.

Where no `@:op` applies, the operands fall back to the values they box. That is deliberately more
permissive than Haxe, which rejects `a < b` between two abstracts unless the operator is declared,
and it is what makes an abstract with no operators at all compare by value instead of by wrapper
identity.

## 4. Overriding native (bridged) methods has holes

Scripts extend curated native bases through generated bridges
([`src/hxscript/macro/Scripted.hx`](../src/hxscript/macro/Scripted.hx)). A native
method **cannot be overridden** when it is:

- **`inline`**, which Haxe forbids overriding outright. (Not because the method has no runtime form:
  it does, and reflection finds it. See section 7.)
- **`final`**.
- **`@:generic`**, the compiler emits one specialized field per instantiation, so there is no single
  method to override.
- **`dynamic`**, `super.f()` is illegal on it; scripts reassign these at runtime instead.
- signed with a **`private`/inaccessible type**, or a **class type-parameter that couldn't be
  substituted**, such methods fall through to the native `super` silently.

## 5. No macros or compile-time metaprogramming

Scripts cannot define or run macros, `@:build`/`@:autoBuild`, expression reification (`macro ...`),
or `@:genericBuild`. Those mechanisms run at *engine* compile time; script code is the dynamic layer
and never reaches that stage.

## 6. Smaller semantic differences

- **Access control is partial.** `private` is enforced in typed mode (or when `Config.strictAccess` is
  set), but only for members marked `private` *explicitly*. **Unmarked members are public**, unlike
  Haxe, where the default is stricter. `@:privateAccess` waives the check at the call site, as in
  Haxe. See `checkAccess` in
  [`src/hxscript/runtime/Interp.hx`](../src/hxscript/runtime/Interp.hx).
- **Custom metadata is inert.** Only a handful are honored: `@:privateAccess`, `@:bypassAccessor`,
  `@:snapshot`, `@:safe`, `@:enumAbstract`, `@:enum`, `@:keep`, `@:coreType`. Anything else parses
  and does nothing.
- **Interfaces carry no default implementations**, signatures only.
- **No `@:structInit` or `@:multiType`.** `Map` is the one special-cased multi-type
  (its implementation is picked from the key type). `@:op` and `@:arrayAccess` are honored on native
  abstracts only; see section 3.
- **`inline` / `final` have no optimization effect**, they parse, but everything is interpreted.
  There is no constant folding, inlining, or dead-code elimination; expect interpreter-level
  performance.

## 7. Scripts can only reach what survives DCE

A script calls native code by reflection, which the compiler cannot see. With dead code elimination
on (Haxe defaults to `-dce std`), a std or library method that the **host** never calls statically
can be stripped, and the script's call then fails at runtime with "Cannot call null".

This is easy to mistake for a library bug. A standalone test program that never touches `EReg`
compiles without `EReg.replace`, so `~/a+/g.replace(...)` fails there while working under `-dce no`.

Mitigations, in order of preference: call the API somewhere in the host, add an `include()` for the
type in the build, or register a `Config.callShims` entry.

**It is per MEMBER, not per class**, which is what makes it confusing in practice. A host that calls
`StringTools.trim` in three hundred places keeps `trim` and loses `isSpace`, so scripts see a
`StringTools` that resolves fine and is missing exactly the members nobody happened to use.

**`inline` is not a second cause of this, and it is routinely blamed for it.** On hxcpp a `static
inline` or `inline` member still has a runtime form and reflects fine, verified by declaring one and
reading it back with `Reflect.field` under both `-dce std` and `-dce no`. What removes it is DCE
noticing that every call site inlined it, so nothing references it any more. Only **`extern inline`**
has genuinely no body to emit; that is the case `Config.callShims` exists for (see section 8).

`StringTools.trim` is the usual example given, and it is a bad one twice over: on the C++ target it
is not `inline` at all (only on `cs`/`java`), and when it goes missing it is because the host never
called it.

## 8. Interop subtlety worth knowing

Scripted types are ordinary **class instances**, not native `Class<T>` / `Enum<T>` / `EnumValue`
runtime objects. Any interop path that hard-types a parameter or return as one of those will coerce a
scripted instance to `null` at the call boundary (this is what broke bare enum construction before
the `createEnum` fix, see the note on that method in
[`src/hxscript/runtime/Interp.hx`](../src/hxscript/runtime/Interp.hx)). Keep scripted-type boundaries
`Dynamic`.

---

## Static extensions

A `using` works on a script-declared class and on a compiled one, but only one of the two can be
type-checked.

Two placement rules come first, and both match Haxe. A `using` has to appear **before any
declaration** in the script, and it cannot name a class the *same script* declares: the extension
has to be compiled, or declared in another `Module` in the same `Environment`. Reaching for a
locally-declared one fails at parse time with `import and using may not appear after a
declaration`, which reads like a placement error rather than the scoping one it is.

A **script-declared** extension still has its declaration at runtime, so the receiver is checked
against the first parameter's declared type (`ScriptedClass.staticArgType`, then
`Interp.typeMatches`) before the call. Several extensions may therefore share a method name, and
`(5).twice()` reaches the one that accepts an `Int` rather than whichever registered first.
`typeMatches` is `tryCast` without the throw, deliberately: the test that *selects* an extension
and the test that *enforces* an annotation cannot drift apart.

A **compiled** extension's parameter types do not exist at runtime, so there is nothing to check
it against. A mismatch can only be found by calling and failing, which is what happens. The
practical consequence: a compiled extension whose name collides with another may be tried first
and rejected on an exception, and a compiled extension that throws internally on a legitimate
call is indistinguishable from one that did not apply. Prefer script-declared extensions where
the name is not unique.

## What has parity

For reference, the following behave like Haxe:

- classes, `extends`, `override`, `super(...)`;
- scripted interfaces **and** native interface implementation (via the bridge);
- enums with parameterized constructors, and `switch` with extraction, guards, `|` alternatives, and
  array/object patterns;
- typedef aliases to named types;
- `static` / instance / `private` / getters & setters (`get`/`set`/`null`/`never`/`default`/
  `dynamic`), `final` fields;
- `using` static extensions, **selected by receiver type** when the extension is declared in a
  script (see below);
- `import`, normal, `as` alias, wildcard `.*`, and single static field / enum constructor;
- string interpolation (`'$ident'`, `'${expr}'`), array and map comprehensions;
- optional, default, and rest (`...`) arguments;
- typed **multi-catch** and raw `throw` of any value;
- closures with capture and self-recursion;
- `#if` / `#elseif` / `#else` / `#end` preprocessing against defines;
- runtime **type enforcement** of variable, parameter, return, and `cast(x, T)` annotations, plus
  `is` / `Std.isOfType` on classes, interfaces, scripted enums, and the primitives (typed mode);
- **`Int`/`Float` correctness**, integer arithmetic stays `Int`, `/` is `Float`.
