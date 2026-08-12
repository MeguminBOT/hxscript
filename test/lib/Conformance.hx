/**
 * How a runner is handed one conformance case.
 *
 * @param label How to name it in the report.
 * @param body The method body to run.
 * @param want What it should produce, or null when nobody has decided yet.
 * @param extra Extra members of the class the body sits in.
 * @param before Declarations preceding that class.
 */
typedef Ask = (label:String, body:String, want:Null<String>, ?extra:String, ?before:String) -> Void;

/**
 * Every case every mode is asked, in one order, so the answers can be read as a table.
 *
 * There were two lists and they answered different questions. `Corpus` is what a backend is meant to
 * pass, so it is green by construction and says nothing about the edges; `Frontier` is the edges,
 * with no expected value written down because a case whose answer nobody knows cannot have one. Both
 * are still the source of truth for their own cases: this adds no cases of its own and holds no
 * copies, it puts them in one sequence so that case 137 means the same thing in six columns.
 *
 * `want` is the difference between them and it is deliberately kept. A case with one is an
 * assertion, and a mode that misses it has a bug. A case without one is a reading, and what decides
 * it is the interpreter: every mode has to agree with what the interpreter said, whatever that was.
 * The second is the weaker claim and it is the one this whole exercise is about, because a script
 * getting a different answer per mode is wrong even when no list says which answer was right.
 */
class Conformance {
	/**
	 * Offers every case to a runner, asserted ones first.
	 *
	 * The order is fixed and is part of the interface: a runner reports by index so that a row can be
	 * found again, and the driver resumes at an index after a case takes the process with it.
	 *
	 * @param ask What to do with one.
	 */
	public static function run(ask:Ask):Void {
		Corpus.run(function(label:String, body:String, want:String, ?extra:String, ?before:String):Void {
			ask(label, body, want, extra, before);
		});

		Frontier.run(function(label:String, body:String, ?extra:String, ?before:String):Void {
			ask(label, body, null, extra, before);
		});
	}

	/**
	 * Builds the source one case runs as.
	 *
	 * **The package is per case, and that is not cosmetic.** Loading compiled bytecode registers its
	 * classes by name for the life of the process, so two hundred cases all declaring `p.T` are two
	 * hundred registrations of one name, and which one a later case reaches is not something this can
	 * control. Giving each its own package makes every case independent of the ones before it, which
	 * is what makes a row a reading about its own construct.
	 *
	 * @param index The case's index, which is what makes its package unique.
	 * @param body The method body.
	 * @param extra Extra members of the class the body sits in.
	 * @param before Declarations preceding that class.
	 * @return The whole module source.
	 */
	public static function source(index:Int, body:String, ?extra:String, ?before:String):String {
		return 'package ' + pack(index) + ';\n'
			+ (before == null ? '' : before) + '\n'
			+ 'class T {\n'
			+ (extra == null ? '' : extra) + '\n'
			+ '\tpublic static function run():Dynamic {\n\t\t' + body + '\n\t}\n'
			+ '}\n';
	}

	/** @return The package a case's module declares. */
	public static inline function pack(index:Int):String {
		return 'c' + index;
	}

	/** @return The path a case's entry class is resolved by. */
	public static inline function path(index:Int):String {
		return pack(index) + '.T';
	}
}
