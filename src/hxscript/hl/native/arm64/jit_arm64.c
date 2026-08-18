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

#include <math.h>
#include <stddef.h>
#include <stdio.h>
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

	/** Where its trap contexts begin, and how many it has. */
	int trap_off;
	int ntraps;

	/** Which trap slot the next OTrap takes, counted as the opcodes are compiled in order. */
	int trap_at;

	/**
		Where each of its opcodes begins, as an index into buf.

		A jump in HashLink's bytecode names its destination as a count of opcodes, and where those
		opcodes ended up is only known once they have all been compiled. So this is filled in as they
		are, and the jumps are patched afterwards against it.
	*/
	int *op_pos;
	int cap_ops;

	/** Jumps waiting for their destination to be known. */
	struct {
		/** Which instruction in buf is the branch. */
		int at;

		/** Which opcode it goes to. */
		int target;
	} *jumps;

	int njumps;
	int cap_jumps;

	/**
		Calls to functions of this module, whose addresses are not known until all of them are
		compiled.

		module.c fills functions_ptrs with offsets as each function is compiled and turns them into
		addresses only after hl_jit_code has said where the code went, so a call emitted now names a
		target that does not have an address yet. The four instructions that build the address are
		left as they are and rewritten once it does.

		A native is not in here. Its address is real before any of this runs, so it is built into the
		call at the point the call is emitted.
	*/
	struct {
		/** The first of the four words that build the address. */
		int at;

		/** Which function, by the index the bytecode calls it. */
		int findex;

		/** Which register it is built in, since a closure wants it as an argument rather than a target. */
		int reg;
	} *calls;

	int ncalls;
	int cap_calls;

	/** Static closures whose function has no address yet, for the same reason a call has none. */
	struct {
		vclosure *c;
		int findex;
	} *closures;

	int nclosures;
	int cap_closures;
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

/** @return Whether there is room for one more jump to patch, growing the list if not. */
static int room_jump( jit_ctx *ctx ) {
	int cap;
	void *grown;

	if( ctx->njumps < ctx->cap_jumps )
		return 1;

	cap = ctx->cap_jumps ? ctx->cap_jumps * 2 : 64;
	grown = realloc(ctx->jumps, sizeof(*ctx->jumps) * (size_t)cap);

	if( grown == NULL ) {
		ctx->failed = 1;
		return 0;
	}

	ctx->jumps = grown;
	ctx->cap_jumps = cap;
	return 1;
}

/**
	Emits a branch whose destination is not known yet and remembers to come back to it.

	@param w The branch, with a zero offset in it.
	@param target The opcode it goes to.
*/
static void emit_jump( jit_ctx *ctx, a64_insn w, int target ) {
	if( !room_jump(ctx) )
		return;

	ctx->jumps[ctx->njumps].at = ctx->len;
	ctx->jumps[ctx->njumps].target = target;
	ctx->njumps++;

	emit(ctx, w);
}

