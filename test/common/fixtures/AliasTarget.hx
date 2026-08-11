/**
 * A host class reached from scripts through `AliasFixture`, the way flixel's `FlxSpriteGroup`
 * reaches `FlxTypedSpriteGroup<FlxSprite>`.
 */
class AliasTarget {
	public var n:Int = 7;

	public function new() {}
}

typedef AliasFixture = AliasTarget;

typedef AliasTwice = AliasFixture;
