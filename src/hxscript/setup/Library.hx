package hxscript.setup;

/**
 * Everything one library needs before a script can use it, as data.
 */
typedef Library = {
	/**
	 * The compiler define that turns this library on.
	 *
	 * Adding `-lib flixel` to a build defines `flixel`, so a library switches itself on by being
	 * present and no flag of its own is needed. Haxelib defines both spellings of a hyphenated name,
	 * and this is matched as a string, so either works.
	 */
	var define:String;

	/** What to call it in the setup report. */
	var title:String;

	/**
	 * Package roots force-compiled into the build, recursively.
	 */
	var roots:Array<String>;

	/**
	 * Modules under some root that cannot be compiled as ordinary runtime code, and would fail the build.
	 * Macro-only classes, integrations for libraries this project does not ship, and deprecation stubs.
	 */
	var ignore:Array<String>;

	/**
	 * Individual modules force-compiled by **referencing** them instead of including their package.
	 */
	var types:Array<String>;

	/**
	 * Classes scripts may extend, fully qualified.
	 *
	 * Costs one generated override per inherited non-`inline`, non-`final` method, so this is the
	 * list that decides how large the binary gets. Keep it to what scripts actually subclass.
	 */
	var bases:Array<String>;

	/** Packages scanned for abstracts to wrap. Worth it for a library sized like flixel, not for one sized like openfl. */
	var abstractPackages:Array<String>;

	/** Abstracts wrapped by name, for libraries with too many to scan. */
	var abstracts:Array<String>;

	/** Abstracts under `abstractPackages` the wrapper cannot generate for. */
	var abstractExclude:Array<String>;

	/** Types scripts may name without importing them. Everything else stays reachable by explicit `import`. */
	var globals:Array<String>;
}
