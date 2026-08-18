# HashLink's loader, carried here

`code.c`, `module.c` and `jit.c` are hashlink's own. They read a `.hl` module, link it against the
running process and compile its functions to machine code, and they are the reason a script can be
compiled while a game is running rather than only while it is being built.

They are here because of where hashlink puts them. Its `Makefile` builds libhl out of `gc.c` and
`std/*.c`, and puts these three in `hl.exe` instead:

```
LIB    = ${PCRE} ${RUNTIME} ${STD}
HL_OBJ = src/code.o src/jit.o src/main.o src/module.o src/debugger.o src/profile.o
```

So a process linked against libhl, which is every HashLink program including every HL/C binary, has
a garbage collector and a standard library and no way to load anything. Carrying the three files is
what closes that, and it closes it the same way in both places: on the VM they go into
`hxscript.hdll` beside the VM's own copies, and in an HL/C build they are compiled straight in.

Everything they call, they call in libhl. Nothing here allocates and `gc.c` is deliberately not
carried, so a module loaded through this shares the host's heap and its collector rather than
getting a second one that the first cannot see.

## What is here

From **hashlink 1.16.0** (`HL_VERSION 0x011000`), the sources at the 1.16 tag:

| file | what it is |
| --- | --- |
| `hl116/code.c` | reads the bytecode container into an `hl_code` |
| `hl116/module.c` | links a read module: globals, natives, constants, types |
| `hl116/jit.c` | compiles its functions to x86 and x86-64 machine code |
| `hl116/hlmodule.h`, `hl116/opcodes.h`, `hl116/hlsystem.h` | the headers those three need and that the binary distributions do not ship |
| `LICENSE.hashlink` | hashlink's licence, which is MIT |

`hl.h` is **not** carried. It has to be the one the running libhl was built from, so it comes from
the HashLink installation the host is already building against, and the version those two agree on
is checked at build time and probed again at run time.

A different HashLink can be built against instead by pointing `HL_SRC` at its source tree, which
takes its `code.c`, `module.c` and `jit.c` over the ones here.

## The three patches

All three are in `module.c`, each marked `HXS_NATIVE_TABLE` where it sits.

**`hl_module_init_natives`.** Hashlink resolves a module's natives by loading `<lib>.hdll` and looking
up `hlp_<name>` in it. A script compiled at runtime needs to reach hxScript's own runtime, which is
already in this process and is in no `.hdll` at all, and in an HL/C build there is no `.hdll` anywhere
to look in. The patch gives that lookup a table to try first and leaves every other native to
hashlink's own path.

**`hl_gc_set_dump_types`, at the end of `hl_module_init`.** Everything else that function takes is a
field of `hl_setup`, which `hxs.c` copies before the load and puts back afterwards. This one is a
setter with no getter, so taking it cannot be undone, and a host's memory dump would name the types
of modules loaded at run time instead of its own from the first script onwards. The call is left out
instead. `gc.c` checks the callback for NULL before using it, so a host that never set one is
unaffected either way.

**`hl_jit_code`'s answer, in the middle of `hl_module_init`.** A jit that could not get memory to put
code in says so by returning NULL, and the loop underneath turns that into pointers just past address
zero, so the first call into the module jumps into nothing. It is reachable wherever a system declines
to hand out executable pages: an SELinux policy without `execmem`, a hardened kernel, or no memory
left. Failing the link instead makes it a module hxScript interprets, which is what every other reason
for not compiling already does. Checked both ways: with the guard the corpus reports every module
rejected and still answers correctly, and without it the same build segfaults.

Nothing else is modified. The symbols are renamed at compile time by `hxs_vendor.h` rather than in
the files, so `diff` against a fresh checkout of the 1.16 tag shows those three hunks and nothing else.

## Updating

1. Copy the four files out of the new tag into a new `hlNNN/` directory.
2. Re-apply all three `HXS_NATIVE_TABLE` hunks.
3. Check `nm -g --defined-only` on the three objects against the list in `hxs_vendor.h`, and add
   whatever the new version defines.
4. Leave the old directory alone until the build's floor moves off it.
