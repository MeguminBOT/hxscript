/**
	Drives the seven functions module.c reaches a jit through, and calls what they produce.

	Not through hl_module_init, deliberately. That would test linking a module as well as compiling
	one, and linking is the next thing rather than this one: what has to be true first is that a
	function built out of opcodes becomes machine code with a frame the processor agrees with, and
	that an argument handed to it in a register arrives where the function looks for it.

	So the hl_function here is built by hand, with only the fields the jit reads filled in. That is
	the same shape hl_code_read would have produced, arrived at without needing a module to read.
*/
#include <hl.h>
#include <hlmodule.h>

#include <stdio.h>
#include <string.h>

static int fail;

static hl_code code;
static hl_module m;
static int ints[2];

/**
	Compiles one function and hands back somewhere to call.

	@param sig Its signature.
	@param regs What its registers hold.
	@param nregs How many.
	@param ops Its instructions.
	@param nops How many.
	@return The compiled function, or NULL when the jit refused it.
*/
static void *build( hl_type *sig, hl_type **regs, int nregs, hl_opcode *ops, int nops ) {
	hl_function f;
	jit_ctx *ctx;
	hl_debug_infos *debug = NULL;
	void *base;
	int at, size = 0;

	memset(&f, 0, sizeof(f));
	f.findex = 0;
	f.nregs = nregs;
	f.nops = nops;
	f.type = sig;
	f.regs = regs;
	f.ops = ops;

	ctx = hl_jit_alloc();
	if( ctx == NULL )
		return NULL;

	hl_jit_init(ctx, &m);

	at = hl_jit_function(ctx, &m, &f);
	if( at < 0 )
		return NULL;

	base = hl_jit_code(ctx, &m, &size, &debug, NULL);
	if( base == NULL )
		return NULL;

	return (void *)((unsigned char *)base + at);
}

static void report( const char *what, long long got, long long want ) {
	if( got == want ) {
		printf("  %-42s %lld\n", what, got);
	} else {
		printf("  %-42s %lld, expected %lld\n", what, got, want);
		fail++;
	}
}

static void report_d( const char *what, double got, double want ) {
	if( got == want ) {
		printf("  %-42s %g\n", what, got);
	} else {
		printf("  %-42s %g, expected %g\n", what, got, want);
		fail++;
	}
}

/** Builds a signature. The jit reads nargs, args and ret and nothing else of it. */
static void signature( hl_type *out, hl_type_fun *fun, hl_type **args, int nargs, hl_type *ret ) {
	memset(fun, 0, sizeof(*fun));
	fun->args = args;
	fun->nargs = nargs;
	fun->ret = ret;

	memset(out, 0, sizeof(*out));
	out->kind = HFUN;
	out->fun = fun;
}

