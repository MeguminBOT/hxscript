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
	The AArch64 instruction encoder.

	Every function here takes operands and returns one 32 bit instruction word. Nothing writes to a
	buffer, nothing keeps state, and nothing knows what HashLink is. That is deliberate: it makes the
	whole encoder checkable without an ARM machine and without running anything, by comparing what a
	call returns against what a real assembler produces for the same mnemonic. `test/hl/native/a64/`
	does exactly that, byte for byte, against clang.

	AArch64 is a pleasant target for this. Every instruction is exactly four bytes, so a buffer is an
	array of words rather than a stream of variable length encodings, and patching a branch after the
	fact is writing one field at a known index rather than rediscovering where the instruction began.

	Where a field is named below it is named as the architecture manual names it, so the encoding can
	be read against the manual rather than against somebody's idea of a better name.
*/
#ifndef HXS_A64_H
#define HXS_A64_H

#include <stdint.h>

typedef uint32_t a64_insn;

/** The registers that have a job rather than a number. */
#define A64_ZR		31	/* reads zero, discards writes, in most instructions */
#define A64_SP		31	/* the same encoding as ZR: which one it is depends on the instruction */
#define A64_LR		30	/* the link register, written by BL and read by RET */
#define A64_FP		29	/* the frame pointer */
#define A64_IP0		16	/* intra-procedure-call scratch, which no ABI expects preserved */
#define A64_IP1		17	/* the second of those */

/** Condition codes, in the order the manual numbers them. */
#define A64_EQ		0
#define A64_NE		1
#define A64_CS		2
#define A64_CC		3
#define A64_MI		4
#define A64_PL		5
#define A64_VS		6
#define A64_VC		7
#define A64_HI		8
#define A64_LS		9
#define A64_GE		10
#define A64_LT		11
#define A64_GT		12
#define A64_LE		13
#define A64_AL		14

/** How a shifted-register operand is shifted. */
#define A64_LSL		0
#define A64_LSR		1
#define A64_ASR		2
#define A64_ROR		3

/** The access width of a load or a store, as the size field spells it. */
#define A64_B		0	/* 8 bit */
#define A64_H		1	/* 16 bit */
#define A64_W		2	/* 32 bit, and single precision */
#define A64_X		3	/* 64 bit, and double precision */

/** Which half of a move-wide immediate is being written, as the hw field spells it. */
#define A64_HW0		0
#define A64_HW16	1
#define A64_HW32	2
#define A64_HW48	3

/**
	Moving a constant into a register.

	Three instructions rather than one, because a 64 bit constant does not fit in an instruction that
	is itself 32 bits. MOVZ writes 16 bits and zeroes the rest, MOVN writes the complement, and MOVK
	writes 16 bits and leaves the rest alone, so any constant is one MOVZ followed by up to three
	MOVKs. Choosing the shortest sequence is the caller's job.
*/

static inline a64_insn a64_movz( int is64, int rd, unsigned int imm16, int hw ) {
	return ((a64_insn)(is64 & 1) << 31) | ((a64_insn)2 << 29) | ((a64_insn)0x25 << 23)
		| ((a64_insn)(hw & 3) << 21) | ((a64_insn)(imm16 & 0xFFFF) << 5) | (rd & 31);
}

static inline a64_insn a64_movn( int is64, int rd, unsigned int imm16, int hw ) {
	return ((a64_insn)(is64 & 1) << 31) | ((a64_insn)0 << 29) | ((a64_insn)0x25 << 23)
		| ((a64_insn)(hw & 3) << 21) | ((a64_insn)(imm16 & 0xFFFF) << 5) | (rd & 31);
}

static inline a64_insn a64_movk( int is64, int rd, unsigned int imm16, int hw ) {
	return ((a64_insn)(is64 & 1) << 31) | ((a64_insn)3 << 29) | ((a64_insn)0x25 << 23)
		| ((a64_insn)(hw & 3) << 21) | ((a64_insn)(imm16 & 0xFFFF) << 5) | (rd & 31);
}