/**
	Fills in every branch now that every opcode has a position.

	The offset a branch carries is in instructions rather than bytes, and it is measured from the
	branch itself, which is what makes patching a rewrite of one field rather than a recalculation of
	anything around it.
*/
static void patch_jumps( jit_ctx *ctx ) {
	int i;

	for(i=0;i<ctx->njumps;i++) {
		int at = ctx->jumps[i].at;
		int to = ctx->op_pos[ctx->jumps[i].target];
		int off = to - at;
		a64_insn w = ctx->buf[at];

		/**
			Which field the offset goes in depends on the branch. An unconditional one carries 26
			bits at the bottom of the word and a conditional one carries 19 starting five bits up,
			and they are told apart by the opcode bits that are already there.
		*/
		if( (w & 0xFC000000u) == ((a64_insn)5 << 26) )
			ctx->buf[at] = a64_b(off);
		else
			ctx->buf[at] = (w & ~(0x7FFFFu << 5)) | (((a64_insn)off & 0x7FFFF) << 5);
	}
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
	Puts the address of somewhere in the frame into a register.

	The one instruction form reaches 4095 bytes, which every ordinary frame is inside. A frame with
	traps in it is not ordinary: a trap context is over three hundred bytes, so a handful of them puts
	the far end out of reach and it has to be built instead.
*/
static void emit_fp_offset( jit_ctx *ctx, int off, int into ) {
	if( off <= 0xFFF ) {
		emit(ctx, a64_add_imm(1, into, A64_FP, (unsigned int)off));
		return;
	}

	emit_imm32(ctx, into, off);
	emit(ctx, a64_add_reg(1, into, A64_FP, into));
}

/**
	Moves the stack pointer by any amount a frame can be.

	One instruction reaches 4095 bytes and a second shifted one reaches sixteen megabytes, which is
	past anything a function could want. Written as one place rather than at both ends, so the
	prologue and the epilogue cannot disagree about how far they moved.

	@param add Whether to give the space back rather than take it.
*/
static void adjust_sp( jit_ctx *ctx, int bytes, int add ) {
	int hi = bytes >> 12;
	int lo = bytes & 0xFFF;

	if( hi )
		emit(ctx, a64_addsub_imm(1, !add, 0, A64_SP, A64_SP, (unsigned int)hi, 1));

	if( lo )
		emit(ctx, a64_addsub_imm(1, !add, 0, A64_SP, A64_SP, (unsigned int)lo, 0));
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

	/**
		Room for the trap contexts, one per OTrap in the function.

		Each is over three hundred bytes, so they are counted rather than assumed. Reusing a slot
		across iterations is safe because a trap is entered and left within the same stretch of
		execution: a loop containing a try reaches the same OTrap only after the OEndTrap that closed
		the last one.
	*/
	at = (at + 15) & ~15;
	ctx->trap_off = at;
	ctx->ntraps = 0;

	for(i=0;i<f->nops;i++)
		if( f->ops[i].op == OTrap )
			ctx->ntraps++;

	at += ctx->ntraps * (int)sizeof(hl_trap_ctx);

	ctx->frame = (at + 15) & ~15;
	return ctx->frame <= 0xFFFFFF;
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

	adjust_sp(ctx, ctx->frame, 0);
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
	adjust_sp(ctx, ctx->frame, 1);
	emit(ctx, a64_ret(A64_LR));
}

/**
	The registers everything here computes in.

	x16 and x17 are the platform's intra-procedure-call scratch, which no ABI expects preserved, and
	x15 is an ordinary caller-saved temporary. The floating point bank uses the same three numbers:
	d16 and d17 are caller-saved there too, so one pair of names covers both banks and load_reg picks
	which by the type of what it is loading.
*/
#define S0	A64_IP0
#define S1	A64_IP1
#define S2	15

/** @return Whether a register is held in 64 bits rather than 32. */
static int wide( jit_ctx *ctx, int r ) {
	return ctx->regs[r].size == 8;
}

/** @return Which precision a floating point register holds. */
static int fp_type( jit_ctx *ctx, int r ) {
	return ctx->regs[r].size == 8 ? A64_F64 : A64_F32;
}

/** Puts a 64 bit constant in a register, which is how an address that must survive a copy gets there. */
static void emit_imm64( jit_ctx *ctx, int rd, unsigned long long v ) {
	emit(ctx, a64_movz(1, rd, (unsigned int)(v & 0xFFFF), A64_HW0));
	emit(ctx, a64_movk(1, rd, (unsigned int)((v >> 16) & 0xFFFF), A64_HW16));
	emit(ctx, a64_movk(1, rd, (unsigned int)((v >> 32) & 0xFFFF), A64_HW32));
	emit(ctx, a64_movk(1, rd, (unsigned int)((v >> 48) & 0xFFFF), A64_HW48));
}

/**
	Calls a C function, with the arguments already in place.

	The address is built out of movz and movk rather than reached by a relative branch, because the
	buffer is assembled in one place and copied somewhere else before it runs, so a relative offset
	computed here would point at whatever now sits at that distance from there.
*/
static void emit_call( jit_ctx *ctx, void *fn ) {
	emit_imm64(ctx, S0, (unsigned long long)(size_t)fn);
	emit(ctx, a64_blr(S0));
}

/**
	Puts a floating point constant in a register.

	Through the general bank and across, rather than out of a pool of constants next to the code.
	A pool would be one load instead of five instructions, and it would have to be found by an
	address this cannot know until hl_jit_code has copied the buffer somewhere executable.
*/
static void emit_float( jit_ctx *ctx, int r, double v ) {
	if( ctx->regs[r].size == 8 ) {
		unsigned long long bits;
		memcpy(&bits, &v, sizeof(bits));

		emit_imm64(ctx, S0, bits);
		emit(ctx, a64_fmov_from_gpr(1, A64_F64, S0, S0));
	} else {
		float single = (float)v;
		unsigned int bits;
		memcpy(&bits, &single, sizeof(bits));

		emit_imm32(ctx, S0, (int)bits);
		emit(ctx, a64_fmov_from_gpr(0, A64_F32, S0, S0));
	}

	store_reg(ctx, r, S0);
}

/** @return Whether there is room for one more call to patch, growing the list if not. */
static int room_call( jit_ctx *ctx ) {
	int cap;
	void *grown;

	if( ctx->ncalls < ctx->cap_calls )
		return 1;

	cap = ctx->cap_calls ? ctx->cap_calls * 2 : 64;
	grown = realloc(ctx->calls, sizeof(*ctx->calls) * (size_t)cap);

	if( grown == NULL ) {
		ctx->failed = 1;
		return 0;
	}

	ctx->calls = grown;
	ctx->cap_calls = cap;
	return 1;
}

/**
	@param findex A function as the bytecode names it.
	@return Whether that is a native rather than a function of this module.

	Which one it is decides whether the address can be built now or has to wait: module.c gives a
	native its real address before any of this runs, and gives a function of the module an offset that
	only becomes an address after hl_jit_code.
*/
static int is_native( jit_ctx *ctx, int findex ) {
	return ctx->m->functions_indexes[findex] >= ctx->m->code->nfunctions;
}

/**
	Puts the arguments of a call where the ABI expects them.

	@param args The registers holding them.
	@param nargs How many.
	@return Whether they all fit in registers. Anything past the eighth of either bank goes on the
	        stack, and where it goes there differs between AAPCS64 and Apple's ABI, so it is refused
	        until there is an Apple machine to settle it on.

	Each one is read out of its home in the frame, so loading into x1 cannot disturb what x0 needs.
	That is a property of holding every register in memory, and it is most of why doing so is worth
	the loads.
*/
static int pass_args( jit_ctx *ctx, int *args, int nargs ) {
	int i, ints = 0, floats = 0;

	for(i=0;i<nargs;i++) {
		vreg *v = ctx->regs + args[i];

		if( v->size == 0 )
			continue;

		if( v->is_float ) {
			if( floats > 7 )
				return 0;

			load_reg(ctx, args[i], floats++);
		} else {
			if( ints > 7 )
				return 0;

			load_reg(ctx, args[i], ints++);
		}
	}

	return 1;
}

/**
	Calls a function of this module or a native, and keeps what comes back.

	@param dst Where the result goes, or a register of no size when there is none.
	@param findex The function.
	@param args Its arguments.
	@param nargs How many.
	@return Whether the call could be built.
*/
static int emit_hl_call( jit_ctx *ctx, int dst, int findex, int *args, int nargs ) {
	if( !pass_args(ctx, args, nargs) )
		return 0;

	if( is_native(ctx, findex) ) {
		emit_call(ctx, ctx->m->functions_ptrs[findex]);
	} else {
		if( !room_call(ctx) )
			return 0;

		ctx->calls[ctx->ncalls].at = ctx->len;
		ctx->calls[ctx->ncalls].findex = findex;
		ctx->calls[ctx->ncalls].reg = S0;
		ctx->ncalls++;

		/** Four words of nothing in particular, rewritten once the address exists. */
		emit_imm64(ctx, S0, 0);
		emit(ctx, a64_blr(S0));
	}

	if( ctx->regs[dst].size != 0 )
		store_reg(ctx, dst, 0);

	return 1;
}

/**
	Reads the byte offset of one of an object's fields.

	@return The offset, or -1 when the field is not one this can reach directly. A virtual or a
	        dynamic resolves its fields by name at run time and is left to the interpreter for now.
*/
static int field_offset( hl_type *t, int field ) {
	hl_runtime_obj *rt;

	if( t->kind != HOBJ && t->kind != HSTRUCT )
		return -1;

	rt = hl_get_obj_rt(t);

	if( rt == NULL || field < 0 || field >= rt->nfields )
		return -1;

	return rt->fields_indexes[field];
}

/**
	Reads from or writes to memory at a constant offset from a pointer already in a register.

	@param base The register holding the pointer.
	@param off The offset in bytes.
	@param r Which of the function's registers is the other end, for its width and its bank.
	@param into The register to load into or store from.
	@param store Whether this is a write.
	@return Whether the offset can be reached.
*/
static int mem_access( jit_ctx *ctx, int base, int off, int r, int into, int store ) {
	vreg *v = ctx->regs + r;
	int width = width_of(v->size);
	unsigned int scaled;

	if( v->size == 0 || off < 0 || (off % v->size) != 0 )
		return 0;

	scaled = (unsigned int)(off / v->size);
	if( scaled > 0xFFF )
		return 0;

	if( v->is_float )
		emit(ctx, store ? a64_str_fp_imm(width, into, base, scaled) : a64_ldr_fp_imm(width, into, base, scaled));
	else
		emit(ctx, store ? a64_str_imm(width, into, base, scaled) : a64_ldr_imm(width, into, base, scaled));

	return 1;
}

/**
	Puts the arguments of a call where the ABI expects them, starting part way along.

	A closure carrying a receiver passes it as the first argument, so everything else moves along one
	place in the general bank. The floating point bank is unaffected, since a receiver is a pointer.

	@param ints0 Which general argument register to start at.
	@return Whether they all fit in registers.
*/
static int pass_args_from( jit_ctx *ctx, int *args, int nargs, int ints0 ) {
	int i, ints = ints0, floats = 0;

	for(i=0;i<nargs;i++) {
		vreg *v = ctx->regs + args[i];

		if( v->size == 0 )
			continue;

		if( v->is_float ) {
			if( floats > 7 )
				return 0;

			load_reg(ctx, args[i], floats++);
		} else {
			if( ints > 7 )
				return 0;

			load_reg(ctx, args[i], ints++);
		}
	}

	return 1;
}

/**
	Reads a method out of an object's table of them.

	An object begins with a pointer to its type, a type carries the table, and the table is indexed
	by the position the bytecode names. Three loads, and the offsets are asked of the structures
	rather than written down, since writing them down is how a jit and the runtime it shares memory
	with drift apart.

	@param obj The register holding the object.
	@param index Which method.
	@param into Where to leave its address.
*/
static void emit_method_addr( jit_ctx *ctx, int obj, int index, int into ) {
	load_reg(ctx, obj, S1);
	emit(ctx, a64_ldr_imm(A64_X, S2, S1, 0));
	emit(ctx, a64_ldr_imm(A64_X, S2, S2, (unsigned int)(offsetof(hl_type, vobj_proto) / 8)));
	emit(ctx, a64_ldr_imm(A64_X, into, S2, (unsigned int)index));
}

/**
	Calls a method found in an object's table.

	@param dst Where the result goes.
	@param obj The register holding the receiver.
	@param index Which method.
	@param args Every argument, the receiver included, since it is the first.
	@param nargs How many.
	@return Whether the call could be built.
*/
static int emit_method_call( jit_ctx *ctx, int dst, int obj, int index, int *args, int nargs ) {
	hl_type *t = ctx->regs[obj].t;

	/**
		A virtual resolves its fields by name at run time and answers a different way when it has
		none, so it is left to the interpreter rather than half done here.
	*/
	if( t->kind != HOBJ && t->kind != HSTRUCT )
		return 0;

	emit_method_addr(ctx, obj, index, S0);

	if( !pass_args(ctx, args, nargs) )
		return 0;

	emit(ctx, a64_blr(S0));

	if( ctx->regs[dst].size != 0 )
		store_reg(ctx, dst, 0);

	return 1;
}

/**
	@return Whether the runtime's dynamic helpers for this kind take the destination type.

	hl_dyn_getd and hl_dyn_castd and their float and 64 bit relatives already know what they are
	producing from the function that was chosen, so they take two arguments where the others take
	three. Getting that wrong passes a type pointer as nothing in particular.
*/
static int helper_is_short( hl_type *t ) {
	return t->kind == HF32 || t->kind == HF64 || t->kind == HI64 || t->kind == HGUID;
}

/** @return The runtime's cast for this destination kind. */
static void *cast_helper( hl_type *t ) {
	switch( t->kind ) {
		case HF32: return (void *)(size_t)&hl_dyn_castf;
		case HF64: return (void *)(size_t)&hl_dyn_castd;
		case HI64:
		case HGUID: return (void *)(size_t)&hl_dyn_casti64;
		case HI32:
		case HUI16:
		case HUI8:
		case HBOOL: return (void *)(size_t)&hl_dyn_casti;
		default: return (void *)(size_t)&hl_dyn_castp;
	}
}

/** @return The runtime's dynamic field read for this destination kind. */
static void *get_helper( hl_type *t ) {
	switch( t->kind ) {
		case HF32: return (void *)(size_t)&hl_dyn_getf;
		case HF64: return (void *)(size_t)&hl_dyn_getd;
		case HI64:
		case HGUID: return (void *)(size_t)&hl_dyn_geti64;
		case HI32:
		case HUI16:
		case HUI8:
		case HBOOL: return (void *)(size_t)&hl_dyn_geti;
		default: return (void *)(size_t)&hl_dyn_getp;
	}
}

/** @return The runtime's dynamic field write for this value kind. */
static void *set_helper( hl_type *t ) {
	switch( t->kind ) {
		case HF32: return (void *)(size_t)&hl_dyn_setf;
		case HF64: return (void *)(size_t)&hl_dyn_setd;
		case HI64:
		case HGUID: return (void *)(size_t)&hl_dyn_seti64;
		case HI32:
		case HUI16:
		case HUI8:
		case HBOOL: return (void *)(size_t)&hl_dyn_seti;
		default: return (void *)(size_t)&hl_dyn_setp;
	}
}

/**
	Makes the one closure a static closure hands out, rather than a new one each time it runs.

	It lives in the module's own allocator, so it lasts as long as the module does, and a loop that
	reaches the same OStaticClosure a million times hands out the same object a million times instead
	of allocating one per iteration.

	A native already has an address. Anything else joins the list hl_jit_code walks, which fills in
	the address once there is one, the same problem a call has and answered the same way.

	@return The closure, or NULL when it could not be made.
*/
static vclosure *static_closure( jit_ctx *ctx, int findex ) {
	hl_module *m = ctx->m;
	int fidx = m->functions_indexes[findex];
	vclosure *c = (vclosure *)hl_malloc(&m->ctx.alloc, sizeof(vclosure));

	if( c == NULL )
		return NULL;

	c->hasValue = 0;
	c->value = NULL;

	if( fidx >= m->code->nfunctions ) {
		c->t = m->code->natives[fidx - m->code->nfunctions].t;
		c->fun = m->functions_ptrs[findex];
		return c;
	}

	c->t = m->code->functions[fidx].type;
	c->fun = NULL;

	if( ctx->nclosures == ctx->cap_closures ) {
		int cap = ctx->cap_closures ? ctx->cap_closures * 2 : 32;
		void *grown = realloc(ctx->closures, sizeof(*ctx->closures) * (size_t)cap);

		if( grown == NULL ) {
			ctx->failed = 1;
			return NULL;
		}

		ctx->closures = grown;
		ctx->cap_closures = cap;
	}

	ctx->closures[ctx->nclosures].c = c;
	ctx->closures[ctx->nclosures].findex = findex;
	ctx->nclosures++;

	return c;
}

/**
	Puts the address of one of the function's registers in a machine register.

	Several of the runtime's entry points take a pointer to a value rather than the value, because
	they have to read it as whatever its type says. The home in the frame is that pointer, which is
	one of the quieter reasons for keeping every register in memory.
*/
static void emit_addr_of( jit_ctx *ctx, int r, int into ) {
	emit_fp_offset(ctx, ctx->regs[r].offset, into);
}

/**
	Builds the address of a function into a register, for something that wants it as a value.

	A native has one already. Anything else joins the list that hl_jit_code rewrites, exactly as a
	call does, since the two are the same problem: an address that does not exist yet.

	@return Whether it could be arranged.
*/
static int emit_func_addr( jit_ctx *ctx, int findex, int into ) {
	if( is_native(ctx, findex) ) {
		emit_imm64(ctx, into, (unsigned long long)(size_t)ctx->m->functions_ptrs[findex]);
		return 1;
	}

	if( !room_call(ctx) )
		return 0;

	ctx->calls[ctx->ncalls].at = ctx->len;
	ctx->calls[ctx->ncalls].findex = findex;
	ctx->calls[ctx->ncalls].reg = into;
	ctx->ncalls++;

	emit_imm64(ctx, into, 0);
	return 1;
}

/**
	Compiles one arithmetic or bitwise instruction.

	@return Whether it is one this knows.
*/
static int arith( jit_ctx *ctx, hl_opcode *op ) {
	int d = op->p1;
	int w = wide(ctx, d);

	if( ctx->regs[d].is_float ) {
		int t = fp_type(ctx, d);

		/**
			The remainder of two floats is a call, on every architecture. hashlink's own jit calls
			fmod here too, so this is the same answer arrived at the same way rather than a
			shortcut.
		*/
		if( op->op == OSMod ) {
			load_reg(ctx, op->p2, 0);
			load_reg(ctx, op->p3, 1);
			emit_call(ctx, t == A64_F64 ? (void *)(size_t)&fmod : (void *)(size_t)&fmodf);
			store_reg(ctx, d, 0);
			return 1;
		}

		load_reg(ctx, op->p2, S0);
		load_reg(ctx, op->p3, S1);

		switch( op->op ) {
			case OAdd:  emit(ctx, a64_fadd(t, S0, S0, S1)); break;
			case OSub:  emit(ctx, a64_fsub(t, S0, S0, S1)); break;
			case OMul:  emit(ctx, a64_fmul(t, S0, S0, S1)); break;
			case OSDiv: emit(ctx, a64_fdiv(t, S0, S0, S1)); break;
			default: return 0;
		}

		store_reg(ctx, d, S0);
		return 1;
	}

	load_reg(ctx, op->p2, S0);
	load_reg(ctx, op->p3, S1);

	switch( op->op ) {
		case OAdd:  emit(ctx, a64_add_reg(w, S0, S0, S1)); break;
		case OSub:  emit(ctx, a64_sub_reg(w, S0, S0, S1)); break;
		case OMul:  emit(ctx, a64_mul(w, S0, S0, S1)); break;
		case OSDiv: emit(ctx, a64_sdiv(w, S0, S0, S1)); break;
		case OAnd:  emit(ctx, a64_and_reg(w, S0, S0, S1)); break;
		case OOr:   emit(ctx, a64_orr_reg(w, S0, S0, S1)); break;
		case OXor:  emit(ctx, a64_eor_reg(w, S0, S0, S1)); break;
		case OShl:  emit(ctx, a64_shift_reg(w, A64_SHIFT_LSLV, S0, S0, S1)); break;
		case OSShr: emit(ctx, a64_shift_reg(w, A64_SHIFT_ASRV, S0, S0, S1)); break;
		case OUShr: emit(ctx, a64_shift_reg(w, A64_SHIFT_LSRV, S0, S0, S1)); break;

		/**
			Division answers what HashLink means by it without any help: sdiv gives 0 for a divide by
			zero, which is what the bytecode says, and INT_MIN divided by -1 wraps to INT_MIN, which
			is what its own jit produces by multiplying instead. The remainder needs one correction,
			since a % 0 comes out as a here and HashLink says 0. Done with a select rather than a
			branch, so the common path has nothing to predict.
		*/
		case OSMod:
			emit(ctx, a64_sdiv(w, S2, S0, S1));
			emit(ctx, a64_msub(w, S0, S2, S1, S0));
			emit(ctx, a64_cmp_imm(w, S1, 0));
			emit(ctx, a64_csel(w, S0, A64_ZR, S0, A64_EQ));
			break;

		default: return 0;
	}

	store_reg(ctx, d, S0);
	return 1;
}

/**
	Compiles a comparison that is also a jump, which is the only kind HashLink has.

	There is no instruction here that turns a comparison into a boolean either, so the two sides
	agree about that and a condition is control flow on both.

	@param index Which opcode this is, since a jump is measured from the one after it.
	@return Whether it is one this knows.
*/
static int compare_jump( jit_ctx *ctx, hl_opcode *op, int index ) {
	int target = index + 1 + op->p3;
	int cond;

	load_reg(ctx, op->p1, S0);
	load_reg(ctx, op->p2, S1);

	if( ctx->regs[op->p1].is_float ) {
		emit(ctx, a64_fcmp(fp_type(ctx, op->p1), S0, S1));

		/**
			MI and LS rather than LT and LE, which is what makes a comparison against NaN answer
			false instead of true: an unordered result sets the carry, and LT reads that as less
			than where MI does not.
		*/
		switch( op->op ) {
			case OJSLt:   cond = A64_MI; break;
			case OJSGte:  cond = A64_GE; break;
			case OJSGt:   cond = A64_GT; break;
			case OJSLte:  cond = A64_LS; break;
			case OJEq:    cond = A64_EQ; break;
			case OJNotEq: cond = A64_NE; break;

			/**
				Not less than is the inverse of less than, which on this architecture is the condition
				with its bottom bit flipped. For a float that is what makes a comparison against NaN
				answer the way HashLink says: unordered is not less than, so the inverse is taken.
			*/
			case OJNotLt:  cond = A64_MI ^ 1; break;
			case OJNotGte: cond = A64_GE ^ 1; break;
			case OJULt:    cond = A64_CC; break;
			case OJUGte:   cond = A64_CS; break;
			default: return 0;
		}
	} else {
		emit(ctx, a64_cmp_reg(wide(ctx, op->p1), S0, S1));

		switch( op->op ) {
			case OJSLt:   cond = A64_LT; break;
			case OJSGte:  cond = A64_GE; break;
			case OJSGt:   cond = A64_GT; break;
			case OJSLte:  cond = A64_LE; break;
			case OJEq:    cond = A64_EQ; break;
			case OJNotEq: cond = A64_NE; break;
			case OJULt:   cond = A64_CC; break;
			case OJUGte:  cond = A64_CS; break;
			case OJNotLt:  cond = A64_GE; break;
			case OJNotGte: cond = A64_LT; break;
			default: return 0;
		}
	}

	emit_jump(ctx, a64_bcond(cond, 0), target);
	return 1;
}

/**
	Compiles one instruction.

	@param index Which opcode this is, since a jump is measured in opcodes from the one after it.
	@return Whether it was compiled. False means this jit does not know the opcode yet, which fails
	        the whole module and leaves it to be interpreted.
*/
static int compile_op( jit_ctx *ctx, hl_function *f, hl_opcode *op, int index ) {
	(void)f;

	switch( op->op ) {
		case OMov:
			load_reg(ctx, op->p2, S0);
			store_reg(ctx, op->p1, S0);
			return 1;

		case OInt:
			emit_imm32(ctx, S0, ctx->m->code->ints[op->p2]);
			store_reg(ctx, op->p1, S0);
			return 1;

		case OFloat:
			emit_float(ctx, op->p1, ctx->m->code->floats[op->p2]);
			return 1;

		case OBool:
			emit_imm32(ctx, S0, op->p2 ? 1 : 0);
			store_reg(ctx, op->p1, S0);
			return 1;

		case ONull:
			emit(ctx, a64_mov_reg(1, S0, A64_ZR));
			store_reg(ctx, op->p1, S0);
			return 1;

		/** A marker for where a jump lands, which is bookkeeping rather than work. */
		case OLabel:
		case ONop:
			return 1;

		case OAdd:
		case OSub:
		case OMul:
		case OSDiv:
		case OSMod:
		case OShl:
		case OSShr:
		case OUShr:
		case OAnd:
		case OOr:
		case OXor:
			return arith(ctx, op);

		case ONeg:
			load_reg(ctx, op->p2, S0);

			if( ctx->regs[op->p1].is_float )
				emit(ctx, a64_fneg(fp_type(ctx, op->p1), S0, S0));
			else
				emit(ctx, a64_neg(wide(ctx, op->p1), S0, S0));

			store_reg(ctx, op->p1, S0);
			return 1;

		/** Logical rather than bitwise: HashLink's ONot is on a Bool, so it answers 1 or 0. */
		case ONot:
			load_reg(ctx, op->p2, S0);
			emit(ctx, a64_cmp_imm(wide(ctx, op->p2), S0, 0));
			emit(ctx, a64_cset(wide(ctx, op->p1), S0, A64_EQ));
			store_reg(ctx, op->p1, S0);
			return 1;

		case OIncr:
		case ODecr:
			load_reg(ctx, op->p1, S0);

			if( op->op == OIncr )
				emit(ctx, a64_add_imm(wide(ctx, op->p1), S0, S0, 1));
			else
				emit(ctx, a64_sub_imm(wide(ctx, op->p1), S0, S0, 1));

			store_reg(ctx, op->p1, S0);
			return 1;

		case OJAlways:
			emit_jump(ctx, a64_b(0), index + 1 + op->p1);
			return 1;

		/**
			A test against zero, which is one instruction rather than a compare and a branch. Null
			and false are both zero here, so the same pair covers all four.
		*/
		case OJTrue:
		case OJNotNull:
			load_reg(ctx, op->p1, S0);
			emit_jump(ctx, a64_cbnz(wide(ctx, op->p1), S0, 0), index + 1 + op->p2);
			return 1;

		case OJFalse:
		case OJNull:
			load_reg(ctx, op->p1, S0);
			emit_jump(ctx, a64_cbz(wide(ctx, op->p1), S0, 0), index + 1 + op->p2);
			return 1;

		case OJSLt:
		case OJSGte:
		case OJSGt:
		case OJSLte:
		case OJEq:
		case OJNotEq:
			return compare_jump(ctx, op, index);

		case ONullCheck: {
			int at;

			load_reg(ctx, op->p1, S0);

			at = ctx->len;
			emit(ctx, a64_cbnz(1, S0, 0));
			emit_call(ctx, (void *)(size_t)&hl_null_access);
			ctx->buf[at] = a64_cbnz(1, S0, ctx->len - at);
			return 1;
		}

		/**
			A global lives at a fixed place in memory that exists before any of this is compiled, so
			the address is built into the instruction rather than looked up.
		*/
		case OGetGlobal:
			emit_imm64(ctx, S1, (unsigned long long)(size_t)(ctx->m->globals_data + ctx->m->globals_indexes[op->p2]));

			if( !mem_access(ctx, S1, 0, op->p1, S0, 0) )
				return 0;

			store_reg(ctx, op->p1, S0);
			return 1;

		case OSetGlobal:
			load_reg(ctx, op->p2, S0);
			emit_imm64(ctx, S1, (unsigned long long)(size_t)(ctx->m->globals_data + ctx->m->globals_indexes[op->p1]));
			return mem_access(ctx, S1, 0, op->p2, S0, 1);

		case OField:
		case OGetThis: {
			int obj = op->op == OField ? op->p2 : 0;
			int field = op->op == OField ? op->p3 : op->p2;
			hl_type *t = ctx->regs[obj].t;
			int off;

			/**
				A structural type keeps a pointer to wherever the underlying object holds each field,
				or nothing at all when that object has no such field. So both answers are emitted:
				read straight through the pointer when there is one, ask the runtime by name when
				there is not.

				Each branch stores the result itself rather than meeting at a shared register, because
				the fast path leaves a float in the scratch bank and a call leaves one where a return
				value goes.
			*/
			if( t->kind == HVIRTUAL ) {
				int slow, over;

				load_reg(ctx, obj, S1);
				emit(ctx, a64_ldr_imm(A64_X, S2, S1, (unsigned int)(sizeof(vvirtual) / 8 + field)));

				slow = ctx->len;
				emit(ctx, a64_cbz(1, S2, 0));

				if( !mem_access(ctx, S2, 0, op->p1, S0, 0) )
					return 0;

				store_reg(ctx, op->p1, S0);

				over = ctx->len;
				emit(ctx, a64_b(0));
				ctx->buf[slow] = a64_cbz(1, S2, ctx->len - slow);

				load_reg(ctx, obj, 0);
				emit_imm32(ctx, 1, t->virt->fields[field].hashed_name);

				if( !helper_is_short(ctx->regs[op->p1].t) )
					emit_imm64(ctx, 2, (unsigned long long)(size_t)ctx->regs[op->p1].t);

				emit_call(ctx, get_helper(ctx->regs[op->p1].t));
				store_reg(ctx, op->p1, 0);

				ctx->buf[over] = a64_b(ctx->len - over);
				return 1;
			}

			off = field_offset(t, field);

			if( off < 0 )
				return 0;

			load_reg(ctx, obj, S1);

			if( !mem_access(ctx, S1, off, op->p1, S0, 0) )
				return 0;

			store_reg(ctx, op->p1, S0);
			return 1;
		}

		case OSetField:
		case OSetThis: {
			int obj = op->op == OSetField ? op->p1 : 0;
			int field = op->op == OSetField ? op->p2 : op->p1;
			int value = op->op == OSetField ? op->p3 : op->p2;
			hl_type *t = ctx->regs[obj].t;
			int off;

			/** The same two answers the reading side has, for the same reason. */
			if( t->kind == HVIRTUAL ) {
				hl_type *vt = ctx->regs[value].t;
				int slow, over;

				load_reg(ctx, obj, S1);
				emit(ctx, a64_ldr_imm(A64_X, S2, S1, (unsigned int)(sizeof(vvirtual) / 8 + field)));

				slow = ctx->len;
				emit(ctx, a64_cbz(1, S2, 0));

				load_reg(ctx, value, S0);

				if( !mem_access(ctx, S2, 0, value, S0, 1) )
					return 0;

				over = ctx->len;
				emit(ctx, a64_b(0));
				ctx->buf[slow] = a64_cbz(1, S2, ctx->len - slow);

				load_reg(ctx, obj, 0);
				emit_imm32(ctx, 1, t->virt->fields[field].hashed_name);

				if( helper_is_short(vt) ) {
					load_reg(ctx, value, vt->kind == HF32 || vt->kind == HF64 ? 0 : 2);
				} else {
					emit_imm64(ctx, 2, (unsigned long long)(size_t)vt);
					load_reg(ctx, value, 3);
				}

				emit_call(ctx, set_helper(vt));

				ctx->buf[over] = a64_b(ctx->len - over);
				return 1;
			}

			off = field_offset(t, field);

			if( off < 0 )
				return 0;

			load_reg(ctx, obj, S1);
			load_reg(ctx, value, S0);
			return mem_access(ctx, S1, off, value, S0, 1);
		}

		/** Allocation, which is a call into the collector with the type as its argument. */
		case ONew: {
			hl_type *t = ctx->regs[op->p1].t;

			switch( t->kind ) {
				case HOBJ:
				case HSTRUCT:
					emit_imm64(ctx, 0, (unsigned long long)(size_t)t);
					emit_call(ctx, (void *)(size_t)&hl_alloc_obj);
					break;

				case HDYNOBJ:
					emit_call(ctx, (void *)(size_t)&hl_alloc_dynobj);
					break;

				case HVIRTUAL:
					emit_imm64(ctx, 0, (unsigned long long)(size_t)t);
					emit_call(ctx, (void *)(size_t)&hl_alloc_virtual);
					break;

				default:
					return 0;
			}

			store_reg(ctx, op->p1, 0);
			return 1;
		}

		/**
			Between the two banks, rounding towards zero on the way in, which is what Haxe means by
			Std.int. A dynamic on either side is a call and is not one of these yet.
		*/
		case OToSFloat:
			if( ctx->regs[op->p1].is_float && !ctx->regs[op->p2].is_float ) {
				load_reg(ctx, op->p2, S0);
				emit(ctx, a64_scvtf(wide(ctx, op->p2), fp_type(ctx, op->p1), S0, S0));
				store_reg(ctx, op->p1, S0);
				return 1;
			}

			if( ctx->regs[op->p1].is_float && ctx->regs[op->p2].is_float ) {
				load_reg(ctx, op->p2, S0);

				if( ctx->regs[op->p1].size != ctx->regs[op->p2].size )
					emit(ctx, ctx->regs[op->p1].size == 8 ? a64_fcvt_s2d(S0, S0) : a64_fcvt_d2s(S0, S0));

				store_reg(ctx, op->p1, S0);
				return 1;
			}

			return 0;

		/**
			To an integer, from a float or from an integer of another width.

			Rounding towards zero is what Haxe means by Std.int, and it is what this instruction does
			by definition here, where x86 has to set a rounding mode around the conversion and put it
			back afterwards.
		*/
		case OToInt:
			if( ctx->regs[op->p1].is_float )
				return 0;

			if( ctx->regs[op->p2].is_float ) {
				load_reg(ctx, op->p2, S0);
				emit(ctx, a64_fcvtzs(wide(ctx, op->p1), fp_type(ctx, op->p2), S0, S0));
				store_reg(ctx, op->p1, S0);
				return 1;
			}

			load_reg(ctx, op->p2, S0);

			/** Narrowing happens by storing at the destination's width; widening has to take the sign. */
			if( ctx->regs[op->p1].size == 8 && ctx->regs[op->p2].size <= 4 )
				emit(ctx, a64_sxtw(S0, S0));

			store_reg(ctx, op->p1, S0);
			return 1;

		/**
			Entering a try.

			The context goes on the frame, is linked into the thread's chain of them, and setjmp
			marks the place. Coming back through it a second time is a throw arriving, and then the
			exception is read out of the thread and control goes to the handler.

			The thread is asked for twice on purpose. A longjmp restores the callee-saved registers
			and nothing else, so anything held in a scratch register across setjmp is gone by the time
			the second return happens, and reusing it would read whatever the throwing code left
			there.
		*/
		case OTrap: {
			int off = ctx->trap_off + ctx->trap_at * (int)sizeof(hl_trap_ctx);
			int cont;

			ctx->trap_at++;

			emit_call(ctx, (void *)(size_t)&hl_get_thread);
			emit(ctx, a64_mov_reg(1, S2, 0));
			emit_fp_offset(ctx, off, S1);

			emit(ctx, a64_str_imm(A64_X, A64_ZR, S1, (unsigned int)(offsetof(hl_trap_ctx, tcheck) / 8)));
			emit(ctx, a64_ldr_imm(A64_X, S0, S2, (unsigned int)(offsetof(hl_thread_info, trap_current) / 8)));
			emit(ctx, a64_str_imm(A64_X, S0, S1, (unsigned int)(offsetof(hl_trap_ctx, prev) / 8)));
			emit(ctx, a64_str_imm(A64_X, S1, S2, (unsigned int)(offsetof(hl_thread_info, trap_current) / 8)));

			/** The buffer is the first thing in the context, so its address is the context's. */
			emit(ctx, a64_mov_reg(1, 0, S1));
			emit_call(ctx, (void *)(size_t)&setjmp);

			cont = ctx->len;
			emit(ctx, a64_cbz(0, 0, 0));

			emit_call(ctx, (void *)(size_t)&hl_get_thread);
			emit(ctx, a64_ldr_imm(A64_X, S0, 0, (unsigned int)(offsetof(hl_thread_info, exc_value) / 8)));
			store_reg(ctx, op->p1, S0);
			emit_jump(ctx, a64_b(0), index + 1 + op->p2);

			ctx->buf[cont] = a64_cbz(0, 0, ctx->len - cont);
			return 1;
		}

		/** Leaving a try, which is unlinking the context the matching OTrap put in the chain. */
		case OEndTrap:
			emit_call(ctx, (void *)(size_t)&hl_get_thread);
			emit(ctx, a64_ldr_imm(A64_X, S0, 0, (unsigned int)(offsetof(hl_thread_info, trap_current) / 8)));
			emit(ctx, a64_ldr_imm(A64_X, S0, S0, (unsigned int)(offsetof(hl_trap_ctx, prev) / 8)));
			emit(ctx, a64_str_imm(A64_X, S0, 0, (unsigned int)(offsetof(hl_thread_info, trap_current) / 8)));
			return 1;

		/** Both leave through the runtime and neither comes back, so nothing follows them. */
		case OThrow:
			load_reg(ctx, op->p1, 0);
			emit_call(ctx, (void *)(size_t)&hl_throw);
			return 1;

		case ORethrow:
			load_reg(ctx, op->p1, 0);
			emit_call(ctx, (void *)(size_t)&hl_rethrow);
			return 1;

		/**
			Boxing, which reads the value through its home rather than out of a register, since what
			the runtime does with it depends on the type it is told.

			A null pointer boxes to null rather than to a dynamic holding null, which is what
			hashlink's own jit arranges too, and the reason for the branch.
		*/
		case OToDyn: {
			int at = -1;

			if( hl_is_ptr(ctx->regs[op->p2].t) ) {
				load_reg(ctx, op->p2, S1);
				at = ctx->len;
				emit(ctx, a64_cbnz(1, S1, 0));
				emit(ctx, a64_mov_reg(1, 0, A64_ZR));
			}

			if( at >= 0 ) {
				int over = ctx->len;
				emit(ctx, a64_b(0));
				ctx->buf[at] = a64_cbnz(1, S1, ctx->len - at);

				emit_addr_of(ctx, op->p2, 0);
				emit_imm64(ctx, 1, (unsigned long long)(size_t)ctx->regs[op->p2].t);
				emit_call(ctx, (void *)(size_t)&hl_make_dyn);

				ctx->buf[over] = a64_b(ctx->len - over);
			} else {
				emit_addr_of(ctx, op->p2, 0);
				emit_imm64(ctx, 1, (unsigned long long)(size_t)ctx->regs[op->p2].t);
				emit_call(ctx, (void *)(size_t)&hl_make_dyn);
			}

			store_reg(ctx, op->p1, 0);
			return 1;
		}

		case OSafeCast:
			emit_addr_of(ctx, op->p2, 0);
			emit_imm64(ctx, 1, (unsigned long long)(size_t)ctx->regs[op->p2].t);

			if( !helper_is_short(ctx->regs[op->p1].t) )
				emit_imm64(ctx, 2, (unsigned long long)(size_t)ctx->regs[op->p1].t);

			emit_call(ctx, cast_helper(ctx->regs[op->p1].t));
			store_reg(ctx, op->p1, 0);
			return 1;

		case ODynGet:
			load_reg(ctx, op->p2, 0);
			/** The string pool is utf-8, so this is hl_hash_utf8 and not the wide hl_hash_gen. */
			emit_imm32(ctx, 1, hl_hash_utf8(ctx->m->code->strings[op->p3]));

			if( !helper_is_short(ctx->regs[op->p1].t) )
				emit_imm64(ctx, 2, (unsigned long long)(size_t)ctx->regs[op->p1].t);

			emit_call(ctx, get_helper(ctx->regs[op->p1].t));
			store_reg(ctx, op->p1, 0);
			return 1;

		/** A closure carrying its receiver, which the runtime allocates given the two and a type. */
		case OInstanceClosure:
			emit_imm64(ctx, 0, (unsigned long long)(size_t)ctx->m->ctx.functions_types[op->p2]);

			if( !emit_func_addr(ctx, op->p2, 1) )
				return 0;

			load_reg(ctx, op->p3, 2);
			emit_call(ctx, (void *)(size_t)&hl_alloc_closure_ptr);
			store_reg(ctx, op->p1, 0);
			return 1;

		case OCall0:
			return emit_hl_call(ctx, op->p1, op->p2, NULL, 0);

		case OCall1: {
			int args[1];
			args[0] = op->p3;
			return emit_hl_call(ctx, op->p1, op->p2, args, 1);
		}

		/**
			Four operands, so the fourth is the value sitting in `extra` rather than a list it points
			at. Five and more put p3 first and the rest in a list, which is why these read differently
			from one another rather than being one case with a count.
		*/
		case OCall2: {
			int args[2];
			args[0] = op->p3;
			args[1] = (int)(int_val)op->extra;
			return emit_hl_call(ctx, op->p1, op->p2, args, 2);
		}

		case OCall3: {
			int args[3];
			args[0] = op->p3;
			args[1] = op->extra[0];
			args[2] = op->extra[1];
			return emit_hl_call(ctx, op->p1, op->p2, args, 3);
		}

		case OCall4: {
			int args[4];
			args[0] = op->p3;
			args[1] = op->extra[0];
			args[2] = op->extra[1];
			args[3] = op->extra[2];
			return emit_hl_call(ctx, op->p1, op->p2, args, 4);
		}

		case OCallN:
			return emit_hl_call(ctx, op->p1, op->p2, op->extra, op->p3);

		case OCallMethod:
			return emit_method_call(ctx, op->p1, op->extra[0], op->p2, op->extra, op->p3);

		/**
			The same dispatch with the receiver implied. It is register 0, and it is also the first
			argument, so the list is one longer than the bytecode wrote.
		*/
		case OCallThis: {
			int args[16];
			int i;

			if( op->p3 + 1 > (int)(sizeof(args) / sizeof(args[0])) )
				return 0;

			args[0] = 0;
			for(i=0;i<op->p3;i++)
				args[i + 1] = op->extra[i];

			return emit_method_call(ctx, op->p1, 0, op->p2, args, op->p3 + 1);
		}

		/**
			Calling a closure, which may or may not be carrying a receiver, and only says which at run
			time. So both ways of arranging the arguments are emitted and one is jumped over.
		*/
		case OCallClosure: {
			int over, plain;

			/**
				A closure held as a dynamic goes through the runtime instead. Its arguments are already
				dynamics and have to be handed over as an array, so room for them is taken from the
				stack, filled, and given back after. The result is a dynamic too, and casting it to
				whatever the destination is wants a pointer to it, which is why it is put back on the
				stack before the cast rather than kept in a register.
			*/
			if( ctx->regs[op->p2].t->kind != HFUN ) {
				int space = ((op->p3 * 8) + 15) & ~15;
				int i;

				if( space == 0 )
					space = 16;

				adjust_sp(ctx, space, 0);
				emit(ctx, a64_mov_sp(1, S1, A64_SP));

				for(i=0;i<op->p3;i++) {
					load_reg(ctx, op->extra[i], S0);
					emit(ctx, a64_str_imm(A64_X, S0, S1, (unsigned int)i));
				}

				load_reg(ctx, op->p2, 0);
				emit(ctx, a64_mov_reg(1, 1, S1));
				emit_imm32(ctx, 2, op->p3);
				emit_call(ctx, (void *)(size_t)&hl_dyn_call);

				emit(ctx, a64_mov_sp(1, S1, A64_SP));
				emit(ctx, a64_str_imm(A64_X, 0, S1, 0));
				emit(ctx, a64_mov_reg(1, 0, S1));
				emit_imm64(ctx, 1, (unsigned long long)(size_t)&hlt_dyn);

				if( !helper_is_short(ctx->regs[op->p1].t) )
					emit_imm64(ctx, 2, (unsigned long long)(size_t)ctx->regs[op->p1].t);

				emit_call(ctx, cast_helper(ctx->regs[op->p1].t));
				adjust_sp(ctx, space, 1);

				if( ctx->regs[op->p1].size != 0 )
					store_reg(ctx, op->p1, 0);

				return 1;
			}

			load_reg(ctx, op->p2, S1);
			emit(ctx, a64_ldr_imm(A64_X, S0, S1, (unsigned int)(offsetof(vclosure, fun) / 8)));
			emit(ctx, a64_ldr_imm(A64_W, S2, S1, (unsigned int)(offsetof(vclosure, hasValue) / 4)));

			plain = ctx->len;
			emit(ctx, a64_cbz(0, S2, 0));

			emit(ctx, a64_ldr_imm(A64_X, 0, S1, (unsigned int)(offsetof(vclosure, value) / 8)));

			if( !pass_args_from(ctx, op->extra, op->p3, 1) )
				return 0;

			emit(ctx, a64_blr(S0));

			over = ctx->len;
			emit(ctx, a64_b(0));

			ctx->buf[plain] = a64_cbz(0, S2, ctx->len - plain);

			if( !pass_args_from(ctx, op->extra, op->p3, 0) )
				return 0;

			emit(ctx, a64_blr(S0));
			ctx->buf[over] = a64_b(ctx->len - over);

			if( ctx->regs[op->p1].size != 0 )
				store_reg(ctx, op->p1, 0);

			return 1;
		}

		/**
			Constants that are addresses of things the module already holds, so each is a materialised
			pointer rather than a lookup. The string pool is wide and the byte pool is not, and which
			pool the bytes come from depends on how old the bytecode is.
		*/
		case OString:
			emit_imm64(ctx, S0, (unsigned long long)(size_t)hl_get_ustring(ctx->m->code, op->p2));
			store_reg(ctx, op->p1, S0);
			return 1;

		case OBytes: {
			const void *at = ctx->m->code->version >= 5
				? (const void *)(ctx->m->code->bytes + ctx->m->code->bytes_pos[op->p2])
				: (const void *)ctx->m->code->strings[op->p2];

			emit_imm64(ctx, S0, (unsigned long long)(size_t)at);
			store_reg(ctx, op->p1, S0);
			return 1;
		}

		case OType:
			emit_imm64(ctx, S0, (unsigned long long)(size_t)(ctx->m->code->types + op->p2));
			store_reg(ctx, op->p1, S0);
			return 1;

		/** A value's own type is the first thing in it, and null has no first thing, so null is void. */
		case OGetType: {
			int has, over;

			load_reg(ctx, op->p2, S1);

			has = ctx->len;
			emit(ctx, a64_cbnz(1, S1, 0));
			emit_imm64(ctx, S0, (unsigned long long)(size_t)&hlt_void);

			over = ctx->len;
			emit(ctx, a64_b(0));

			ctx->buf[has] = a64_cbnz(1, S1, ctx->len - has);
			emit(ctx, a64_ldr_imm(A64_X, S0, S1, 0));
			ctx->buf[over] = a64_b(ctx->len - over);

			store_reg(ctx, op->p1, S0);
			return 1;
		}

		/** The kind is the first field of a type, and a type is the first field of a value. */
		case OGetTID:
			load_reg(ctx, op->p2, S1);
			emit(ctx, a64_ldr_imm(A64_W, S0, S1, 0));
			store_reg(ctx, op->p1, S0);
			return 1;

		/**
			How many elements an array holds, which sits after the type and the element type in a
			varray and after the type and one int in an abstract one.
		*/
		case OArraySize:
			load_reg(ctx, op->p2, S1);
			emit(ctx, a64_ldr_imm(A64_W, S0, S1,
				(unsigned int)((ctx->regs[op->p2].t->kind == HABSTRACT ? sizeof(void *) + 4 : sizeof(void *) * 2) / 4)));
			store_reg(ctx, op->p1, S0);
			return 1;

		/** A reference to one of the function's own registers, which is its home in the frame. */
		case ORef:
			emit_addr_of(ctx, op->p2, S0);
			store_reg(ctx, op->p1, S0);
			return 1;

		case OUnref:
			load_reg(ctx, op->p2, S1);

			if( !mem_access(ctx, S1, 0, op->p1, S0, 0) )
				return 0;

			store_reg(ctx, op->p1, S0);
			return 1;

		case OSetref:
			load_reg(ctx, op->p1, S1);
			load_reg(ctx, op->p2, S0);
			return mem_access(ctx, S1, 0, op->p2, S0, 1);

		/** A cast the bytecode has already decided is safe, so it is a move. */
		case OUnsafeCast:
			load_reg(ctx, op->p2, S0);
			store_reg(ctx, op->p1, S0);
			return 1;

		case OToUFloat:
			load_reg(ctx, op->p2, S0);
			emit(ctx, a64_ucvtf(wide(ctx, op->p2), fp_type(ctx, op->p1), S0, S0));
			store_reg(ctx, op->p1, S0);
			return 1;

		/** A hint to the memory system, which is allowed to be nothing at all. */
		case OPrefetch:
			return 1;

		/** Reached only where the bytecode has already gone wrong, so it stops rather than continues. */
		case OAssert:
			emit_call(ctx, (void *)(size_t)&hl_assert);
			return 1;

		/**
			Memory reached as a base and a byte offset, which is what hl.Bytes and a native array are.

			The offset is an i32 and the addressing mode extends it, so the extension is part of the
			instruction rather than something emitted before it. Signed, because HashLink's offsets are
			signed ints.
		*/
		case OGetI8:
		case OGetI16:
		case OGetMem: {
			int width = op->op == OGetI8 ? A64_B : (op->op == OGetI16 ? A64_H : width_of(ctx->regs[op->p1].size));

			load_reg(ctx, op->p2, S1);
			load_reg(ctx, op->p3, S2);

			if( ctx->regs[op->p1].is_float && op->op == OGetMem )
				emit(ctx, a64_ls_reg(width, 1, A64_LS_LDR, S0, S1, S2, A64_EXT_SXTW, 0));
			else
				emit(ctx, a64_ls_reg(width, 0, A64_LS_LDR, S0, S1, S2, A64_EXT_SXTW, 0));

			store_reg(ctx, op->p1, S0);
			return 1;
		}

		case OSetI8:
		case OSetI16:
		case OSetMem: {
			int width = op->op == OSetI8 ? A64_B : (op->op == OSetI16 ? A64_H : width_of(ctx->regs[op->p3].size));

			load_reg(ctx, op->p1, S1);
			load_reg(ctx, op->p2, S2);
			load_reg(ctx, op->p3, S0);

			if( ctx->regs[op->p3].is_float && op->op == OSetMem )
				emit(ctx, a64_ls_reg(width, 1, A64_LS_STR, S0, S1, S2, A64_EXT_SXTW, 0));
			else
				emit(ctx, a64_ls_reg(width, 0, A64_LS_STR, S0, S1, S2, A64_EXT_SXTW, 0));

			return 1;
		}

		/**
			An element of an array, which is the elements themselves laid out after the varray header,
			indexed by the element's own width.

			An abstract array is a different shape and its elements may be whole structures, which is a
			copy rather than a load, so it is refused rather than half done.
		*/
		case OGetArray: {
			vreg *dst = ctx->regs + op->p1;

			if( ctx->regs[op->p2].t->kind == HABSTRACT )
				return 0;

			load_reg(ctx, op->p2, S1);
			load_reg(ctx, op->p3, S2);
			emit(ctx, a64_add_imm(1, S1, S1, (unsigned int)sizeof(varray)));

			emit(ctx, a64_ls_reg(width_of(dst->size), dst->is_float ? 1 : 0, A64_LS_LDR, S0, S1, S2, A64_EXT_SXTW, 1));
			store_reg(ctx, op->p1, S0);
			return 1;
		}

		case OSetArray: {
			vreg *src = ctx->regs + op->p3;

			if( ctx->regs[op->p1].t->kind == HABSTRACT )
				return 0;

			load_reg(ctx, op->p1, S1);
			load_reg(ctx, op->p2, S2);
			emit(ctx, a64_add_imm(1, S1, S1, (unsigned int)sizeof(varray)));
			load_reg(ctx, op->p3, S0);

			emit(ctx, a64_ls_reg(width_of(src->size), src->is_float ? 1 : 0, A64_LS_STR, S0, S1, S2, A64_EXT_SXTW, 1));
			return 1;
		}

		/** Unsigned division, and its remainder, which needs the same correction the signed one does. */
		case OUDiv:
		case OUMod: {
			int w = wide(ctx, op->p1);

			load_reg(ctx, op->p2, S0);
			load_reg(ctx, op->p3, S1);

			if( op->op == OUDiv ) {
				emit(ctx, a64_udiv(w, S0, S0, S1));
			} else {
				emit(ctx, a64_udiv(w, S2, S0, S1));
				emit(ctx, a64_msub(w, S0, S2, S1, S0));
				emit(ctx, a64_cmp_imm(w, S1, 0));
				emit(ctx, a64_csel(w, S0, A64_ZR, S0, A64_EQ));
			}

			store_reg(ctx, op->p1, S0);
			return 1;
		}

		case OJULt:
		case OJUGte:
		case OJNotLt:
		case OJNotGte:
			return compare_jump(ctx, op, index);

		/**
			An enum value: the type, then the construct index, then that construct's fields at offsets
			the type carries.
		*/
		case OEnumAlloc:
			emit_imm64(ctx, 0, (unsigned long long)(size_t)ctx->regs[op->p1].t);
			emit_imm32(ctx, 1, op->p2);
			emit_call(ctx, (void *)(size_t)&hl_alloc_enum);
			store_reg(ctx, op->p1, 0);
			return 1;

		case OEnumIndex:
			load_reg(ctx, op->p2, S1);
			emit(ctx, a64_ldr_imm(A64_W, S0, S1, (unsigned int)(sizeof(void *) / 4)));
			store_reg(ctx, op->p1, S0);
			return 1;

		case OEnumField: {
			hl_type *t = ctx->regs[op->p2].t;
			hl_enum_construct *c;
			int at = (int)(int_val)op->extra;

			if( t->kind != HENUM )
				return 0;

			c = t->tenum->constructs + op->p3;
			load_reg(ctx, op->p2, S1);

			if( !mem_access(ctx, S1, c->offsets[at], op->p1, S0, 0) )
				return 0;

			store_reg(ctx, op->p1, S0);
			return 1;
		}

		case OSetEnumField: {
			hl_type *t = ctx->regs[op->p1].t;
			hl_enum_construct *c;

			if( t->kind != HENUM )
				return 0;

			c = t->tenum->constructs;
			load_reg(ctx, op->p1, S1);
			load_reg(ctx, op->p3, S0);
			return mem_access(ctx, S1, c->offsets[op->p2], op->p3, S0, 1);
		}

		/**
			Building an enum value in one instruction, which is an allocation followed by a field write
			per argument. The construct decides the offsets, so they are read here and written into the
			instructions rather than worked out at run time.
		*/
		case OMakeEnum: {
			hl_type *t = ctx->regs[op->p1].t;
			hl_enum_construct *c;
			int i;

			if( t->kind != HENUM )
				return 0;

			c = t->tenum->constructs + op->p2;

			emit_imm64(ctx, 0, (unsigned long long)(size_t)t);
			emit_imm32(ctx, 1, op->p2);
			emit_call(ctx, (void *)(size_t)&hl_alloc_enum);
			store_reg(ctx, op->p1, 0);

			for(i=0;i<op->p3;i++) {
				load_reg(ctx, op->p1, S1);
				load_reg(ctx, op->extra[i], S0);

				if( !mem_access(ctx, S1, c->offsets[i], op->extra[i], S0, 1) )
					return 0;
			}

			return 1;
		}

		/**
			Writing a field by name at run time. The short forms take the value where the type would
			have gone, exactly as the reading side does, and for the same reason: the function chosen
			already knows what it is being handed.
		*/
		case ODynSet: {
			hl_type *vt = ctx->regs[op->p3].t;

			load_reg(ctx, op->p1, 0);
			emit_imm32(ctx, 1, hl_hash_utf8(ctx->m->code->strings[op->p2]));

			if( helper_is_short(vt) ) {
				load_reg(ctx, op->p3, vt->kind == HF32 || vt->kind == HF64 ? 0 : 2);
			} else {
				emit_imm64(ctx, 2, (unsigned long long)(size_t)vt);
				load_reg(ctx, op->p3, 3);
			}

			emit_call(ctx, set_helper(vt));
			return 1;
		}

		/** A closure over a function with nothing bound, allocated once rather than per execution. */
		case OStaticClosure: {
			vclosure *c = static_closure(ctx, op->p2);

			if( c == NULL )
				return 0;

			emit_imm64(ctx, S0, (unsigned long long)(size_t)c);
			store_reg(ctx, op->p1, S0);
			return 1;
		}

		/**
			A jump table, which is the one place a PC relative address is right here.

			adr computes from where it sits, and the whole buffer moves as one block, so the distance
			between an instruction and a table four instructions later is the same wherever the block
			ends up. That is not true of anything pointing outside the buffer, which is why every other
			address in this file is built rather than computed.
		*/
		case OSwitch: {
			int over, i;

			load_reg(ctx, op->p1, S0);
			emit(ctx, a64_cmp_imm(0, S0, (unsigned int)op->p2));

			over = ctx->len;
			emit(ctx, a64_bcond(A64_CS, 0));

			/** The table begins three instructions along: the adr, the add and the br. */
			emit(ctx, a64_adr(S1, 3 * 4));
			emit(ctx, a64_addsub_reg(1, 0, 0, S1, S1, S0, A64_LSL, 2));
			emit(ctx, a64_br(S1));

			for(i=0;i<op->p2;i++)
				emit_jump(ctx, a64_b(0), index + 1 + op->extra[i]);

			/** Out of range falls past the table, which is where the default belongs. */
			ctx->buf[over] = a64_bcond(A64_CS, ctx->len - over);
			return 1;
		}

		/**
			Refused rather than half done, and each for its own reason.

			A virtual resolves its fields by name at run time and answers a different way when it has
			none. Making one out of an object walks its fields against the virtual's. Reference data
			and reference offsets are for pointers into the middle of a structure. And OAsm is literal
			machine code the bytecode carries, which cannot be anything but the architecture it was
			written for.
		*/
		/** Wrapping an object as a structural type, which the runtime works out the fields for. */
		case OToVirtual:
			emit_imm64(ctx, 0, (unsigned long long)(size_t)ctx->regs[op->p1].t);
			load_reg(ctx, op->p2, 1);
			emit_call(ctx, (void *)(size_t)&hl_to_virtual);
			store_reg(ctx, op->p1, 0);
			return 1;

		case OVirtualClosure:
		case ORefData:
		case ORefOffset:
		case OAsm:
		case OCatch:
			return 0;

		case ORet:
			if( ctx->regs[op->p1].size != 0 )
				load_reg(ctx, op->p1, 0);

			epilogue(ctx);
			return 1;

		default:
			return 0;
	}
}

/**
	Entering compiled code from C, which the runtime cannot do by itself.

	hl_dyn_call and everything built on it reach a function through hl_setup.static_call, handing over
	the arguments as an array of pointers and a place to put the result. Turning that into a real call
	means putting each argument in the register the ABI wants it in, and which register that is depends
	on the signature, which is only known at run time.

	So a small function is compiled for each signature the first time it is needed, and kept. It is the
	same problem the rest of this file solves and it is solved the same way, which is the reason there
	is no hand written assembly anywhere in here.

	The trampoline is called as tramp(fun, args, out) and does:

	    load each args[i] through its pointer into the register its type belongs in
	    call fun
	    store what came back into out

	x16 holds the argument array while the argument registers are filled, because it is not one of
	them, and the function pointer is kept in the frame because x0 stops being available the moment
	the first argument goes in.
*/
typedef struct hxs_entry hxs_entry;

struct hxs_entry {
	hl_type *t;
	void *code;
	hxs_entry *next;
};

static hxs_entry *hxs_entries = NULL;

/** @return A trampoline for that signature, compiling one if this is the first time it is asked for. */
static void *hxs_entry_for( hl_type *t ) {
	hxs_entry *e;
	jit_ctx ctx;
	hl_type_fun *fun = t->fun;
	int i, ints = 0, floats = 0, frame = 32;
	size_t bytes;
	void *at;

	for(e = hxs_entries; e; e = e->next)
		if( e->t->fun->nargs == fun->nargs && e->t == t )
			return e->code;

	/** Signatures are compared by shape rather than by pointer, since two types can say the same. */
	for(e = hxs_entries; e; e = e->next) {
		hl_type_fun *o = e->t->fun;
		int same = o->nargs == fun->nargs && o->ret->kind == fun->ret->kind;

		for(i=0;same && i<fun->nargs;i++)
			same = o->args[i]->kind == fun->args[i]->kind;

		if( same )
			return e->code;
	}

	memset(&ctx, 0, sizeof(ctx));

	emit(&ctx, a64_sub_imm(1, A64_SP, A64_SP, (unsigned int)frame));
	emit(&ctx, a64_stp(1, A64_PAIR_OFF, A64_FP, A64_LR, A64_SP, 0));
	emit(&ctx, a64_mov_sp(1, A64_FP, A64_SP));

	emit(&ctx, a64_str_imm(A64_X, 0, A64_FP, 2));
	emit(&ctx, a64_str_imm(A64_X, 2, A64_FP, 3));
	emit(&ctx, a64_mov_reg(1, S0, 1));

	for(i=0;i<fun->nargs;i++) {
		hl_type *a = fun->args[i];
		int size = hl_type_size(a);
		int isf = a->kind == HF32 || a->kind == HF64;

		if( size == 0 )
			continue;

		if( (isf ? floats : ints) > 7 ) {
			ctx.failed = 1;
			break;
		}

		emit(&ctx, a64_ldr_imm(A64_X, S1, S0, (unsigned int)i));

		if( isf )
			emit(&ctx, a64_ldr_fp_imm(width_of(size), floats++, S1, 0));
		else
			emit(&ctx, a64_ldr_imm(width_of(size), ints++, S1, 0));
	}

	emit(&ctx, a64_ldr_imm(A64_X, S0, A64_FP, 2));
	emit(&ctx, a64_blr(S0));

	if( fun->ret->kind != HVOID ) {
		int size = hl_type_size(fun->ret);
		int isf = fun->ret->kind == HF32 || fun->ret->kind == HF64;

		emit(&ctx, a64_ldr_imm(A64_X, S1, A64_FP, 3));

		if( isf )
			emit(&ctx, a64_str_fp_imm(width_of(size), 0, S1, (unsigned int)(offsetof(vdynamic, v) / size)));
		else
			emit(&ctx, a64_str_imm(width_of(size), 0, S1, (unsigned int)(offsetof(vdynamic, v) / size)));
	}

	emit(&ctx, a64_ldp(1, A64_PAIR_OFF, A64_FP, A64_LR, A64_SP, 0));
	emit(&ctx, a64_add_imm(1, A64_SP, A64_SP, (unsigned int)frame));
	emit(&ctx, a64_ret(A64_LR));

	if( ctx.failed ) {
		free(ctx.buf);
		return NULL;
	}

	bytes = (size_t)ctx.len * sizeof(a64_insn);
	at = hxs_exec_alloc(bytes);

	if( at == NULL ) {
		free(ctx.buf);
		return NULL;
	}

	hxs_exec_unseal(at, bytes);
	memcpy(at, ctx.buf, bytes);
	hxs_exec_seal(at, bytes);
	free(ctx.buf);

	e = (hxs_entry *)malloc(sizeof(hxs_entry));

	if( e == NULL )
		return NULL;

	e->t = t;
	e->code = at;
	e->next = hxs_entries;
	hxs_entries = e;

	return at;
}

/** What hl_setup.static_call points at: enter a compiled function with arguments the runtime arranged. */
static void *hxs_static_call( void *fun, hl_type *t, void **args, vdynamic *out ) {
	void *(*tramp)( void *, void **, vdynamic * ) = (void *(*)( void *, void **, vdynamic * ))hxs_entry_for(t);

	if( tramp == NULL )
		hl_error("no way into a function of this shape");

	return tramp(fun, args, out);
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
		free(ctx->op_pos);
		free(ctx->jumps);
		free(ctx->calls);
		free(ctx->closures);
		free(ctx);
	}
}

