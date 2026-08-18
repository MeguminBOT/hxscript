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
static int ints[9];
static double floats[4];

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
	ints[2] = 0;
	ints[3] = 1;
	ints[4] = 7;
	ints[5] = 2;
	ints[6] = (-2147483647 - 1);
	ints[7] = -1;
	ints[8] = 10;
	code.ints = ints;
	code.nints = 9;

	floats[0] = 40.5;
	floats[1] = 1.5;
	floats[2] = 7.0;
	floats[3] = 2.0;
	code.floats = floats;
	code.nfloats = 4;
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
		/**
			A loop, which is where a jit earns its keep and where every piece so far has to be right
			at once: a backward jump, a forward jump, arithmetic into a register that outlives the
			iteration, and a comparison that is control flow rather than a value.

			  s = 0; i = 1; while( i <= n ) { s += i; i++; } return s;
		*/
		hl_type sig;
		hl_type_fun fun;
		hl_type *args[1];
		hl_type *regs[3];
		hl_opcode ops[7];
		int (*f)( int );

		args[0] = &hlt_i32;
		signature(&sig, &fun, args, 1, &hlt_i32);
		regs[0] = regs[1] = regs[2] = &hlt_i32;

		memset(ops, 0, sizeof(ops));
		ops[0].op = OInt;     ops[0].p1 = 1; ops[0].p2 = 2;
		ops[1].op = OInt;     ops[1].p1 = 2; ops[1].p2 = 3;
		ops[2].op = OJSGt;    ops[2].p1 = 2; ops[2].p2 = 0; ops[2].p3 = 3;
		ops[3].op = OAdd;     ops[3].p1 = 1; ops[3].p2 = 1; ops[3].p3 = 2;
		ops[4].op = OIncr;    ops[4].p1 = 2;
		ops[5].op = OJAlways; ops[5].p1 = -4;
		ops[6].op = ORet;     ops[6].p1 = 1;

		f = (int (*)( int ))build(&sig, regs, 3, ops, 7);
		report("one to ten, summed in a loop", f == NULL ? -1 : f(10), 55);
		report("the same loop with nothing to do", f == NULL ? -1 : f(0), 0);
	}

	{
		/**
			Division and remainder, including what HashLink says they answer when they cannot.

			A divide by zero is 0 and a remainder by zero is 0, which AArch64 gives for the first and
			has to be told about for the second. INT_MIN over -1 overflows on some architectures and
			traps on others; here it wraps, which is what hashlink's own jit arrives at by
			multiplying instead of dividing.
		*/
		hl_type sig;
		hl_type_fun fun;
		hl_type *args[2];
		hl_type *regs[3];
		hl_opcode ops[2];
		int (*divide)( int, int );
		int (*modulo)( int, int );

		args[0] = args[1] = &hlt_i32;
		signature(&sig, &fun, args, 2, &hlt_i32);
		regs[0] = regs[1] = regs[2] = &hlt_i32;

		memset(ops, 0, sizeof(ops));
		ops[0].op = OSDiv; ops[0].p1 = 2; ops[0].p2 = 0; ops[0].p3 = 1;
		ops[1].op = ORet;  ops[1].p1 = 2;
		divide = (int (*)( int, int ))build(&sig, regs, 3, ops, 2);

		memset(ops, 0, sizeof(ops));
		ops[0].op = OSMod; ops[0].p1 = 2; ops[0].p2 = 0; ops[0].p3 = 1;
		ops[1].op = ORet;  ops[1].p1 = 2;
		modulo = (int (*)( int, int ))build(&sig, regs, 3, ops, 2);

		report("7 divided by 2", divide == NULL ? -1 : divide(7, 2), 3);
		report("7 divided by 0", divide == NULL ? -1 : divide(7, 0), 0);
		report("the smallest int over -1", divide == NULL ? -1 : divide(-2147483647 - 1, -1), -2147483647 - 1);
		report("7 remainder 2", modulo == NULL ? -1 : modulo(7, 2), 1);
		report("7 remainder 0", modulo == NULL ? -1 : modulo(7, 0), 0);
		report("7 remainder -1", modulo == NULL ? -1 : modulo(7, -1), 0);
	}

	{
		/** The rest of the arithmetic, each one instruction, checked together. */
		hl_type sig;
		hl_type_fun fun;
		hl_type *args[2];
		hl_type *regs[3];
		hl_opcode ops[2];
		int i;

		struct { int op; const char *what; int a; int b; int want; } cases[] = {
			{ OAdd,  "40 plus 2",            40,  2,  42 },
			{ OSub,  "44 minus 2",           44,  2,  42 },
			{ OMul,  "6 times 7",             6,  7,  42 },
			{ OAnd,  "58 and 46",            58, 46,  42 },
			{ OOr,   "34 or 10",             34, 10,  42 },
			{ OXor,  "40 xor 2",             40,  2,  42 },
			{ OShl,  "21 shifted up one",    21,  1,  42 },
			{ OSShr, "-84 shifted down one",-84,  1, -42 },
			{ OUShr, "84 shifted down one",  84,  1,  42 }
		};

		args[0] = args[1] = &hlt_i32;
		signature(&sig, &fun, args, 2, &hlt_i32);
		regs[0] = regs[1] = regs[2] = &hlt_i32;

		for(i=0;i<(int)(sizeof(cases)/sizeof(cases[0]));i++) {
			int (*f)( int, int );

			memset(ops, 0, sizeof(ops));
			ops[0].op = cases[i].op; ops[0].p1 = 2; ops[0].p2 = 0; ops[0].p3 = 1;
			ops[1].op = ORet;        ops[1].p1 = 2;

			f = (int (*)( int, int ))build(&sig, regs, 3, ops, 2);
			report(cases[i].what, f == NULL ? -1 : f(cases[i].a, cases[i].b), cases[i].want);
		}
	}

	{
		/** Floating point, including the remainder, which is a call to fmod on every architecture. */
		hl_type sig;
		hl_type_fun fun;
		hl_type *args[2];
		hl_type *regs[3];
		hl_opcode ops[2];
		int i;

		struct { int op; const char *what; double a; double b; double want; } cases[] = {
			{ OAdd,  "40.5 plus 1.5",      40.5, 1.5, 42.0 },
			{ OSub,  "43.5 minus 1.5",     43.5, 1.5, 42.0 },
			{ OMul,  "21.0 times 2.0",     21.0, 2.0, 42.0 },
			{ OSDiv, "84.0 over 2.0",      84.0, 2.0, 42.0 },
			{ OSMod, "85.5 remainder 43.5",85.5,43.5, 42.0 }
		};

		args[0] = args[1] = &hlt_f64;
		signature(&sig, &fun, args, 2, &hlt_f64);
		regs[0] = regs[1] = regs[2] = &hlt_f64;

		for(i=0;i<(int)(sizeof(cases)/sizeof(cases[0]));i++) {
			double (*f)( double, double );

			memset(ops, 0, sizeof(ops));
			ops[0].op = cases[i].op; ops[0].p1 = 2; ops[0].p2 = 0; ops[0].p3 = 1;
			ops[1].op = ORet;        ops[1].p1 = 2;

			f = (double (*)( double, double ))build(&sig, regs, 3, ops, 2);
			report_d(cases[i].what, f == NULL ? -1 : f(cases[i].a, cases[i].b), cases[i].want);
		}
	}

	{
		/** A float constant, which is built through the general bank rather than loaded from a pool. */
		hl_type sig;
		hl_type_fun fun;
		hl_type *regs[1];
		hl_opcode ops[2];
		double (*f)( void );

		signature(&sig, &fun, NULL, 0, &hlt_f64);
		regs[0] = &hlt_f64;

		memset(ops, 0, sizeof(ops));
		ops[0].op = OFloat; ops[0].p1 = 0; ops[0].p2 = 0;
		ops[1].op = ORet;   ops[1].p1 = 0;

		f = (double (*)( void ))build(&sig, regs, 1, ops, 2);
		report_d("a float constant returned", f == NULL ? -1 : f(), 40.5);
	}

	{
		/** Every comparison, as the branch each one becomes. */
		hl_type sig;
		hl_type_fun fun;
		hl_type *args[2];
		hl_type *regs[3];
		hl_opcode ops[5];
		int i;

		struct { int op; const char *what; int a; int b; int want; } cases[] = {
			{ OJSLt,   "1 is less than 2",         1, 2, 1 },
			{ OJSLt,   "2 is not less than 1",     2, 1, 0 },
			{ OJSGte,  "2 is at least 2",          2, 2, 1 },
			{ OJSGt,   "3 is more than 2",         3, 2, 1 },
			{ OJSLte,  "2 is at most 2",           2, 2, 1 },
			{ OJEq,    "2 equals 2",               2, 2, 1 },
			{ OJNotEq, "2 does not equal 3",       2, 3, 1 },
			{ OJNotEq, "2 does equal 2",           2, 2, 0 }
		};

		args[0] = args[1] = &hlt_i32;
		signature(&sig, &fun, args, 2, &hlt_i32);
		regs[0] = regs[1] = regs[2] = &hlt_i32;

		for(i=0;i<(int)(sizeof(cases)/sizeof(cases[0]));i++) {
			int (*f)( int, int );

			/** if( a <cmp> b ) return 1 else return 0, which is what the jump has to decide. */
			memset(ops, 0, sizeof(ops));
			ops[0].op = cases[i].op; ops[0].p1 = 0; ops[0].p2 = 1; ops[0].p3 = 2;
			ops[1].op = OInt;        ops[1].p1 = 2; ops[1].p2 = 2;
			ops[2].op = ORet;        ops[2].p1 = 2;
			ops[3].op = OInt;        ops[3].p1 = 2; ops[3].p2 = 3;
			ops[4].op = ORet;        ops[4].p1 = 2;

			f = (int (*)( int, int ))build(&sig, regs, 3, ops, 5);
			report(cases[i].what, f == NULL ? -1 : f(cases[i].a, cases[i].b), cases[i].want);
		}
	}

	{
		/**
			An opcode this jit does not know, which has to be refused rather than guessed at.

			OSwitch, because hxScript's emitter lowers a switch to a chain of comparisons and never
			produces one, so this stays a case about refusing rather than a note to come back to.
		*/
		hl_type sig;
		hl_type_fun fun;
		hl_type *regs[1];
		hl_opcode ops[2];
		void *f;

		signature(&sig, &fun, NULL, 0, &hlt_i32);
		regs[0] = &hlt_i32;

		memset(ops, 0, sizeof(ops));
		ops[0].op = OSwitch; ops[0].p1 = 0; ops[0].p2 = 0; ops[0].p3 = 0;
		ops[1].op = ORet;    ops[1].p1 = 0;

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