/**
	Add and subtract.

	The S forms set the flags, which is what makes CMP and CMN aliases rather than instructions: CMP
	is SUBS into ZR, CMN is ADDS into ZR. There is no separate compare.
*/

/** @param shift12 Whether the immediate is shifted left by 12, which is the only shift on offer. */
static inline a64_insn a64_addsub_imm( int is64, int sub, int flags, int rd, int rn, unsigned int imm12, int shift12 ) {
	return ((a64_insn)(is64 & 1) << 31) | ((a64_insn)(sub & 1) << 30) | ((a64_insn)(flags & 1) << 29)
		| ((a64_insn)0x11 << 24) | ((a64_insn)(shift12 & 1) << 22) | ((a64_insn)(imm12 & 0xFFF) << 10)
		| ((rn & 31) << 5) | (rd & 31);
}

static inline a64_insn a64_add_imm( int is64, int rd, int rn, unsigned int imm12 ) {
	return a64_addsub_imm(is64, 0, 0, rd, rn, imm12, 0);
}

static inline a64_insn a64_sub_imm( int is64, int rd, int rn, unsigned int imm12 ) {
	return a64_addsub_imm(is64, 1, 0, rd, rn, imm12, 0);
}

static inline a64_insn a64_cmp_imm( int is64, int rn, unsigned int imm12 ) {
	return a64_addsub_imm(is64, 1, 1, A64_ZR, rn, imm12, 0);
}

static inline a64_insn a64_addsub_reg( int is64, int sub, int flags, int rd, int rn, int rm, int shift, int amount ) {
	return ((a64_insn)(is64 & 1) << 31) | ((a64_insn)(sub & 1) << 30) | ((a64_insn)(flags & 1) << 29)
		| ((a64_insn)0x0B << 24) | ((a64_insn)(shift & 3) << 22) | ((rm & 31) << 16)
		| ((a64_insn)(amount & 63) << 10) | ((rn & 31) << 5) | (rd & 31);
}

static inline a64_insn a64_add_reg( int is64, int rd, int rn, int rm ) {
	return a64_addsub_reg(is64, 0, 0, rd, rn, rm, A64_LSL, 0);
}

static inline a64_insn a64_sub_reg( int is64, int rd, int rn, int rm ) {
	return a64_addsub_reg(is64, 1, 0, rd, rn, rm, A64_LSL, 0);
}

static inline a64_insn a64_cmp_reg( int is64, int rn, int rm ) {
	return a64_addsub_reg(is64, 1, 1, A64_ZR, rn, rm, A64_LSL, 0);
}

/** Negation, which is subtraction from the zero register and not an instruction of its own. */
static inline a64_insn a64_neg( int is64, int rd, int rm ) {
	return a64_addsub_reg(is64, 1, 0, rd, A64_ZR, rm, A64_LSL, 0);
}

/**
	Bitwise.

	The N bit inverts the second operand, which is what turns AND into BIC, ORR into ORN and EOR into
	EON. MOV between registers is ORR from ZR, and MVN is ORN from ZR, for the same reason.
*/

#define A64_LOGIC_AND	0
#define A64_LOGIC_ORR	1
#define A64_LOGIC_EOR	2
#define A64_LOGIC_ANDS	3

static inline a64_insn a64_logic_reg( int is64, int op, int invert, int rd, int rn, int rm, int shift, int amount ) {
	return ((a64_insn)(is64 & 1) << 31) | ((a64_insn)(op & 3) << 29) | ((a64_insn)0x0A << 24)
		| ((a64_insn)(shift & 3) << 22) | ((a64_insn)(invert & 1) << 21) | ((rm & 31) << 16)
		| ((a64_insn)(amount & 63) << 10) | ((rn & 31) << 5) | (rd & 31);
}

static inline a64_insn a64_and_reg( int is64, int rd, int rn, int rm ) {
	return a64_logic_reg(is64, A64_LOGIC_AND, 0, rd, rn, rm, A64_LSL, 0);
}