int main( void ) {
	hl_global_init();

	memset(&code, 0, sizeof(code));
	memset(&m, 0, sizeof(m));

	ints[0] = 42;
	ints[1] = -7;
	code.ints = ints;
	code.nints = 2;
	code.nfunctions = 1;
	code.hasdebug = 0;
	m.code = &code;

	printf("-- functions the jit built, called --\n");

	{
		/** OInt then ORet, which is the smallest function that can be compiled at all. */
		hl_type sig;
		hl_type_fun fun;
		hl_type *regs[1];
		hl_opcode ops[2];
		int (*f)( void );

		signature(&sig, &fun, NULL, 0, &hlt_i32);
		regs[0] = &hlt_i32;

		memset(ops, 0, sizeof(ops));
		ops[0].op = OInt;  ops[0].p1 = 0; ops[0].p2 = 0;
		ops[1].op = ORet;  ops[1].p1 = 0;

		f = (int (*)( void ))build(&sig, regs, 1, ops, 2);
		report("a constant returned", f == NULL ? -1 : f(), 42);
	}

	{
		/** A negative constant, which takes the other half of the immediate cases. */
		hl_type sig;
		hl_type_fun fun;
		hl_type *regs[1];
		hl_opcode ops[2];
		int (*f)( void );

		signature(&sig, &fun, NULL, 0, &hlt_i32);
		regs[0] = &hlt_i32;

		memset(ops, 0, sizeof(ops));
		ops[0].op = OInt;  ops[0].p1 = 0; ops[0].p2 = 1;
		ops[1].op = ORet;  ops[1].p1 = 0;

		f = (int (*)( void ))build(&sig, regs, 1, ops, 2);
		report("a negative constant returned", f == NULL ? -1 : f(), -7);
	}

	{
		/** An argument, which the prologue has to put into the frame before anything reads it. */
		hl_type sig;
		hl_type_fun fun;
		hl_type *args[1];
		hl_type *regs[1];
		hl_opcode ops[1];
		int (*f)( int );

		args[0] = &hlt_i32;
		signature(&sig, &fun, args, 1, &hlt_i32);
		regs[0] = &hlt_i32;

		memset(ops, 0, sizeof(ops));
		ops[0].op = ORet;  ops[0].p1 = 0;

		f = (int (*)( int ))build(&sig, regs, 1, ops, 1);
		report("an argument returned", f == NULL ? -1 : f(42), 42);
	}

	{
		/** The third argument, so the prologue is counting registers rather than assuming one. */
		hl_type sig;
		hl_type_fun fun;
		hl_type *args[3];
		hl_type *regs[3];
		hl_opcode ops[1];
		int (*f)( int, int, int );

		args[0] = args[1] = args[2] = &hlt_i32;
		signature(&sig, &fun, args, 3, &hlt_i32);
		regs[0] = regs[1] = regs[2] = &hlt_i32;

		memset(ops, 0, sizeof(ops));
		ops[0].op = ORet;  ops[0].p1 = 2;

		f = (int (*)( int, int, int ))build(&sig, regs, 3, ops, 1);
		report("the third argument returned", f == NULL ? -1 : f(1, 2, 42), 42);
	}

	{
		/**
			A double, which arrives in the other bank and is counted separately from the integers.

			An argument list that mixes them is the case that catches a prologue counting one
			sequence where the ABI keeps two.
		*/
		hl_type sig;
		hl_type_fun fun;
		hl_type *args[3];
		hl_type *regs[3];
		hl_opcode ops[1];
		double (*f)( int, double, int );

		args[0] = &hlt_i32;
		args[1] = &hlt_f64;
		args[2] = &hlt_i32;
		signature(&sig, &fun, args, 3, &hlt_f64);
		regs[0] = &hlt_i32;
		regs[1] = &hlt_f64;
		regs[2] = &hlt_i32;

		memset(ops, 0, sizeof(ops));
		ops[0].op = ORet;  ops[0].p1 = 1;

		f = (double (*)( int, double, int ))build(&sig, regs, 3, ops, 1);
		report_d("a double between two integers", f == NULL ? -1 : f(1, 42.5, 3), 42.5);
	}

	{
		/** An opcode this jit does not know, which has to be refused rather than guessed at. */
		hl_type sig;
		hl_type_fun fun;
		hl_type *regs[1];
		hl_opcode ops[2];
		void *f;

		signature(&sig, &fun, NULL, 0, &hlt_i32);
		regs[0] = &hlt_i32;

		memset(ops, 0, sizeof(ops));
		ops[0].op = OAdd;  ops[0].p1 = 0; ops[0].p2 = 0; ops[0].p3 = 0;
		ops[1].op = ORet;  ops[1].p1 = 0;

		f = build(&sig, regs, 1, ops, 2);
		report("an unknown opcode is refused", f == NULL ? 1 : 0, 1);
	}

	printf("\n");
	if( fail == 0 ) {
		printf("== every function the jit built ran correctly ==\n");
		return 0;
	}

	printf("== %d failed ==\n", fail);
	return 1;
}
