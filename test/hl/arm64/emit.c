/**
	Emits machine code with a64.h, makes it executable with exec.h, and calls it.

	No HashLink anywhere in here. What this settles is everything underneath a JIT that has nothing
	to do with bytecode: that the encoder's words are the instructions it thinks they are on a real
	processor rather than only to an assembler, that a frame set up by hand is one the machine agrees
	with, that a branch patched after the fact lands where it was pointed, that both register banks
	survive a call boundary, and that code written into fresh pages is visible to the processor as
	instructions rather than as whatever was at that address before.

	The last of those is the one that bites. On AArch64 the caches are not coherent, so skipping the
	flush produces failures that move when you look at them.
*/
#include <stdio.h>
#include <string.h>

#include "a64.h"
#include "exec.h"

static a64_insn buf[256];
static int len;

static int fail;

static void emit( a64_insn w ) {
	buf[len++] = w;
}

/** A 64 bit constant, which is four instructions and is how an address gets into a register. */
static void emit_imm64( int rd, unsigned long long v ) {
	emit(a64_movz(1, rd, (unsigned int)(v & 0xFFFF), A64_HW0));
	emit(a64_movk(1, rd, (unsigned int)((v >> 16) & 0xFFFF), A64_HW16));
	emit(a64_movk(1, rd, (unsigned int)((v >> 32) & 0xFFFF), A64_HW32));
	emit(a64_movk(1, rd, (unsigned int)((v >> 48) & 0xFFFF), A64_HW48));
}

/** Starts a function over. */
static void begin( void ) {
	len = 0;
}

/**
	Publishes what has been emitted.

	Written while the pages are writable and sealed before anything jumps into them, which is both
	the W^X dance where that is enforced and the cache flush everywhere.

	@return Somewhere to call, or NULL when the pages could not be had.
*/
static void *finish( void ) {
	size_t bytes = (size_t)len * sizeof(a64_insn);
	void *at = hxs_exec_alloc(bytes);

	if( at == NULL )
		return NULL;

	hxs_exec_unseal(at, bytes);
	memcpy(at, buf, bytes);
	hxs_exec_seal(at, bytes);

	return at;
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

/** Something to call out to, so a call boundary is a real one. */
static int multiply( int a, int b ) {
	return a * b;
}

int main( void ) {
	printf("-- the machine agrees with the encoder --\n");

	{
		/** add w0, w0, w1 / ret, which is the smallest thing that can be wrong. */
		int (*f)( int, int );

		begin();
		emit(a64_add_reg(0, 0, 0, 1));
		emit(a64_ret(A64_LR));

		f = (int (*)( int, int ))finish();
		report("two arguments added", f == NULL ? -1 : f(40, 2), 42);
	}

	{
		/**
			A frame, written to and read back.

			stp with a pre-index is the prologue, ldp with a post-index is the epilogue, and between
			them the two arguments go into the frame and come back out, so a wrong offset or a wrong
			scale shows up as a wrong answer rather than as a crash somewhere else.
		*/
		int (*f)( int, int );

		begin();
		emit(a64_stp(1, A64_PAIR_PRE, A64_FP, A64_LR, A64_SP, -4));
		emit(a64_mov_sp(1, A64_FP, A64_SP));
		emit(a64_str_imm(A64_W, 0, A64_FP, 4));
		emit(a64_str_imm(A64_W, 1, A64_FP, 5));
		emit(a64_ldr_imm(A64_W, 2, A64_FP, 4));
		emit(a64_ldr_imm(A64_W, 3, A64_FP, 5));
		emit(a64_sub_reg(0, 0, 2, 3));
		emit(a64_ldp(1, A64_PAIR_POST, A64_FP, A64_LR, A64_SP, 4));
		emit(a64_ret(A64_LR));

		f = (int (*)( int, int ))finish();
		report("through a frame and back", f == NULL ? -1 : f(50, 8), 42);
	}

	{
		/**
			A branch emitted before its target is known and patched once it is.

			This is how every forward jump in the JIT will be written, so it is worth proving on a
			four instruction function rather than discovering inside a loop.
		*/
		int (*f)( int, int );
		int at;

		begin();
		emit(a64_cmp_reg(0, 0, 1));
		at = len;
		emit(a64_bcond(A64_GE, 0));
		emit(a64_mov_reg(0, 0, 1));
		buf[at] = a64_bcond(A64_GE, len - at);
		emit(a64_ret(A64_LR));

		f = (int (*)( int, int ))finish();
		report("a patched branch, taken", f == NULL ? -1 : f(42, 7), 42);
		report("a patched branch, not taken", f == NULL ? -1 : f(7, 42), 42);
	}

	{
		/** The other register bank, which has its own arguments and its own return. */
		double (*f)( double, double );

		begin();
		emit(a64_fadd(A64_F64, 0, 0, 1));
		emit(a64_ret(A64_LR));

		f = (double (*)( double, double ))finish();
		report_d("two doubles added", f == NULL ? -1 : f(40.5, 1.5), 42.0);
	}

	{
		/**
			Calling out, which needs a frame because the link register does not survive it.

			The address goes in through movz and movk rather than a relative branch, since the buffer
			is assembled in one place and executed in another and anything relative would be wrong
			across that move.
		*/
		int (*f)( int, int );

		begin();
		emit(a64_stp(1, A64_PAIR_PRE, A64_FP, A64_LR, A64_SP, -2));
		emit(a64_mov_sp(1, A64_FP, A64_SP));
		emit_imm64(A64_IP0, (unsigned long long)(size_t)&multiply);
		emit(a64_blr(A64_IP0));
		emit(a64_ldp(1, A64_PAIR_POST, A64_FP, A64_LR, A64_SP, 2));
		emit(a64_ret(A64_LR));

		f = (int (*)( int, int ))finish();
		report("a call out and back", f == NULL ? -1 : f(6, 7), 42);
	}

	{
		/**
			The ninth argument, which is the first one that arrives on the stack.

			AAPCS64 gives every stack argument an eight byte slot. Apple's ABI packs them at their
			natural size instead, so this reads 42 here and would read the wrong half of two
			arguments on macOS. It is here to record which of the two this build is, not to claim
			they are the same.
		*/
		int (*f)( int, int, int, int, int, int, int, int, int );

		begin();
		emit(a64_ldr_imm(A64_W, 0, A64_SP, 0));
		emit(a64_ret(A64_LR));

		f = (int (*)( int, int, int, int, int, int, int, int, int ))finish();
		report("the ninth argument, off the stack", f == NULL ? -1 : f(1, 2, 3, 4, 5, 6, 7, 8, 42), 42);
	}

	printf("\n  %-42s %s\n", "W^X enforced here", hxs_exec_strict() ? "yes" : "no");

	printf("\n");
	if( fail == 0 ) {
		printf("== everything emitted ran correctly ==\n");
		return 0;
	}

	printf("== %d failed ==\n", fail);
	return 1;
}
