package hxscript.error;

/**
 * Which part of the pipeline produced a [`Diagnostic`](Diagnostic.hx).
 */
enum Phase {
	/** The lexer or parser, before anything ran. */
	PParse;

	/** Building a scripted type: its super-class, interfaces, fields. */
	PType;

	/** Interpreting. The only phase whose diagnostics are caused by what a script did, not by how it was built. */
	PRun;

	/** The runtime compiler declining to emit a module, which leaves it interpreted. */
	PEmit;

	/** The bytecode loader declining to accept what was emitted. */
	PLoad;

	/** The bytecode loader accepting a module only with the JIT turned off. */
	PJit;

	/** The setup steps: a library not in the build, a base that could not be bridged. */
	PSetup;
}
