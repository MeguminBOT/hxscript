/*
 * Copyright (c) 2026 MeguminBOT (hxScript)
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 * DEALINGS IN THE SOFTWARE.
 */

/**
	The AArch64 half of HashLink's jit, which hashlink does not have.

	hashlink compiles bytecode to machine code in src/jit.c, and that file is an x86 and x86-64
	instruction encoder with no other backend behind it. Its own guard is on __arm__, which 64 bit ARM
	does not define, so on arm64 it compiles, emits x86, and produces something that cannot run. This
	is the counterpart, and it is a drop-in: module.c reaches a jit through exactly seven functions,
	and these are those seven under the same names.

	Nothing else of hashlink's is replaced. code.c reads a module and module.c links it, and both are
	plain C with no architecture in them, so they are shared with the x86-64 build rather than forked.

	An opcode this does not implement yet makes hl_jit_function return -1, which module.c treats as a
	module that will not link, hxs.c reports, and hxScript answers by interpreting that module
	instead. That is what makes a partial jit a slower program rather than a wrong one, and it is why
	the opcode switch below has no default that guesses.
*/

#include <hl.h>
#include <hlmodule.h>

#include <stdlib.h>
#include <string.h>

#include "a64.h"
#include "exec.h"

/**
	Where one of a function's HL registers lives.

	Every register has a home in the frame and is loaded and stored around each instruction that
	touches it, which is the model hashlink's own jit uses. It reads as wasteful and mostly is not:
	the homes are a few hundred bytes of hot stack that stays in L1, and it removes a whole class of
	bug from a backend that has to be correct before it is quick.
*/
typedef struct {
	hl_type *t;

	/** Bytes it occupies, which is 0 for void. */
	int size;

	/** Where it sits, as a positive offset from the frame pointer. */
	int offset;

	/** Whether it lives in the floating point bank rather than the general one. */
	int is_float;
} vreg;

struct _jit_ctx {
	/** Instructions, as words, since everything on this architecture is one word. */
	a64_insn *buf;
	int len;
	int cap;

	/** Set when something could not be allocated, so the failure reaches the caller once. */
	int failed;

	hl_module *m;
	hl_debug_infos *debug;

	/** The function being compiled, and where its registers live. */
	vreg *regs;
	int nregs;
	int cap_regs;

	/** Its frame size in bytes, a multiple of 16 because the stack pointer must stay so aligned. */
	int frame;
};

/** @return Whether there is room for that many more instructions, growing the buffer if not. */
static int room( jit_ctx *ctx, int words ) {
	int cap;
	a64_insn *grown;

	if( ctx->len + words <= ctx->cap )
		return 1;

	cap = ctx->cap ? ctx->cap : 4096;
	while( cap < ctx->len + words )
		cap *= 2;

	grown = (a64_insn *)realloc(ctx->buf, (size_t)cap * sizeof(a64_insn));
	if( grown == NULL ) {
		ctx->failed = 1;
		return 0;
	}

	ctx->buf = grown;
	ctx->cap = cap;
	return 1;
}

/** Appends one instruction. */
static void emit( jit_ctx *ctx, a64_insn w ) {
	if( !room(ctx, 1) )
		return;

	ctx->buf[ctx->len++] = w;
}

/** @return Whether a type is held in the floating point bank. */
static int is_float( hl_type *t ) {
	return t->kind == HF32 || t->kind == HF64;
}

/**
	Puts a 32 bit constant in a register.

	One instruction where it fits in sixteen bits either way up, or where its complement does, and
	two otherwise. Worth the three cases: most constants a script contains are small.
*/
static void emit_imm32( jit_ctx *ctx, int rd, int v ) {
	unsigned int u = (unsigned int)v;

	if( (u & 0xFFFF0000u) == 0 ) {
		emit(ctx, a64_movz(0, rd, u, A64_HW0));
	} else if( (u & 0x0000FFFFu) == 0 ) {
		emit(ctx, a64_movz(0, rd, u >> 16, A64_HW16));
	} else if( (~u & 0xFFFF0000u) == 0 ) {
		emit(ctx, a64_movn(0, rd, ~u & 0xFFFFu, A64_HW0));
	} else {
		emit(ctx, a64_movz(0, rd, u & 0xFFFFu, A64_HW0));
		emit(ctx, a64_movk(0, rd, u >> 16, A64_HW16));
	}
}

/** @return The size field a load or store of that many bytes wants. */
static int width_of( int size ) {
	switch( size ) {
		case 1: return A64_B;
		case 2: return A64_H;
		case 4: return A64_W;
		default: return A64_X;
	}
}

