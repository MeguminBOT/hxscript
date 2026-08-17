# hxcpp issues

Faults that live in hxcpp rather than in this library, found while making compiled scripts agree with
the interpreter. Everything here reproduces with hxcpp's own bytecode grammar and most of it affects
Haxe's own cppia output too, so none of it is about how this emitter writes things.

Paths are relative to the root of an hxcpp checkout. Which checkout a build actually links is
whatever `haxelib path hxcpp` reports, which is not always the one being read.

## Applying the fixes

Two ways, and the first is less work.

**A prepatched hxcpp.** Every fix below that has one is already applied on
[`MeguminBOT/hxcpp`, branch `patched-hxscript`](https://github.com/MeguminBOT/hxcpp/tree/patched-hxscript):

```sh
haxelib git hxcpp https://github.com/MeguminBOT/hxcpp patched-hxscript
```

Nothing else about it diverges from upstream, so this is the ordinary hxcpp with the fixes in it.
The trade is the usual one for tracking a fork: `haxelib upgrade` will not move it, so it wants
pulling by hand when upstream moves.

**Or patch the hxcpp you already have.**

```sh
python patches/apply-hxcpp.py            # apply, and say what was already there
python patches/apply-hxcpp.py --check    # report only, change nothing
python patches/apply-hxcpp.py --revert   # put the originals back
```

It finds hxcpp through `haxelib path hxcpp` unless given `--path`, and it is idempotent, so run it
again after every `haxelib upgrade`. Nothing is written unless every fix that is not already there
matched exactly: a half applied hxcpp is a state nobody has tested. `--revert` restores the files
byte for byte, and `--check` exits 1 when there is work to do and 0 when there is not, so it can gate
a build. It reports which issues below it closes when it runs, so the two files cannot drift about
what "covered" means.

**hxcpp compiles its runtime into each project** either way, so anything built before applying keeps
the old behaviour until it is rebuilt. Delete the binary rather than trusting a rebuild to notice.

Issues 1, 2, 3 and 7 are covered. The rest have no patch yet.

**Issue 1's fix is required, not optional.** This library declares a `Bool` field with its real type
by default, which is what makes a boolean read back as `true` in every mode including jitted. Against
a stock hxcpp that field gets an integer slot instead. `-D hxscript_cppia_bool_compat` is the way out
for a build that cannot patch: it emits no type and marks the value, which is right interpreted and
still wrong jitted, because the jitted store of a boolean into an object slot is a separate fault
that is not understood. So the choice is a patched hxcpp and agreement everywhere, or a stock one and
agreement only while interpreting.

| # | issue | status |
| --- | --- | --- |
| 1 | A member field declared `Bool` never gets `fsBool` storage | patched on the fork, not upstream |
| 2 | `DataVal<T>` does not report itself as a boolean to the JIT | patched on the fork, not upstream |
| 3 | `convert` moves registers without a width, and the JIT refuses | patched on the fork, not upstream |
| 4 | `CallMember` trusts a vtable slot it did not verify, and segfaults | open, no patch |
| 5 | `Type.getEnumConstructs` on a non-enum ends the process | open, avoided rather than fixed |
| 6 | An hxcpp binary writing to `NUL` on Windows ends there | open, avoided rather than fixed |
| 7 | A jitted `throw` never leaves the context, so the caller reads null | patched on the fork, not upstream |
| 8 | A `Bool` put in a `Map` from a script comes back an `Int` | open, and it is Haxe's std rather than hxcpp |

Everything listed here has been reproduced. Something suspected and not yet pinned down does not go
in this file, because a wrong entry costs more than a missing one.

---

## 1. A member field declared `Bool` never gets `fsBool` storage

**`src/hx/cppia/CppiaVars.cpp`, `CppiaVar::linkVarTypes(CppiaModule &cppia, int &ioOffset)`.**

There are two `linkVarTypes`. The static one asks `fieldStorageFromType(type)`, which is the function
that knows about booleans:

```cpp
case etInt:
   if (inType->name==HX_CSTRING("Bool"))
      return fsBool;
   return fsInt;
```

The member one does not call it. It re-derives storage from `exprType` alone:

```cpp
switch(exprType)
{
   case etInt: ioOffset += sizeof(int); storeType=fsInt; break;
   ...
}
```

`TypeData::link` maps the name `Bool` to `etInt` beside `Int` (`Cppia.cpp`, around line 8247), so by
the time this switch runs the distinction is already gone. **A `Bool` member therefore gets an integer
slot, and reading it back through reflection answers `1` rather than `true`.** `fsBool` is reachable
for a static and unreachable for a member.

Everything downstream is already in place, which is what makes this look like an oversight rather
than a design decision:

- `Cppia.cpp:4641` builds `MemReference<bool,locObj>` / `MemReference<bool,locThis>` for `fsBool`.
- `CppiaVars.cpp:210` and `:228` read and write `*(bool *)(base)`, which boxes a real `Bool`.
- `MemReferenceSetter::genCode` handles a one-byte target: `sizeof(T)==1` picks `jtByte` and takes the
  `useTemp` path.

**This affects Haxe's own cppia output.** `script_type_string` writes `bool` for such a field and
`TypeData::link` renames it to `Bool`, so a Haxe-generated module hits exactly the same switch. It
has probably gone unnoticed because typed code reading `o.flag` is fine with an integer 0 or 1; only
reflection, `Std.string` and dynamic access can tell.

### The patch

Mirror the static variant, then size from the storage rather than from `exprType`. This is the exact
text `patches/apply-hxcpp.py` writes, replacing the `switch(exprType)` above:

```cpp
      storeType = typeId==0 ? fsObject : fieldStorageFromType(type);

      switch(storeType)
      {
         case fsBool: ioOffset += sizeof(int); break;
         case fsByte: ioOffset += sizeof(int); break;
         case fsInt: ioOffset += sizeof(int); break;
         case fsFloat: ioOffset += sizeof(Float); break;
         case fsString: ioOffset += sizeof(String); break;
         case fsObject: ioOffset += sizeof(hx::Object *); break;
         case fsUnknown:
            break;
      }
```

Every case is written out rather than left to a `default`, so a storage kind added upstream fails to
compile here instead of silently getting no offset. `sizeof(int)` for the boolean rather than
`sizeof(bool)` keeps the layout and the surrounding `AlignOffset` call exactly as they are, so a
one-byte field simply leaves three bytes unused. Getting the size back is a separate change and is not
worth coupling to a correctness fix.

### Confirmed by building it

Patched, with the field declared `Bool` for real, every boolean reads back as `true` under the JIT
and interpreted alike, including one with no annotation whose type is inferred from its initialiser.
`test/cpp/BoolProbe.hx` is the reading, and the conformance table's `hxcpp-cppia-jit` column went to
0 differ with it.

### The way out for a stock hxcpp

`-D hxscript_cppia_bool_compat` emits a `Bool` field with **no declared type** and writes `CASTBOOL`
on the value. See `hxscript.Config.nativeBoolSlots`, `hxscript.cppia.Backend.isBool` and
`hxscript.cppia.Emitter.boolean`.

That is correct interpreted and still reads back as `1` under the JIT, so it is a fallback rather
than a substitute. Why it fails there has not been established, and it is deliberately not written up
as an hxcpp fault, since it may equally be this library's: the store is confirmed to reach an
`fsObject` slot with a `CASTBOOL` value, and a diagnostic in `MemReferenceSetter::genCode` never
fires for it, so the write is taking a route that has not been identified.

---

## 2. `DataVal<T>` does not report itself as a boolean to the JIT

**`src/hx/cppia/Cppia.cpp`, `struct DataVal<T>`, around line 4805.**

`tok=="true"` builds `new DataVal<bool>(true)`. Interpreted, `DataVal<bool>::runObject` does
`Dynamic(data)` with a C++ `bool`, so a real `Bool` is boxed. Under the JIT, `CppiaCompiler::convert`
chooses between `intToObj` and the branchy `Dynamic(true)`/`Dynamic(false)` pair by an `asBool` flag
that callers take from `CppiaExpr::isBoolInt()`, and **`DataVal` never overrides it**
(`Cppia.h:186` defaults to false) even though `ExprTypeOf<bool>` is `etInt` precisely because a bool
is carried as one.

So the same bytecode stores a boxed `Bool` interpreted and a boxed `Int` jitted.

### The patch

```cpp
bool isBoolInt() HXCPP_OVERRIDE { return ExprTypeIsBool<T>::value; }
```

`MemReference` already reports itself the same way for the same reason, so this is consistency rather
than invention.

---

## 3. `convert` moves registers without a width, and the JIT refuses

**`src/hx/cppia/CppiaCompiler.cpp`, three sites in `convert`, around lines 901, 920 and 947.**

`move(sJitArg0, inSrc)` with neither side given a width. sljit then rejects the move with
`Bad move target`, which takes down whatever was being compiled.

### The patch

```cpp
move(sJitArg0.as(jtInt), inSrc.as(jtInt));          // the etString case
move(sJitArg0.as(jtPointer), inSrc.as(jtPointer));  // the two etObject cases
```

Committed as `78d8605d` on branch `fix-cppia-jit-untyped-register-move`.

---

## 4. `CallMember` trusts a vtable slot it did not verify

**`src/hx/cppia/Cppia.cpp`, `CallMember::link`.**

When the named class resolves to a cppia class, the call becomes
`CallMemberVTable(..., type->cppiaClass->findFunctionSlot(fieldId), ...)` and dispatch goes through
that slot. hxcpp's own comment elsewhere says the order functions are written in is load bearing
("The order is important because cppia looks up functions by index"), and nothing checks that the
producer honoured it.

A producer that numbers its functions differently gets a **segfault** rather than an error naming the
class and the field. That is a real cost even for a producer at fault, because the fault is silent
until it is a crash in jitted code with no Haxe stack.

Writing an empty class name in `CALLMEMBER` forces dispatch by name and is order independent, which
is what this library does and why. The cost is that the call loses the callee's declared return type.

---

## 5. `Type.getEnumConstructs` on a non-enum ends the process

Passing a `Class` where an `Enum` is expected does not throw where a script can catch it; the process
goes down. Worked around here by only asking where the type is already known to be an enum.

Not investigated further, so there is no file and line yet.

---

## 6. An hxcpp binary writing to `NUL` on Windows ends there

Redirecting a binary's stderr to `/dev/null` from a POSIX shell on Windows sends it to `NUL`, and an
hxcpp binary writing its first report to it stops at that point. Nine conformance cases read as
having killed the process when every one of them was a refusal that had simply printed its reason.

Worked around in `test/lib/conformance.sh` by sending stderr to a real file, never to `/dev/null`,
which is worth doing anyway because the reasons are what a refusal is worth reading for.

---

## 7. A jitted `throw` never leaves the context, so the caller reads null and the process stays poisoned

**`src/hx/cppia/CppiaFunction.cpp`, `ScriptCallable::runFunction`, `ScriptCallable::runFunctionClosure`,
and the compiled branch of `CppiaClosure::__run`.**

Jitted cppia does not throw. `ThrowExpr::genCode` writes the value to `ctx->exception` and calls
`addThrow()`, which jumps to the function epilogue, and the epilogue is a plain return. Every call
jitted code makes to other jitted code follows it with `checkException()`, so within jitted code the
unwind is complete and correct.

Nothing did that at the boundary back to native code. `runFunction` calls `compiled(ctx)` and returns
without ever looking at `ctx->exception`. The closure path does look, but only to decide not to read
a return value, and then answers `null()` with the exception still set.

Two things follow, and the second is the worse one:

1. The immediate caller reads `null` where it should have caught something.
2. `ctx->exception` is never cleared, so the next jitted function to run hits its first
   `checkException()` and returns at once. Every call after the first throw answers `null`, for the
   life of the process.

### Confirmed by building it

A script whose compiled body throws is the only way to reach this, and until a compiled body could
throw at all, nothing here ever did. Two conformance cases now do: reading a local declared
`var x(never, default)` and writing one declared `var x(default, never)`. Interpreted cppia raises
both correctly. Jitted cppia answered `null` for the case itself and then `null` for all 49 cases
after it, in case order, whichever case was placed first.

### The patch

At each of the three sites, raise it where the interpreter would have and clear it:

```cpp
if (ctx->exception)
{
   Dynamic caught = ctx->exception;
   ctx->exception = nullptr;
   HX_STACK_DO_THROW(caught);
}
```

This is the same shape `TryExpr::runVoid` already uses on the interpreted path, which ends its own
unwind with `if (ctx->exception) handleException(ctx, ctx->exception);`.

---

## 8. A `Bool` put in a `Map` from a script comes back an `Int`, and the cause is in Haxe's std

**`std/cpp/_std/haxe/ds/StringMap.hx`, the `#if (scriptable)` block, `setBool`. Not an hxcpp file.**

```haxe
var flag:Bool = true;
var m:Map<String, Bool> = new Map();
m.set('k', flag);
Type.typeof(m.get('k'));   // TInt, where every other target says TBool
```

`Std.string` of it prints `1`, and `false` prints `0`. A condition still reads correctly, because `1`
is truthy, which is what keeps this quiet. It happens interpreted and jitted alike, for a variable
and for a constant, for `Map<String,Bool>` and `Map<String,Dynamic>` and a bare
`haxe.ds.StringMap<Bool>`.

### Why

`StringMap` carries a set of specialised setters that exist only under `-D scriptable`, which is to
say only for cppia hosts. `setBool` is one of them, and it stores through the integer setter:

```haxe
#if (scriptable)
private function setBool(key:String, val:Bool):Void {
   untyped __string_hash_set_int(__cpp__("HX_MAP_THIS"), key, val);
}
```

A native build never sees these, uses `set`, and stores a value that keeps its type. A cppia host
dispatches to `setBool`, the boolean is stored as an integer, and `get` is typed `Null<T>` with `T`
erased, so nothing converts it back on the way out. Natively the typed `get` is what restores the
boolean, and cppia has no type left to do that with.

This is why pre-boxing avoids it. Handing `set` a value already typed `Dynamic` picks the generic
setter rather than `setBool`:

```haxe
var boxed:Dynamic = flag;
b.set('k', boxed);         // TBool
```

### What it is not

Every hxcpp boxing site reached for this was already correct, and three were ruled out by building
the change and measuring no difference: `MemReference::runObject` and `CppiaBoolExpr::runObject` both
ask `isBoolInt()`, `DataVal<bool>::runObject` holds a real `bool`, and teaching the `sigObject`
argument case at `Cppia.cpp:1779` to ask changes no answer. Nothing in hxcpp boxes a boolean wrongly.

### The fix

`setBool` should store the value the way `set` does, so it keeps its type rather than being flattened
to an integer no one can widen again. That belongs in a pull request against Haxe rather than hxcpp.

`IntMap` and `ObjectMap` want checking for the same shape, and an `Int` keyed map shows the same
symptom here.

### Still open, and separate from this

Three constructs are wrong only with the JIT on, are fine interpreted, and are not explained by the
above:

| construct | interpreted | jitted |
| --- | --- | --- |
| `Array<Dynamic>.push(true)` | `TBool` | `TInt` |
| a `Dynamic` instance field assigned `true` | `TBool` | `TInt` |
| a mixed `Array<Dynamic>` literal inside an anonymous object | `TBool` | `TInt` |

Measured against the same code compiled natively, which answers `TBool` everywhere.

---
