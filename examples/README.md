# Examples

Two, because the library gets used two different ways. The third thing you can do with it, running
somebody else's projects against a stack of game libraries, is an application rather than an
example, and lives in [`../apps/sandbox/`](../apps/sandbox).

| | |
| --- | --- |
| [`battle/`](battle) | **Scripts as content.** A turn-based RPG whose creatures, bosses and status effects are all loaded at runtime, extending compiled classes. The host owns the rules and knows nothing about what fights in them. |
| [`workbench/`](workbench) | **Scripts as the whole program.** A coding environment: write any number of scripts, then list, test, run or watch them with no rebuild. The shipped one is a playable falling-block game, written entirely in scripts. |

Both run from the repository root with nothing but the compiler.

```
haxe -cp src -cp examples/battle -main Main \
     --macro include('bridges') --macro macros.BridgeMacro.generate() --interp
```

```
haxe -cp src -cp examples/workbench --macro include('bridges') --run Workbench list
haxe -cp src -cp examples/workbench --macro include('bridges') --run Workbench run BlockDrop
```

`battle/` also builds as a Lime/OpenFL application (`cd examples/battle && lime test windows`), which
is the shape a real project takes; its `Project.xml` shows the same wiring as build declarations
rather than compiler flags.

Read `battle/game/Mods.hx` first if you are adding scripting to a game that exists, and
`workbench/README.md` first if you want to write the program itself in script. If the thing in your
way is a game library your scripts cannot see yet, read
[`../apps/sandbox/README.md`](../apps/sandbox/README.md) instead, along with the library's own
[advanced.md §4](../docs/advanced.md#4-adding-a-game-library).