static inline a64_insn a64_orr_reg( int is64, int rd, int rn, int rm ) {
	return a64_logic_reg(is64, A64_LOGIC_ORR, 0, rd, rn, rm, A64_LSL, 0);
}

static inline a64_insn a64_eor_reg( int is64, int rd, int rn, int rm ) {
	return a64_logic_reg(is64, A64_LOGIC_EOR, 0, rd, rn, rm, A64_LSL, 0);
}

static inline a64_insn a64_tst_reg( int is64, int rn, int rm ) {
	return a64_logic_reg(is64, A64_LOGIC_ANDS, 0, A64_ZR, rn, rm, A64_LSL, 0);
}

/**
	Register to register move, which is ORR from the zero register.

	Not usable with the stack pointer, in either position. Register 31 means ZR in this encoding and
	not SP, so `a64_mov_reg(1, rd, A64_SP)` is `mov rd, xzr`: it assembles, it runs, and it writes
	zero. `a64_mov_sp` is the one that means the stack pointer.
*/
static inline a64_insn a64_mov_reg( int is64, int rd, int rm ) {
	return a64_logic_reg(is64, A64_LOGIC_ORR, 0, rd, A64_ZR, rm, A64_LSL, 0);
}

/**
	A move where either side may be the stack pointer, which is ADD of zero rather than ORR.

	AArch64 spells register 31 as ZR in some encodings and as SP in others, and the add-immediate
	form is one of the second kind. That is the whole of why `mov x29, sp` is a different instruction
	from `mov x29, x0`, and why writing the obvious one silently zeroes the frame pointer.
*/
static inline a64_insn a64_mov_sp( int is64, int rd, int rn ) {
	return a64_addsub_imm(is64, 0, 0, rd, rn, 0, 0);
}

/** Bitwise not, which is ORN from the zero register. */
static inline a64_insn a64_mvn( int is64, int rd, int rm ) {
	return a64_logic_reg(is64, A64_LOGIC_ORR, 1, rd, A64_ZR, rm, A64_LSL, 0);
}

/**
	Bitfield, which is where the immediate shifts and the extensions live.

	There is no shift-by-immediate instruction. LSL, LSR and ASR by a constant are all aliases of the
	bitfield moves with immr and imms worked out from the amount, and so are the extensions: SXTW is
	SBFM with a width, UXTB is UBFM with a narrower one.
*/

#define A64_BFM_S	0	/* signed, so vacated bits take the sign */
#define A64_BFM_ZERO	1	/* the plain form */
#define A64_BFM_U	2	/* unsigned, so vacated bits are zero */

static inline a64_insn a64_bfm( int is64, int op, int rd, int rn, int immr, int imms ) {
	return ((a64_insn)(is64 & 1) << 31) | ((a64_insn)(op & 3) << 29) | ((a64_insn)0x26 << 23)
		| ((a64_insn)(is64 & 1) << 22) | ((a64_insn)(immr & 63) << 16) | ((a64_insn)(imms & 63) << 10)
		| ((rn & 31) << 5) | (rd & 31);
}

static inline a64_insn a64_lsl_imm( int is64, int rd, int rn, int shift ) {
	int width = is64 ? 64 : 32;
	return a64_bfm(is64, A64_BFM_U, rd, rn, (width - shift) & (width - 1), width - 1 - shift);
}

static inline a64_insn a64_lsr_imm( int is64, int rd, int rn, int shift ) {
	return a64_bfm(is64, A64_BFM_U, rd, rn, shift, is64 ? 63 : 31);
}

static inline a64_insn a64_asr_imm( int is64, int rd, int rn, int shift ) {
	return a64_bfm(is64, A64_BFM_S, rd, rn, shift, is64 ? 63 : 31);
}

/** Sign extension of a 32 bit value into a 64 bit register, which HL needs wherever an i32 meets a pointer. */
static inline a64_insn a64_sxtw( int rd, int rn ) {
	return a64_bfm(1, A64_BFM_S, rd, rn, 0, 31);
}

