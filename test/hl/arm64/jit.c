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

/** One function to compile, as build_module takes them. */
typedef struct {
	hl_type *sig;
	hl_type **regs;
	int nregs;
	hl_opcode *ops;
	int nops;
	int findex;
} fndef;

static hl_function built[8];
static int indexes[8];
static void *pointers[8];

/**
	Compiles several functions as one module, the way module.c does it.

	Calls between them are the reason this exists. A call names its target by index, and the address
	behind that index is an offset until every function has been compiled and hl_jit_code has said
	where the code went, so a call cannot be checked one function at a time.

	The order here is module.c's order, deliberately: compile each and keep the offset it returns,
	ask for the code, then turn the offsets into addresses.

	@param defs The functions.
	@param n How many.
	@param out Filled with somewhere to call for each.
	@return Whether all of them compiled.
*/
static int build_module( fndef *defs, int n, void **out ) {
	jit_ctx *ctx;
	hl_debug_infos *debug = NULL;
	unsigned char *base;
	int i, size = 0;

	memset(built, 0, sizeof(built));
	memset(indexes, 0, sizeof(indexes));
	memset(pointers, 0, sizeof(pointers));

	for(i=0;i<n;i++) {
		built[i].findex = defs[i].findex;
		built[i].nregs = defs[i].nregs;
		built[i].nops = defs[i].nops;
		built[i].type = defs[i].sig;
		built[i].regs = defs[i].regs;
		built[i].ops = defs[i].ops;

		indexes[defs[i].findex] = i;
	}

	code.functions = built;
	code.nfunctions = n;
	code.nnatives = 0;
	m.functions_indexes = indexes;
	m.functions_ptrs = pointers;

	ctx = hl_jit_alloc();
	if( ctx == NULL )
		return 0;

	hl_jit_init(ctx, &m);

	for(i=0;i<n;i++) {
		int fpos = hl_jit_function(ctx, &m, built + i);

		if( fpos < 0 )
			return 0;

		m.functions_ptrs[built[i].findex] = (void *)(size_t)fpos;
	}

	base = (unsigned char *)hl_jit_code(ctx, &m, &size, &debug, NULL);
	if( base == NULL )
		return 0;

	for(i=0;i<n;i++)
		out[i] = base + (size_t)m.functions_ptrs[built[i].findex];

	return 1;
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
		/** Between the two banks, which is one instruction each way. */
		hl_type sig;
		hl_type_fun fun;
		hl_type *args[1];
		hl_type *regs[2];
		hl_opcode ops[2];
		double (*widen)( int );
		int (*narrow)( double );

		args[0] = &hlt_i32;
		signature(&sig, &fun, args, 1, &hlt_f64);
		regs[0] = &hlt_i32;
		regs[1] = &hlt_f64;

		memset(ops, 0, sizeof(ops));
		ops[0].op = OToSFloat; ops[0].p1 = 1; ops[0].p2 = 0;
		ops[1].op = ORet;      ops[1].p1 = 1;
		widen = (double (*)( int ))build(&sig, regs, 2, ops, 2);
		report_d("an int widened to a float", widen == NULL ? -1 : widen(42), 42.0);

		args[0] = &hlt_f64;
		signature(&sig, &fun, args, 1, &hlt_i32);
		regs[0] = &hlt_f64;
		regs[1] = &hlt_i32;

		memset(ops, 0, sizeof(ops));
		ops[0].op = OToInt; ops[0].p1 = 1; ops[0].p2 = 0;
		ops[1].op = ORet;   ops[1].p1 = 1;
		narrow = (int (*)( double ))build(&sig, regs, 2, ops, 2);
		report("42.9 truncated towards zero", narrow == NULL ? -1 : narrow(42.9), 42);
		report("-42.9 truncated towards zero", narrow == NULL ? -1 : narrow(-42.9), -42);
	}

	{
		/**
			A global, which lives at an address that exists before any of this is compiled.
		*/
		hl_type sig;
		hl_type_fun fun;
		hl_type *regs[1];
		hl_opcode ops[2];
		int (*f)( void );
		static int storage[2];
		static int where[1];

		storage[0] = 0;
		storage[1] = 42;
		where[0] = (int)sizeof(int);

		m.globals_data = (unsigned char *)storage;
		m.globals_indexes = where;
		code.nglobals = 1;

		signature(&sig, &fun, NULL, 0, &hlt_i32);
		regs[0] = &hlt_i32;

		memset(ops, 0, sizeof(ops));
		ops[0].op = OGetGlobal; ops[0].p1 = 0; ops[0].p2 = 0;
		ops[1].op = ORet;       ops[1].p1 = 0;

		f = (int (*)( void ))build(&sig, regs, 1, ops, 2);
		report("a global read", f == NULL ? -1 : f(), 42);
	}

	{
		/**
			One function calling another, which is the case a single function cannot check: the
			address of the target does not exist until both have been compiled and the code has been
			put somewhere.
		*/
		hl_type add_sig, call_sig;
		hl_type_fun add_fun, call_fun;
		hl_type *add_args[2];
		hl_type *call_args[1];
		hl_type *add_regs[3];
		hl_type *call_regs[3];
		hl_opcode add_ops[2];
		hl_opcode call_ops[3];
		fndef defs[2];
		void *out[2];
		int (*f)( int );

		add_args[0] = add_args[1] = &hlt_i32;
		signature(&add_sig, &add_fun, add_args, 2, &hlt_i32);
		add_regs[0] = add_regs[1] = add_regs[2] = &hlt_i32;

		memset(add_ops, 0, sizeof(add_ops));
		add_ops[0].op = OAdd; add_ops[0].p1 = 2; add_ops[0].p2 = 0; add_ops[0].p3 = 1;
		add_ops[1].op = ORet; add_ops[1].p1 = 2;

		call_args[0] = &hlt_i32;
		signature(&call_sig, &call_fun, call_args, 1, &hlt_i32);
		call_regs[0] = call_regs[1] = call_regs[2] = &hlt_i32;

		memset(call_ops, 0, sizeof(call_ops));
		call_ops[0].op = OInt;   call_ops[0].p1 = 1; call_ops[0].p2 = 5;
		call_ops[1].op = OCall2; call_ops[1].p1 = 2; call_ops[1].p2 = 0;
		call_ops[1].p3 = 0;      call_ops[1].extra = (int *)(size_t)1;
		call_ops[2].op = ORet;   call_ops[2].p1 = 2;

		defs[0].sig = &add_sig;  defs[0].regs = add_regs;  defs[0].nregs = 3;
		defs[0].ops = add_ops;   defs[0].nops = 2;         defs[0].findex = 0;
		defs[1].sig = &call_sig; defs[1].regs = call_regs; defs[1].nregs = 3;
		defs[1].ops = call_ops;  defs[1].nops = 3;         defs[1].findex = 1;

		f = build_module(defs, 2, out) ? (int (*)( int ))out[1] : NULL;
		report("one function calling another", f == NULL ? -1 : f(40), 42);
	}

	{
		/**
			A function calling itself, which is the same patching read from the other side: the
			target is the function being compiled, so its offset is known but its address is not.

			  fact(n) = n <= 1 ? 1 : n * fact(n - 1)
		*/
		hl_type sig;
		hl_type_fun fun;
		hl_type *args[1];
		hl_type *regs[3];
		hl_opcode ops[8];
		fndef defs[1];
		void *out[1];
		int (*f)( int );

		args[0] = &hlt_i32;
		signature(&sig, &fun, args, 1, &hlt_i32);
		regs[0] = regs[1] = regs[2] = &hlt_i32;

		memset(ops, 0, sizeof(ops));
		ops[0].op = OInt;    ops[0].p1 = 1; ops[0].p2 = 3;
		ops[1].op = OJSGt;   ops[1].p1 = 0; ops[1].p2 = 1; ops[1].p3 = 1;
		ops[2].op = ORet;    ops[2].p1 = 1;
		ops[3].op = OSub;    ops[3].p1 = 2; ops[3].p2 = 0; ops[3].p3 = 1;
		ops[4].op = OCall1;  ops[4].p1 = 2; ops[4].p2 = 7; ops[4].p3 = 2;
		ops[5].op = OMul;    ops[5].p1 = 2; ops[5].p2 = 0; ops[5].p3 = 2;
		ops[6].op = ORet;    ops[6].p1 = 2;

		defs[0].sig = &sig;  defs[0].regs = regs; defs[0].nregs = 3;
		defs[0].ops = ops;   defs[0].nops = 7;    defs[0].findex = 7;

		f = build_module(defs, 1, out) ? (int (*)( int ))out[0] : NULL;
		report("a function calling itself, 5 factorial", f == NULL ? -1 : f(5), 120);
		report("the same at its base case", f == NULL ? -1 : f(1), 1);
	}

	{
		/**
			Boxing and unboxing, which both go through the runtime because what they do depends on
			the type they are told rather than on the instruction.
		*/
		hl_type box_sig, unbox_sig;
		hl_type_fun box_fun, unbox_fun;
		hl_type *box_args[1];
		hl_type *unbox_args[1];
		hl_type *box_regs[2];
		hl_type *unbox_regs[2];
		hl_opcode ops[2];
		vdynamic *(*box)( int );
		int (*unbox)( vdynamic * );
		vdynamic *boxed;

		box_args[0] = &hlt_i32;
		signature(&box_sig, &box_fun, box_args, 1, &hlt_dyn);
		box_regs[0] = &hlt_i32;
		box_regs[1] = &hlt_dyn;

		memset(ops, 0, sizeof(ops));
		ops[0].op = OToDyn; ops[0].p1 = 1; ops[0].p2 = 0;
		ops[1].op = ORet;   ops[1].p1 = 1;
		box = (vdynamic *(*)( int ))build(&box_sig, box_regs, 2, ops, 2);

		unbox_args[0] = &hlt_dyn;
		signature(&unbox_sig, &unbox_fun, unbox_args, 1, &hlt_i32);
		unbox_regs[0] = &hlt_dyn;
		unbox_regs[1] = &hlt_i32;

		memset(ops, 0, sizeof(ops));
		ops[0].op = OSafeCast; ops[0].p1 = 1; ops[0].p2 = 0;
		ops[1].op = ORet;      ops[1].p1 = 1;
		unbox = (int (*)( vdynamic * ))build(&unbox_sig, unbox_regs, 2, ops, 2);

		boxed = box == NULL ? NULL : box(42);

		report("an int boxed, and what it holds", boxed == NULL ? -1 : boxed->v.i, 42);
		report("and the type it says it is", boxed == NULL ? -1 : (int)boxed->t->kind, (int)HI32);
		report("that box cast back to an int", unbox == NULL || boxed == NULL ? -1 : unbox(boxed), 42);
	}

	{
		/**
			A method reached through the object's own table, which is three loads: the object names
			its type, the type carries the table, and the table is indexed by position.

			The object here is a type pointer and nothing else, and the table holds one function this
			jit compiled a moment ago. That is all the dispatch actually reads, so it is all that has
			to exist for the reading to be checked.
		*/
		hl_type sig, obj_type;
		hl_type_fun fun;
		hl_type *args[2];
		hl_type *regs[3];
		hl_opcode ops[2];
		static void *table[2];
		static hl_type *instance[1];
		int (*method)( void *, int );
		int (*caller)( void *, int );

		memset(&obj_type, 0, sizeof(obj_type));
		obj_type.kind = HOBJ;
		obj_type.vobj_proto = table;
		instance[0] = &obj_type;

		/** int method(receiver, n) { return n; } */
		args[0] = &hlt_dyn;
		args[1] = &hlt_i32;
		signature(&sig, &fun, args, 2, &hlt_i32);
		regs[0] = &hlt_dyn;
		regs[1] = regs[2] = &hlt_i32;

		memset(ops, 0, sizeof(ops));
		ops[0].op = ORet; ops[0].p1 = 1;
		method = (int (*)( void *, int ))build(&sig, regs, 3, ops, 1);
		table[1] = (void *)method;

		/** int caller(receiver, n) { return receiver.method_at_1(receiver, n); } */
		regs[0] = &obj_type;
		regs[1] = regs[2] = &hlt_i32;

		memset(ops, 0, sizeof(ops));
		ops[0].op = OCallThis; ops[0].p1 = 2; ops[0].p2 = 1; ops[0].p3 = 1;
		ops[1].op = ORet;      ops[1].p1 = 2;

		{
			static int through[1];
			through[0] = 1;
			ops[0].extra = through;
		}

		caller = (int (*)( void *, int ))build(&sig, regs, 3, ops, 2);
		report("a method through the object's table", caller == NULL ? -1 : caller(instance, 42), 42);
	}

	{
		/**
			A closure, which only says at run time whether it carries a receiver, so both ways of
			arranging the arguments are emitted and one is jumped over. Both are checked here, since
			the branch is the whole of what there is to get wrong.
		*/
		hl_type sig, fsig;
		hl_type_fun fun, ffun;
		hl_type *args[2];
		hl_type *regs[3];
		hl_opcode ops[2];
		static vclosure bare, bound;
		int (*plain)( int );
		int (*two)( void *, int );
		int (*call)( vclosure * );

		/** int plain(n) { return n; } */
		args[0] = &hlt_i32;
		signature(&fsig, &ffun, args, 1, &hlt_i32);
		regs[0] = regs[1] = &hlt_i32;

		memset(ops, 0, sizeof(ops));
		ops[0].op = ORet; ops[0].p1 = 0;
		plain = (int (*)( int ))build(&fsig, regs, 2, ops, 1);

		/** int two(receiver, n) { return n; } */
		args[0] = &hlt_dyn;
		args[1] = &hlt_i32;
		signature(&sig, &fun, args, 2, &hlt_i32);
		regs[0] = &hlt_dyn;
		regs[1] = regs[2] = &hlt_i32;

		memset(ops, 0, sizeof(ops));
		ops[0].op = ORet; ops[0].p1 = 1;
		two = (int (*)( void *, int ))build(&sig, regs, 3, ops, 1);

		memset(&bare, 0, sizeof(bare));
		bare.t = &fsig;
		bare.fun = (void *)plain;
		bare.hasValue = 0;

		memset(&bound, 0, sizeof(bound));
		bound.t = &fsig;
		bound.fun = (void *)two;
		bound.hasValue = 1;
		bound.value = (void *)&bare;

		/** int call(c) { return c(42); } */
		args[0] = &fsig;
		signature(&sig, &fun, args, 1, &hlt_i32);
		regs[0] = &fsig;
		regs[1] = regs[2] = &hlt_i32;

		memset(ops, 0, sizeof(ops));
		ops[0].op = OInt;         ops[0].p1 = 1; ops[0].p2 = 0;
		ops[1].op = OCallClosure; ops[1].p1 = 2; ops[1].p2 = 0; ops[1].p3 = 1;

		{
			static int through[1];
			through[0] = 1;
			ops[1].extra = through;
		}

		{
			hl_opcode full[3];
			memset(full, 0, sizeof(full));
			full[0] = ops[0];
			full[1] = ops[1];
			full[2].op = ORet; full[2].p1 = 2;

			call = (int (*)( vclosure * ))build(&sig, regs, 3, full, 3);
		}

		report("a closure with no receiver", call == NULL ? -1 : call(&bare), 42);
		report("a closure carrying one", call == NULL ? -1 : call(&bound), 42);
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