/**
	Reads one of the function's registers into a machine register.

	@param r Which HL register.
	@param into A general register, or a floating point one when the HL register is a float.
*/
static void load_reg( jit_ctx *ctx, int r, int into ) {
	vreg *v = ctx->regs + r;

	if( v->size == 0 )
		return;

	if( v->is_float )
		emit(ctx, a64_ldr_fp_imm(width_of(v->size), into, A64_FP, (unsigned int)(v->offset / v->size)));
	else
		emit(ctx, a64_ldr_imm(width_of(v->size), into, A64_FP, (unsigned int)(v->offset / v->size)));
}

/** Writes a machine register into one of the function's registers. */
static void store_reg( jit_ctx *ctx, int r, int from ) {
	vreg *v = ctx->regs + r;

	if( v->size == 0 )
		return;

	if( v->is_float )
		emit(ctx, a64_str_fp_imm(width_of(v->size), from, A64_FP, (unsigned int)(v->offset / v->size)));
	else
		emit(ctx, a64_str_imm(width_of(v->size), from, A64_FP, (unsigned int)(v->offset / v->size)));
}

/**
	Works out where every register of a function lives, and how big its frame is.

	The saved frame pointer and link register take the first sixteen bytes, so homes start above
	them. Each is aligned to its own size, which keeps the scaled form of every load and store
	usable: that form multiplies its offset by the access width, so an unaligned home would need the
	unscaled form and its much shorter reach.

	@return Whether it fits. A frame beyond what one instruction can subtract is refused rather than
	        emitted in two, because nothing hxScript emits comes close and guessing at the shape of
	        something untested is worse than not compiling it.
*/
static int layout( jit_ctx *ctx, hl_function *f ) {
	int i, at = 16;

	if( f->nregs > ctx->cap_regs ) {
		vreg *grown = (vreg *)realloc(ctx->regs, sizeof(vreg) * (size_t)f->nregs);

		if( grown == NULL ) {
			ctx->failed = 1;
			return 0;
		}

		ctx->regs = grown;
		ctx->cap_regs = f->nregs;
	}

	ctx->nregs = f->nregs;

	for(i=0;i<f->nregs;i++) {
		vreg *v = ctx->regs + i;
		hl_type *t = f->regs[i];
		int size = hl_type_size(t);

		v->t = t;
		v->is_float = is_float(t);

		if( size == 0 ) {
			v->size = 0;
			v->offset = 0;
			continue;
		}

		at += hl_pad_size(at, t);
		v->size = size;
		v->offset = at;
		at += size;
	}

	ctx->frame = (at + 15) & ~15;
	return ctx->frame <= 4095;
}

/**
	Opens a frame and puts the incoming arguments into it.

	The subtraction is separate from the store rather than folded into a pre-indexed one, which costs
	an instruction once per call and makes every frame the same shape whatever its size.

	@return Whether the function's arguments can be received. Anything past the eighth of either bank
	        arrives on the stack, and where it arrives differs between AAPCS64 and Apple's ABI, so it
	        is refused until there is an Apple machine to settle it on.
*/
static int prologue( jit_ctx *ctx, hl_function *f ) {
	hl_type_fun *sig = f->type->fun;
	int i, ints = 0, floats = 0;

	emit(ctx, a64_sub_imm(1, A64_SP, A64_SP, (unsigned int)ctx->frame));
	emit(ctx, a64_stp(1, A64_PAIR_OFF, A64_FP, A64_LR, A64_SP, 0));
	emit(ctx, a64_mov_sp(1, A64_FP, A64_SP));

	for(i=0;i<sig->nargs;i++) {
		if( i >= ctx->nregs )
			return 0;

		if( ctx->regs[i].size == 0 )
			continue;

		if( ctx->regs[i].is_float ) {
			if( floats > 7 )
				return 0;

			store_reg(ctx, i, floats++);
		} else {
			if( ints > 7 )
				return 0;

			store_reg(ctx, i, ints++);
		}
	}

	return 1;
}

/** Closes the frame and returns. Emitted at every return rather than jumped to, since it is three instructions. */
static void epilogue( jit_ctx *ctx ) {
	emit(ctx, a64_ldp(1, A64_PAIR_OFF, A64_FP, A64_LR, A64_SP, 0));
	emit(ctx, a64_add_imm(1, A64_SP, A64_SP, (unsigned int)ctx->frame));
	emit(ctx, a64_ret(A64_LR));
}