static inline a64_insn a64_sxtb( int is64, int rd, int rn ) {
	return a64_bfm(is64, A64_BFM_S, rd, rn, 0, 7);
}

static inline a64_insn a64_sxth( int is64, int rd, int rn ) {
	return a64_bfm(is64, A64_BFM_S, rd, rn, 0, 15);
}

static inline a64_insn a64_uxtb( int rd, int rn ) {
	return a64_bfm(0, A64_BFM_U, rd, rn, 0, 7);
}

static inline a64_insn a64_uxth( int rd, int rn ) {
	return a64_bfm(0, A64_BFM_U, rd, rn, 0, 15);
}

/**
	Shifts and division by a register.

	These share one encoding group, which is why the shifts by register are here and the shifts by
	constant are up in the bitfield section instead.
*/

#define A64_SHIFT_LSLV	0
#define A64_SHIFT_LSRV	1
#define A64_SHIFT_ASRV	2
#define A64_SHIFT_RORV	3

static inline a64_insn a64_shift_reg( int is64, int op, int rd, int rn, int rm ) {
	return ((a64_insn)(is64 & 1) << 31) | ((a64_insn)0xD6 << 21) | ((rm & 31) << 16)
		| ((a64_insn)2 << 12) | ((a64_insn)(op & 3) << 10) | ((rn & 31) << 5) | (rd & 31);
}

static inline a64_insn a64_sdiv( int is64, int rd, int rn, int rm ) {
	return ((a64_insn)(is64 & 1) << 31) | ((a64_insn)0xD6 << 21) | ((rm & 31) << 16)
		| ((a64_insn)1 << 11) | ((a64_insn)1 << 10) | ((rn & 31) << 5) | (rd & 31);
}

static inline a64_insn a64_udiv( int is64, int rd, int rn, int rm ) {
	return ((a64_insn)(is64 & 1) << 31) | ((a64_insn)0xD6 << 21) | ((rm & 31) << 16)
		| ((a64_insn)1 << 11) | ((a64_insn)0 << 10) | ((rn & 31) << 5) | (rd & 31);
}

/**
	Multiply.

	MUL is MADD accumulating into the zero register, and the remainder of a division is MSUB, which is
	the whole of why AArch64 needs no modulo instruction: a % b is a - (a / b) * b in two instructions.
*/

static inline a64_insn a64_madd( int is64, int rd, int rn, int rm, int ra ) {
	return ((a64_insn)(is64 & 1) << 31) | ((a64_insn)0x1B << 24) | ((rm & 31) << 16)
		| ((a64_insn)0 << 15) | ((ra & 31) << 10) | ((rn & 31) << 5) | (rd & 31);
}

static inline a64_insn a64_msub( int is64, int rd, int rn, int rm, int ra ) {
	return ((a64_insn)(is64 & 1) << 31) | ((a64_insn)0x1B << 24) | ((rm & 31) << 16)
		| ((a64_insn)1 << 15) | ((ra & 31) << 10) | ((rn & 31) << 5) | (rd & 31);
}

static inline a64_insn a64_mul( int is64, int rd, int rn, int rm ) {
	return a64_madd(is64, rd, rn, rm, A64_ZR);
}

/**
	Loads and stores.

	The unsigned-offset form scales its immediate by the access width, so it reaches far but only at
	aligned multiples. The unscaled form takes a signed byte offset and reaches 256 bytes either way,
	which is what a negative frame offset needs. Both are here because a frame uses both.

	`v` selects the register bank: 0 for x and w, 1 for d and s. That one bit is the only difference
	between storing an integer and storing a double.
*/

#define A64_LS_STR	0
#define A64_LS_LDR	1
#define A64_LS_LDRS64	2	/* load and sign extend into a 64 bit register */
#define A64_LS_LDRS32	3	/* load and sign extend into a 32 bit register */

