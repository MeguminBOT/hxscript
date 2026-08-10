# Example: a scripting workbench

A coding environment built on the library. Write as many scripts as you like under `scripts/`, then
list, test, run or watch them, without rebuilding the host once.

The point is how far that goes: **the game in `scripts/` is not partly scripted, it is entirely
scripted.** The host owns a character screen, a keyboard, a clock and this shell. The well, the
pieces, the rotation and kicks, the seven-bag randomiser, the scoring curve and every character of
the layout are `.hx` files read at runtime.

## Running it

From the repository root:

```
haxe -cp src -cp examples/workbench --macro include('bridges') --run Workbench list
haxe -cp src -cp examples/workbench --macro include('bridges') --run Workbench test
haxe -cp src -cp examples/workbench --macro include('bridges') --run Workbench run BlockDrop
haxe -cp src -cp examples/workbench --macro include('bridges') --run Workbench watch BlockDrop
```

`--run` rather than `-main ... --interp`, because only `--run` passes arguments through to the
program.

| command | what it does |
| --- | --- |
| `list` | every class the scripts declare, marked with what can be done with it |
| `test` | runs every scripted `static function test()` and reports pass/fail |
| `run <Name>` | plays a scripted `App` |
| `watch <Name>` | plays it again from the top whenever any script changes |

`list` on the shipped scripts:

```
  [run] BlockDrop  BlockDrop: arrows move, up rotates, space drops, q quits  46x22
        Bag
        Board
        Scoring
        Shapes
 [test] BoardTest
```

## What is where

| | |
| --- | --- |
| `Workbench.hx` | the shell: discovery, `list`, `test`, `run`, `watch` |
| `host/App.hx` | the base a scripted program extends; the entire lifecycle the host imposes |
| `host/Screen.hx` | a character grid: `put`, `text`, `frame`, `present` |
| `host/Keys.hx` | key codes, and the terminal decoding that produces them |
| `bridges/ScriptedApp.hx` | one empty class, which is what lets a script write `extends App` |
| `scripts/BlockDrop.hx` | the game |
| `scripts/blocks/` | its parts: `Board`, `Piece` shapes, `Bag`, `Scoring` |
| `scripts/tests/BoardTest.hx` | a test, written as a script like everything else |

## How the environment works

**A file's path becomes its package.** `scripts/blocks/Board.hx` loads as `blocks.Board` and is
imported as `import blocks.Board;`, which is the same arrangement a Haxe classpath gives you, so scripts
organise into packages instead of one flat folder.

**The host surface is deliberately tiny.** `App` declares six methods and four fields. A bridge
generates one override per inherited method, so a wide base is expensive; and anything the host
declares is something the script cannot change without a rebuild. Both push the same way: give
scripts a small surface and let them build upward.

**Reloading rebuilds the world.** Each load constructs a fresh `Environment`. Reusing one and
re-adding modules leaves the previous definitions reachable.

**Errors print with their stack.** The module hooks use `e.details()`, not `e.message`. A prototype
is broken half the time by definition, and the message alone rarely locates anything.

## Writing your own program

Declare a class extending `App` anywhere under `scripts/`:

```haxe
class Hello extends App {
    public function new() {
        super();
        title = 'hello';
        width = 30;
        height = 8;
    }

    override public function key(k:Int):Void {
        if (k == Keys.of('q')) done = true;
    }

    override public function draw(screen:Screen):Void {
        screen.frame(0, 0, 30, 8);
        screen.text(2, 3, 'press q to quit');
    }
}
```

`list` picks it up immediately; `run Hello` plays it. No rebuild, because nothing about the host
changed.

## Writing a test

Any scripted class with a `static function test()` is collected by `test`. Return an empty string
when it passes, or a description of the first failure:

```haxe
class BoardTest {
    public static function test():String {
        var board = new Board(10, 18);
        if (!board.collides(1, 0, -5, 0))
            return 'a piece off the left wall should collide';
        return '';
    }
}
```

Returning `true` also counts as a pass, for tests that have nothing to say.

Tests reload with the code they cover, so a rule can be changed and re-checked without a build. That
is the part worth stealing even if you never ship a scripted game: the edit-check loop stops being
bounded by compile time.

## The trade this example makes

The game steps **once per keypress**. A terminal has no portable non-blocking key poll, so a real
frame loop would need a platform-specific input layer, which is host work and beside the point here.
Gravity is still real time, so holding a key drops you faster than thinking about it does.

If you build this on a real display library instead of a terminal, that constraint disappears and
nothing else in the arrangement changes. The host grows a render surface and a frame loop, and the
scripts stay exactly as they are.

## Where to go next

- [`../battle/`](../battle) is the other shape: scripts as content inside a game that already exists.
- [`../../docs/embedding.md`](../../docs/embedding.md) explains what each step of the host is doing.
- [`../../docs/advanced.md`](../../docs/advanced.md) covers generating bridges instead of writing them,
  and wiring in a real game library.
