# Example: a scriptable battle

A small turn-based RPG with the library embedded in it. The host owns the rules; everything that
fights in them is loaded from `scripts/` at runtime.

```
haxe -cp src -cp examples/battle -main Main \
  --macro include('bridges') --macro macros.BridgeMacro.generate() \
  --macro macros.AbstractsMacro.generate() --macro include('game') --interp
```

or compiled:

```
haxe -cp src -cp examples/battle -main Main \
  --macro include('bridges') --macro macros.BridgeMacro.generate() \
  --macro macros.AbstractsMacro.generate() --macro include('game') -cpp bin && ./bin/Main.exe
```

or as a Lime/OpenFL application, which is the shape a game actually builds in. The same battle, with
the log drawn into a window:

```
cd examples/battle && lime test windows
```

`Project.xml` is the point of that third one: it shows the wiring in the form a real project uses,
rather than as compiler flags. Everything a host has to declare is on one page: the haxelib, the
two macro flags that keep the scripting bridges in the build, and the scripts shipped as assets so
they land next to the executable. It needs `lime` and `openfl` installed; the console forms need
nothing but the compiler.

## What is where

| | |
| --- | --- |
| `Main.hx` | the app: builds a battle and runs it |
| `game/Entity.hx` | a combatant. Health, damage, death, and a default "attack someone" turn |
| `game/Component.hx` | a behaviour attached to an entity: poison, thorns, whatever a script invents |
| `game/Battle.hx` | turn order, targeting, the log, a seeded RNG so runs are reproducible |
| `game/Mods.hx` | **the embedding layer**: the entire integration, four steps and a discovery helper |
| `bridges/` | the manual form of a scripting bridge: one empty class, hand-written, for `Entity` |
| `macros/BridgeMacro.hx` | the generated form of the same thing, used here for `Component` |
| `game/Damage.hx` | a **native abstract**, with no `@:build` on it |
| `macros/AbstractsMacro.hx` | applies hxscript's wrapper macro to it **from outside**, the way you cover a library you do not own |
| `game/ModInterp.hx` | a **custom interpreter**, so scripts name the running battle's members bare |
| `Project.xml` | the Lime/OpenFL build, showing the same wiring as a game project declares it |
| `scripts/` | the content: two party members, four enemies, two components, and a module of shared types |

`game/Mods.hx` is the file to read first. It is short, and it is the whole job.

## What the scripts show

- **`Slime`** splits into two of itself the first time it is hurt, and puts the halves into the
  battle. A script changing the shape of the fight, with the host knowing nothing about slimes.
- **`Bandit`** replaces the default turn with a real decision: finish a target it can kill this
  turn, otherwise hit the healthiest. It is also the host-extension file: `log(...)` and `round`
  are the battle's members named bare (the custom interpreter), and `Damage` is a native abstract
  with working operators and methods (the abstract macro). Drop either macro from the build and
  this script is what fails.
- **`HiveQueen`** is the boss. It attaches a component to itself in its constructor, alternates
  attacks on a timer, summons plain native entities, and changes behaviour when its own health drops.
- **`Cleric`** and **`Rogue`** are party members, because scripts are not only for enemies. The
  rogue applies the same `Poison` component the boss uses, which is the point of components: they
  belong to neither side.
- **`Poison`** and **`Thorns`** are pure behaviour, attachable to anything.
- **`Combat.hx`** is one module holding several types, the way a Haxe module does: an `enum` with
  parameters, a structural `typedef` with an optional field, an `interface`, and an `abstract` over
  `Int` with its own operator.
- **`Elementalist`** is where those meet: it switches on the enum with its parameters bound and a
  guard, does arithmetic with the abstract, implements the interface, and returns the typedef with
  its optional field left out. Note the `import Combat;` at the top: types from another module need
  importing, exactly as in Haxe.

## Two ways to make a class scriptable

A script can only extend a class that has a **bridge**, and there are two ways to get one. The
example uses both at once so they can be compared:

- `bridges/ScriptedEntity.hx` is written by hand. It is three lines, and for one or two bases that
  is the clearest thing to do.
- `macros/BridgeMacro.hx` generates the identical class from a list, and bridges `Component` that
  way. Past a handful of bases this is the one to use: a bridge is boilerplate, and the generated
  `Bridges.all` array is also what keeps them from being eliminated, which the manual form needs
  `--macro include('bridges')` for.

Pick one in a real project. Adding a scriptable base is then either a new file or a new line.

## The thing worth noticing

The host never names a script. `Main` asks for `Mods.roster('party')` and `Mods.roster('enemy')`,
and `Mods` asks the loaded world which classes descend from `Entity` and which side each one put
itself on.

So this is a complete mod:

```haxe
// scripts/Warhound.hx
class Warhound extends Entity {
	public static var side:String = 'enemy';

	public function new() {
		super('warhound', 26, 5);
	}

	override public function takeTurn(battle:Battle) {
		for (i in 0...2) {
			if (!alive || battle.over)
				return;
			super.takeTurn(battle);
		}
	}
}
```

Drop that in `scripts/`, run again, and there is a warhound in the fight. No host code changes, no
registration list, no rebuild of the app.

## Reading the output

The battle is seeded, so it plays out the same every time and a change to a script shows up as a
change in the log. Edit a script, run again, and diff.

---

For how the embedding works step by step, see [`../../docs/embedding.md`](../../docs/embedding.md).