/** @param imm12 In units of the access width, so a byte offset divided by 1, 2, 4 or 8. */
static inline a64_insn a64_ls_imm( int size, int v, int opc, int rt, int rn, unsigned int imm12 ) {
	return ((a64_insn)(size & 3) << 30) | ((a64_insn)7 << 27) | ((a64_insn)(v & 1) << 26)
		| ((a64_insn)1 << 24) | ((a64_insn)(opc & 3) << 22) | ((a64_insn)(imm12 & 0xFFF) << 10)
		| ((rn & 31) << 5) | (rt & 31);
}

static inline a64_insn a64_str_imm( int size, int rt, int rn, unsigned int imm12 ) {
	return a64_ls_imm(size, 0, A64_LS_STR, rt, rn, imm12);
}

static inline a64_insn a64_ldr_imm( int size, int rt, int rn, unsigned int imm12 ) {
	return a64_ls_imm(size, 0, A64_LS_LDR, rt, rn, imm12);
}

static inline a64_insn a64_str_fp_imm( int size, int rt, int rn, unsigned int imm12 ) {
	return a64_ls_imm(size, 1, A64_LS_STR, rt, rn, imm12);
}

static inline a64_insn a64_ldr_fp_imm( int size, int rt, int rn, unsigned int imm12 ) {
	return a64_ls_imm(size, 1, A64_LS_LDR, rt, rn, imm12);
}

/** @param imm9 A signed byte offset, not scaled, so this is what reaches a negative frame slot. */
static inline a64_insn a64_ls_unscaled( int size, int v, int opc, int rt, int rn, int imm9 ) {
	return ((a64_insn)(size & 3) << 30) | ((a64_insn)7 << 27) | ((a64_insn)(v & 1) << 26)
		| ((a64_insn)(opc & 3) << 22) | ((a64_insn)(imm9 & 0x1FF) << 12)
		| ((rn & 31) << 5) | (rt & 31);
}

static inline a64_insn a64_stur( int size, int rt, int rn, int imm9 ) {
	return a64_ls_unscaled(size, 0, A64_LS_STR, rt, rn, imm9);
}

static inline a64_insn a64_ldur( int size, int rt, int rn, int imm9 ) {
	return a64_ls_unscaled(size, 0, A64_LS_LDR, rt, rn, imm9);
}

static inline a64_insn a64_stur_fp( int size, int rt, int rn, int imm9 ) {
	return a64_ls_unscaled(size, 1, A64_LS_STR, rt, rn, imm9);
}

static inline a64_insn a64_ldur_fp( int size, int rt, int rn, int imm9 ) {
	return a64_ls_unscaled(size, 1, A64_LS_LDR, rt, rn, imm9);
}

/** How a register offset is widened before it is added, as the option field spells it. */
#define A64_EXT_UXTW	2
#define A64_EXT_LSL	3
#define A64_EXT_SXTW	6
#define A64_EXT_SXTX	7

/** @param scaled Whether the index is multiplied by the access width, which is the S bit. */
static inline a64_insn a64_ls_reg( int size, int v, int opc, int rt, int rn, int rm, int option, int scaled ) {
	return ((a64_insn)(size & 3) << 30) | ((a64_insn)7 << 27) | ((a64_insn)(v & 1) << 26)
		| ((a64_insn)(opc & 3) << 22) | ((a64_insn)1 << 21) | ((rm & 31) << 16)
		| ((a64_insn)(option & 7) << 13) | ((a64_insn)(scaled & 1) << 12) | ((a64_insn)2 << 10)
		| ((rn & 31) << 5) | (rt & 31);
}

static inline a64_insn a64_str_reg( int size, int rt, int rn, int rm ) {
	return a64_ls_reg(size, 0, A64_LS_STR, rt, rn, rm, A64_EXT_LSL, 0);
}

static inline a64_insn a64_ldr_reg( int size, int rt, int rn, int rm ) {
	return a64_ls_reg(size, 0, A64_LS_LDR, rt, rn, rm, A64_EXT_LSL, 0);
}

