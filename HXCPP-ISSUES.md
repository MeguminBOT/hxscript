# hxcpp issues

Faults that live in hxcpp rather than in this library, found while making compiled scripts agree with
the interpreter. Everything here reproduces with hxcpp's own bytecode grammar and most of it affects
Haxe's own cppia output too, so none of it is about how this emitter writes things.

Paths are relative to the root of an hxcpp checkout. Which checkout a build actually links is
whatever `haxelib path hxcpp` reports, which is not always the one being read.

## Applying the fixes

```sh
python patches/apply-hxcpp.py            # apply, and say what was already there
python patches/apply-hxcpp.py --check    # report only, change nothing
python patches/apply-hxcpp.py --revert   # put the originals back
```

It finds hxcpp through `haxelib path hxcpp` unless given `--path`, and it is idempotent, so run it
again after every `haxelib upgrade`. Nothing is written unless every fix that is not already there
matched exactly: a half applied hxcpp is a state nobody has tested. `--revert` restores the files
byte for byte.

**hxcpp compiles its runtime into each project**, so anything built before applying keeps the old
behaviour until it is rebuilt. Delete the binary rather than trusting a rebuild to notice.

Issues 1, 2 and 3 are covered. The rest have no patch yet.

**Issue 1's fix is required, not optional.** This library declares a `Bool` field with its real type
by default, which is what makes a boolean read back as `true` in every mode including jitted. Against
a stock hxcpp that field gets an integer slot instead. `-D hxscript_cppia_bool_compat` is the way out
for a build that cannot patch: it emits no type and marks the value, which is right interpreted and
still wrong jitted, because the jitted store of a boolean into an object slot is a separate fault
that is not understood. So the choice is a patched hxcpp and agreement everywhere, or a stock one and
agreement only while interpreting.

| # | issue | status |
| --- | --- | --- |
| 1 | A member field declared `Bool` never gets `fsBool` storage | open, patch known |
| 2 | `DataVal<T>` does not report itself as a boolean to the JIT | patched locally, not upstream |
| 3 | `convert` moves registers without a width, and the JIT refuses | patched locally, committed on the fork |
| 4 | `CallMember` trusts a vtable slot it did not verify, and segfaults | open, no patch |
| 5 | `Type.getEnumConstructs` on a non-enum ends the process | open, avoided rather than fixed |
| 6 | An hxcpp binary writing to `NUL` on Windows ends there | open, avoided rather than fixed |

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

Mirror the static variant, then size from the storage rather than from `exprType`:

```cpp
   if (!isVirtual)
   {
      exprType = typeId==0 ? etObject : type->expressionType;
      AlignOffset(exprType, ioOffset);
      offset = ioOffset;

      storeType = typeId==0 ? fsObject : fieldStorageFromType(type);

      switch(storeType)
      {
         case fsBool: ioOffset += sizeof(int); break;
         case fsInt: ioOffset += sizeof(int); break;
         case fsFloat: ioOffset += sizeof(Float); break;
         case fsString: ioOffset += sizeof(String); break;
         case fsObject: ioOffset += sizeof(hx::Object *); break;
         default: break;
      }
   }
```

`sizeof(int)` for the boolean rather than `sizeof(bool)` keeps the layout and the `AlignOffset` call
exactly as they are, so a one-byte field simply leaves three bytes unused. Getting the size back is a
separate change and is not worth coupling to a correctness fix.

### Confirmed by building it

Patched, with the field declared `Bool` for real, every boolean reads back as `true` under the JIT
and interpreted alike, including one with no annotation whose type is inferred from its initialiser.
`test/cpp/BoolProbe.hx` is the reading, and the conformance table's `cppia-jit` column went to 0
differ with it.

### The way out for a stock hxcpp

`-D hxscript_cppia_bool_compat` emits a `Bool` field with **no declared type** and writes `CASTBOOL`
on the value. See `Config.nativeBoolSlots`, `Backend.isBool` and `Emitter.boolean`.

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

### The patch, applied locally

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

### The patch, applied locally and committed on the fork

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