void hl_jit_init( jit_ctx *ctx, hl_module *m ) {
	ctx->m = m;
	ctx->len = 0;
	ctx->failed = 0;

	/** Per module rather than per function, since they are all patched together at the end. */
	ctx->ncalls = 0;
	ctx->nclosures = 0;

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

	/**
		One more than there are opcodes, because a jump may name the position after the last one and
		that is a place the bytecode is allowed to point at.
	*/
	if( f->nops + 1 > ctx->cap_ops ) {
		int *grown = (int *)realloc(ctx->op_pos, sizeof(int) * (size_t)(f->nops + 1));

		if( grown == NULL ) {
			ctx->failed = 1;
			return -1;
		}

		ctx->op_pos = grown;
		ctx->cap_ops = f->nops + 1;
	}

	ctx->njumps = 0;
	ctx->trap_at = 0;

	if( !prologue(ctx, f) )
		return -1;

	for(i=0;i<f->nops;i++) {
		ctx->op_pos[i] = ctx->len;

		if( !compile_op(ctx, f, f->ops + i, i) ) {
			/**
				Which opcode was refused, for whoever is extending this. Refusing is a normal answer
				and not an error, so it says nothing unless asked: hxScript reports it once per module
				and interprets, and a build that wants to know which instruction stopped it asks with
				-D HXS_JIT_TRACE.
			*/
#			ifdef HXS_JIT_TRACE
			fprintf(stderr, "hxs jit: no rule for %s, in function %d at %d\n",
				hl_op_name(f->ops[i].op), f->findex, i);
#			endif
			return -1;
		}
	}

	ctx->op_pos[f->nops] = ctx->len;
	patch_jumps(ctx);

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
	int i;

	(void)m;
	(void)previous;

	if( ctx->failed || bytes == 0 )
		return NULL;

	at = hxs_exec_alloc(bytes);
	if( at == NULL )
		return NULL;

	/**
		Now that there is somewhere for the code to live, every call to a function of this module has
		an address at last. module.c has been filling functions_ptrs with offsets as each function
		was compiled, so an address is the base plus one of those, and the four instructions left
		behind at each call site are rewritten to build it.

		Before the copy rather than after, so what lands in executable memory is already finished and
		nothing has to be written through pages that may no longer allow it.
	*/
	for(i=0;i<ctx->ncalls;i++) {
		unsigned long long to = (unsigned long long)(size_t)at
			+ (unsigned long long)(size_t)ctx->m->functions_ptrs[ctx->calls[i].findex];
		int w = ctx->calls[i].at;

		int r = ctx->calls[i].reg;

		ctx->buf[w + 0] = a64_movz(1, r, (unsigned int)(to & 0xFFFF), A64_HW0);
		ctx->buf[w + 1] = a64_movk(1, r, (unsigned int)((to >> 16) & 0xFFFF), A64_HW16);
		ctx->buf[w + 2] = a64_movk(1, r, (unsigned int)((to >> 32) & 0xFFFF), A64_HW32);
		ctx->buf[w + 3] = a64_movk(1, r, (unsigned int)((to >> 48) & 0xFFFF), A64_HW48);
	}

	hxs_exec_unseal(at, bytes);
	memcpy(at, ctx->buf, bytes);
	hxs_exec_seal(at, bytes);

	*codesize = (int)bytes;
	*debug = ctx->debug;

	/**
		The runtime reaches compiled code through this, and nothing else provides it on the VM, where
		every function including the standard library is jitted. An HL/C program has its own, generated
		beside the rest of its C, so this only fills a gap that is there rather than taking one over:
		it is set once and only when nobody has set it already.
	*/
	if( hl_setup.static_call == NULL ) {
		hl_setup.static_call = hxs_static_call;
		hl_setup.static_call_ref = false;
	}

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