/**
	Load and store pair.

	A prologue is one STP and an epilogue is one LDP, which is why these are here rather than being
	two stores. The pre-index form writes the adjusted base back, so pushing the frame pointer and the
	link register and moving the stack pointer is a single instruction.
*/

#define A64_PAIR_OFF	2	/* [rn, #imm] */
#define A64_PAIR_PRE	3	/* [rn, #imm]! */
#define A64_PAIR_POST	1	/* [rn], #imm */

/** @param imm7 In units of the access width, so a byte offset divided by 4 or 8. */
static inline a64_insn a64_pair( int is64, int v, int mode, int load, int rt, int rt2, int rn, int imm7 ) {
	return ((a64_insn)(is64 ? 2 : 0) << 30) | ((a64_insn)5 << 27) | ((a64_insn)(v & 1) << 26)
		| ((a64_insn)(mode & 7) << 23) | ((a64_insn)(load & 1) << 22) | ((a64_insn)(imm7 & 0x7F) << 15)
		| ((rt2 & 31) << 10) | ((rn & 31) << 5) | (rt & 31);
}

static inline a64_insn a64_stp( int is64, int mode, int rt, int rt2, int rn, int imm7 ) {
	return a64_pair(is64, 0, mode, 0, rt, rt2, rn, imm7);
}

static inline a64_insn a64_ldp( int is64, int mode, int rt, int rt2, int rn, int imm7 ) {
	return a64_pair(is64, 0, mode, 1, rt, rt2, rn, imm7);
}

/**
	Branches.

	Every offset here is in instructions rather than bytes, since every instruction is four bytes and
	a branch to an unaligned address cannot be spelled. A forward branch is emitted with a zero offset
	and patched once its target is known, which on a fixed width encoding is rewriting one field.
*/

/** @param imm26 The offset in instructions, signed. */
static inline a64_insn a64_b( int imm26 ) {
	return ((a64_insn)5 << 26) | ((a64_insn)imm26 & 0x3FFFFFF);
}

/** @param imm26 The offset in instructions, signed. */
static inline a64_insn a64_bl( int imm26 ) {
	return ((a64_insn)0x25 << 26) | ((a64_insn)imm26 & 0x3FFFFFF);
}

/** @param imm19 The offset in instructions, signed. */
static inline a64_insn a64_bcond( int cond, int imm19 ) {
	return ((a64_insn)0x54 << 24) | (((a64_insn)imm19 & 0x7FFFF) << 5) | (cond & 15);
}

/** @param imm19 The offset in instructions, signed. */
static inline a64_insn a64_cbz( int is64, int rt, int imm19 ) {
	return ((a64_insn)(is64 & 1) << 31) | ((a64_insn)0x34 << 24) | (((a64_insn)imm19 & 0x7FFFF) << 5) | (rt & 31);
}

/** @param imm19 The offset in instructions, signed. */
static inline a64_insn a64_cbnz( int is64, int rt, int imm19 ) {
	return ((a64_insn)(is64 & 1) << 31) | ((a64_insn)0x35 << 24) | (((a64_insn)imm19 & 0x7FFFF) << 5) | (rt & 31);
}

static inline a64_insn a64_br( int rn ) {
	return 0xD61F0000u | ((a64_insn)(rn & 31) << 5);
}

static inline a64_insn a64_blr( int rn ) {
	return 0xD63F0000u | ((a64_insn)(rn & 31) << 5);
}

static inline a64_insn a64_ret( int rn ) {
	return 0xD65F0000u | ((a64_insn)(rn & 31) << 5);
}

static inline a64_insn a64_nop( void ) {
	return 0xD503201Fu;
}

/** A breakpoint, which is what an unreachable path is filled with so a mistake stops rather than runs on. */
static inline a64_insn a64_brk( unsigned int imm16 ) {
	return 0xD4200000u | ((a64_insn)(imm16 & 0xFFFF) << 5);
}