/**
	Compiles one instruction.

	@return Whether it was compiled. False means this jit does not know the opcode yet, which fails
	        the whole module and leaves it to be interpreted.
*/
static int compile_op( jit_ctx *ctx, hl_function *f, hl_opcode *op ) {
	(void)f;

	switch( op->op ) {
		case OInt:
			emit_imm32(ctx, A64_IP0, ctx->m->code->ints[op->p2]);
			store_reg(ctx, op->p1, A64_IP0);
			return 1;

		case ORet:
			if( ctx->regs[op->p1].size != 0 )
				load_reg(ctx, op->p1, 0);

			epilogue(ctx);
			return 1;

		default:
			return 0;
	}
}

jit_ctx *hl_jit_alloc( void ) {
	return (jit_ctx *)calloc(1, sizeof(jit_ctx));
}

void hl_jit_free( jit_ctx *ctx, h_bool can_reset ) {
	if( ctx == NULL )
		return;

	/**
		A context kept for hot reload keeps its buffer, since patching a module compiles into the
		same one. Nothing here asks for that yet, and freeing what is not kept is the same either
		way.
	*/
	if( !can_reset ) {
		free(ctx->buf);
		free(ctx->regs);
		free(ctx);
	}
}

void hl_jit_init( jit_ctx *ctx, hl_module *m ) {
	ctx->m = m;
	ctx->len = 0;
	ctx->failed = 0;

	if( m->code->hasdebug ) {
		ctx->debug = (hl_debug_infos *)malloc(sizeof(hl_debug_infos) * (size_t)m->code->nfunctions);

		if( ctx->debug != NULL )
			memset(ctx->debug, -1, sizeof(hl_debug_infos) * (size_t)m->code->nfunctions);
	}
}

void hl_jit_reset( jit_ctx *ctx, hl_module *m ) {
	ctx->debug = NULL;
	hl_jit_init(ctx, m);
}

int hl_jit_function( jit_ctx *ctx, hl_module *m, hl_function *f ) {
	int at = ctx->len * (int)sizeof(a64_insn);
	int i;

	(void)m;

	if( !layout(ctx, f) )
		return -1;

	if( !prologue(ctx, f) )
		return -1;

	for(i=0;i<f->nops;i++) {
		if( !compile_op(ctx, f, f->ops + i) )
			return -1;
	}

	/**
		A function that runs off its end is one whose last instruction was not a return, which
		hashlink's bytecode does not produce. Filling the gap with a breakpoint rather than a return
		means a mistake here stops where it happened instead of returning a register nobody set.
	*/
	emit(ctx, a64_brk(0));

	return ctx->failed ? -1 : at;
}

void *hl_jit_code( jit_ctx *ctx, hl_module *m, int *codesize, hl_debug_infos **debug, hl_module *previous ) {
	size_t bytes = (size_t)ctx->len * sizeof(a64_insn);
	void *at;

	(void)m;
	(void)previous;

	if( ctx->failed || bytes == 0 )
		return NULL;

	at = hxs_exec_alloc(bytes);
	if( at == NULL )
		return NULL;

	hxs_exec_unseal(at, bytes);
	memcpy(at, ctx->buf, bytes);
	hxs_exec_seal(at, bytes);

	*codesize = (int)bytes;
	*debug = ctx->debug;

	return at;
}

/**
	Points an already compiled function at a new one, for hot reload.

	Six instructions, which is twenty four bytes, so a function shorter than that cannot be patched
	this way. Nothing hxScript does reaches here: hxs.c loads with hot_reload false and never calls
	hl_module_patch, so this exists to answer the symbol module.c links against rather than because
	it is used.
*/
void hl_jit_patch_method( void *old_fun, void **new_fun_table ) {
	a64_insn *at = (a64_insn *)old_fun;
	unsigned long long table = (unsigned long long)(size_t)new_fun_table;

	hxs_exec_unseal(old_fun, 6 * sizeof(a64_insn));

	at[0] = a64_movz(1, A64_IP0, (unsigned int)(table & 0xFFFF), A64_HW0);
	at[1] = a64_movk(1, A64_IP0, (unsigned int)((table >> 16) & 0xFFFF), A64_HW16);
	at[2] = a64_movk(1, A64_IP0, (unsigned int)((table >> 32) & 0xFFFF), A64_HW32);
	at[3] = a64_movk(1, A64_IP0, (unsigned int)((table >> 48) & 0xFFFF), A64_HW48);
	at[4] = a64_ldr_imm(A64_X, A64_IP0, A64_IP0, 0);
	at[5] = a64_br(A64_IP0);

	hxs_exec_seal(old_fun, 6 * sizeof(a64_insn));
}