/**
	Addresses.

	ADR only, reaching a megabyte either way, and it is relative to where it sits. That matters here
	more than usual: hl_jit_code assembles into one buffer and copies the result somewhere executable,
	so anything PC relative has to be emitted after the move or not at all. An absolute address is
	built with MOVZ and MOVK instead, which is four instructions that are right wherever they land.

	ADRP is deliberately absent. It cannot be checked the way everything else here is, because an
	assembler given a page relative expression emits a relocation and leaves the field zero, and an
	encoder nothing compares against is an encoder nobody has checked.
*/

/** @param imm21 The offset in bytes, signed. */
static inline a64_insn a64_adr( int rd, int imm21 ) {
	return ((a64_insn)((unsigned)imm21 & 3) << 29) | ((a64_insn)0x10 << 24)
		| ((((a64_insn)imm21 >> 2) & 0x7FFFF) << 5) | (rd & 31);
}

/**
	Conditional select.

	CSET is CSINC reading the zero register twice with the condition inverted, which is how a
	comparison becomes a value without a branch. HL's comparisons are jumps, so this is for the places
	that want a boolean rather than control flow.
*/

static inline a64_insn a64_csinc( int is64, int rd, int rn, int rm, int cond ) {
	return ((a64_insn)(is64 & 1) << 31) | ((a64_insn)0xD4 << 21) | ((rm & 31) << 16)
		| ((a64_insn)(cond & 15) << 12) | ((a64_insn)1 << 10) | ((rn & 31) << 5) | (rd & 31);
}

static inline a64_insn a64_csel( int is64, int rd, int rn, int rm, int cond ) {
	return ((a64_insn)(is64 & 1) << 31) | ((a64_insn)0xD4 << 21) | ((rm & 31) << 16)
		| ((a64_insn)(cond & 15) << 12) | ((rn & 31) << 5) | (rd & 31);
}

static inline a64_insn a64_cset( int is64, int rd, int cond ) {
	return a64_csinc(is64, rd, A64_ZR, A64_ZR, cond ^ 1);
}

/**
	Floating point.

	`type` is 0 for single and 1 for double, and it is the same field in every group below.
*/

#define A64_F32		0
#define A64_F64		1

#define A64_FP_MUL	0
#define A64_FP_DIV	1
#define A64_FP_ADD	2
#define A64_FP_SUB	3

static inline a64_insn a64_fp2( int type, int op, int rd, int rn, int rm ) {
	return ((a64_insn)0x1E << 24) | ((a64_insn)(type & 3) << 22) | ((a64_insn)1 << 21)
		| ((rm & 31) << 16) | ((a64_insn)(op & 15) << 12) | ((a64_insn)2 << 10)
		| ((rn & 31) << 5) | (rd & 31);
}

static inline a64_insn a64_fadd( int type, int rd, int rn, int rm ) {
	return a64_fp2(type, A64_FP_ADD, rd, rn, rm);
}

static inline a64_insn a64_fsub( int type, int rd, int rn, int rm ) {
	return a64_fp2(type, A64_FP_SUB, rd, rn, rm);
}

static inline a64_insn a64_fmul( int type, int rd, int rn, int rm ) {
	return a64_fp2(type, A64_FP_MUL, rd, rn, rm);
}

static inline a64_insn a64_fdiv( int type, int rd, int rn, int rm ) {
	return a64_fp2(type, A64_FP_DIV, rd, rn, rm);
}

#define A64_FP1_MOV	0
#define A64_FP1_ABS	1
#define A64_FP1_NEG	2
#define A64_FP1_CVT_S	4	/* to single, so from double */
#define A64_FP1_CVT_D	5	/* to double, so from single */

static inline a64_insn a64_fp1( int type, int op, int rd, int rn ) {
	return ((a64_insn)0x1E << 24) | ((a64_insn)(type & 3) << 22) | ((a64_insn)1 << 21)
		| ((a64_insn)(op & 63) << 15) | ((a64_insn)0x10 << 10) | ((rn & 31) << 5) | (rd & 31);
}

static inline a64_insn a64_fmov_reg( int type, int rd, int rn ) {
	return a64_fp1(type, A64_FP1_MOV, rd, rn);
}

static inline a64_insn a64_fneg( int type, int rd, int rn ) {
	return a64_fp1(type, A64_FP1_NEG, rd, rn);
}

/** Widening a single to a double, which is the conversion HL needs when an f32 meets an f64. */
static inline a64_insn a64_fcvt_s2d( int rd, int rn ) {
	return a64_fp1(A64_F32, A64_FP1_CVT_D, rd, rn);
}

static inline a64_insn a64_fcvt_d2s( int rd, int rn ) {
	return a64_fp1(A64_F64, A64_FP1_CVT_S, rd, rn);
}

/** Comparison, which sets the same flags an integer comparison does, so the same branches read it. */
static inline a64_insn a64_fcmp( int type, int rn, int rm ) {
	return ((a64_insn)0x1E << 24) | ((a64_insn)(type & 3) << 22) | ((a64_insn)1 << 21)
		| ((rm & 31) << 16) | ((a64_insn)8 << 10) | ((rn & 31) << 5);
}

/** Comparison against zero, which needs no register to hold the zero. */
static inline a64_insn a64_fcmp_zero( int type, int rn ) {
	return ((a64_insn)0x1E << 24) | ((a64_insn)(type & 3) << 22) | ((a64_insn)1 << 21)
		| ((a64_insn)8 << 10) | ((rn & 31) << 5) | 8;
}

/**
	Moving between the two banks.

	SCVTF and FCVTZS convert the value, FMOV moves the bits. HL wants the first pair for OToSFloat and
	OToInt, and the second for reading a double out of a structure into a general register.
*/

#define A64_CVT_SCVTF	0x02	/* rmode 00, opcode 010 */
#define A64_CVT_UCVTF	0x03	/* rmode 00, opcode 011 */
#define A64_CVT_FCVTZU	0x19	/* rmode 11, opcode 001 */
#define A64_CVT_FCVTZS	0x18	/* rmode 11, opcode 000 */
#define A64_CVT_FMOV_TO	0x06	/* rmode 00, opcode 110, fp to general */
#define A64_CVT_FMOV_FROM	0x07	/* rmode 00, opcode 111, general to fp */

static inline a64_insn a64_cvt( int is64, int type, int op, int rd, int rn ) {
	return ((a64_insn)(is64 & 1) << 31) | ((a64_insn)0x1E << 24) | ((a64_insn)(type & 3) << 22)
		| ((a64_insn)1 << 21) | ((a64_insn)(op & 0x1F) << 16) | ((rn & 31) << 5) | (rd & 31);
}

/** Signed integer to floating point. */
static inline a64_insn a64_scvtf( int is64, int type, int rd, int rn ) {
	return a64_cvt(is64, type, A64_CVT_SCVTF, rd, rn);
}

/** Unsigned integer to floating point, which is what HashLink's OToUFloat means. */
static inline a64_insn a64_ucvtf( int is64, int type, int rd, int rn ) {
	return a64_cvt(is64, type, A64_CVT_UCVTF, rd, rn);
}

/** Floating point to unsigned integer, rounding towards zero. */
static inline a64_insn a64_fcvtzu( int is64, int type, int rd, int rn ) {
	return a64_cvt(is64, type, A64_CVT_FCVTZU, rd, rn);
}

/** Floating point to signed integer, rounding towards zero, which is what Haxe means by Std.int. */
static inline a64_insn a64_fcvtzs( int is64, int type, int rd, int rn ) {
	return a64_cvt(is64, type, A64_CVT_FCVTZS, rd, rn);
}

static inline a64_insn a64_fmov_to_gpr( int is64, int type, int rd, int rn ) {
	return a64_cvt(is64, type, A64_CVT_FMOV_TO, rd, rn);
}

static inline a64_insn a64_fmov_from_gpr( int is64, int type, int rd, int rn ) {
	return a64_cvt(is64, type, A64_CVT_FMOV_FROM, rd, rn);
}

#endif
