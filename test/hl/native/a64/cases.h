/*
	Every encoder in a64.h, with the mnemonic it is supposed to be.

	One line per case, read twice: once to print the word the encoder produced, once to print the
	assembly a real assembler should turn into that same word. run.sh assembles the second and
	compares it against the first, so a case is a claim about what an instruction encodes to, and the
	assembler is what settles it.

	A case with no mnemonic beside it is not a test. Add both or add neither.
*/

/** Moving a constant. */
A64_CASE(a64_movz(1, 0, 0x1234, A64_HW0),	"movz x0, #0x1234")
A64_CASE(a64_movz(1, 3, 0x1234, A64_HW16),	"movz x3, #0x1234, lsl #16")
A64_CASE(a64_movz(1, 7, 0xFFFF, A64_HW48),	"movz x7, #0xffff, lsl #48")
A64_CASE(a64_movz(0, 5, 0xFFFF, A64_HW0),	"movz w5, #0xffff")
A64_CASE(a64_movn(1, 1, 0, A64_HW0),		"movn x1, #0")
A64_CASE(a64_movn(0, 2, 0x00FF, A64_HW16),	"movn w2, #0xff, lsl #16")
A64_CASE(a64_movk(1, 2, 0xBEEF, A64_HW32),	"movk x2, #0xbeef, lsl #32")
A64_CASE(a64_movk(1, 30, 0x0001, A64_HW0),	"movk x30, #1")

/** Add and subtract. */
A64_CASE(a64_add_imm(1, 0, 1, 0),		"add x0, x1, #0")
A64_CASE(a64_add_imm(1, A64_SP, A64_SP, 16),	"add sp, sp, #16")
A64_CASE(a64_add_imm(0, 9, 10, 4095),		"add w9, w10, #4095")
A64_CASE(a64_sub_imm(1, A64_SP, A64_SP, 4095),	"sub sp, sp, #4095")
A64_CASE(a64_addsub_imm(1, 0, 0, 0, 1, 1, 1),	"add x0, x1, #1, lsl #12")
A64_CASE(a64_cmp_imm(0, 5, 10),			"cmp w5, #10")
A64_CASE(a64_cmp_imm(1, 28, 0),			"cmp x28, #0")
A64_CASE(a64_add_reg(1, 0, 1, 2),		"add x0, x1, x2")
A64_CASE(a64_add_reg(0, 3, 4, 5),		"add w3, w4, w5")
A64_CASE(a64_sub_reg(0, 3, 4, 5),		"sub w3, w4, w5")
A64_CASE(a64_sub_reg(1, 30, 29, 28),		"sub x30, x29, x28")
A64_CASE(a64_addsub_reg(1, 0, 0, 0, 1, 2, A64_LSL, 3),	"add x0, x1, x2, lsl #3")
A64_CASE(a64_addsub_reg(0, 1, 0, 4, 5, 6, A64_ASR, 7),	"sub w4, w5, w6, asr #7")
A64_CASE(a64_cmp_reg(1, 6, 7),			"cmp x6, x7")
A64_CASE(a64_cmp_reg(0, 0, 1),			"cmp w0, w1")
A64_CASE(a64_neg(0, 1, 2),			"neg w1, w2")
A64_CASE(a64_neg(1, 3, 4),			"neg x3, x4")

/** Bitwise. */
A64_CASE(a64_and_reg(1, 0, 1, 2),		"and x0, x1, x2")
A64_CASE(a64_orr_reg(0, 3, 4, 5),		"orr w3, w4, w5")
A64_CASE(a64_eor_reg(1, 6, 7, 8),		"eor x6, x7, x8")
A64_CASE(a64_tst_reg(1, 9, 10),			"tst x9, x10")
A64_CASE(a64_tst_reg(0, 11, 11),		"tst w11, w11")
A64_CASE(a64_mov_reg(1, 0, 1),			"mov x0, x1")
A64_CASE(a64_mov_reg(0, 19, 20),		"mov w19, w20")
A64_CASE(a64_mvn(0, 2, 3),			"mvn w2, w3")
A64_CASE(a64_mvn(1, 16, 17),			"mvn x16, x17")
A64_CASE(a64_logic_reg(1, A64_LOGIC_AND, 1, 0, 1, 2, A64_LSL, 0),	"bic x0, x1, x2")

/** Shifts by a constant, and the extensions, which share one encoding. */
A64_CASE(a64_lsl_imm(0, 0, 1, 4),		"lsl w0, w1, #4")
A64_CASE(a64_lsl_imm(1, 0, 1, 4),		"lsl x0, x1, #4")
A64_CASE(a64_lsl_imm(0, 2, 3, 0),		"lsl w2, w3, #0")
A64_CASE(a64_lsl_imm(1, 4, 5, 63),		"lsl x4, x5, #63")
A64_CASE(a64_lsr_imm(0, 2, 3, 8),		"lsr w2, w3, #8")
A64_CASE(a64_lsr_imm(1, 6, 7, 32),		"lsr x6, x7, #32")
A64_CASE(a64_asr_imm(1, 4, 5, 16),		"asr x4, x5, #16")
A64_CASE(a64_asr_imm(0, 8, 9, 31),		"asr w8, w9, #31")
A64_CASE(a64_sxtw(0, 1),			"sxtw x0, w1")
A64_CASE(a64_sxtb(0, 2, 3),			"sxtb w2, w3")
A64_CASE(a64_sxth(1, 4, 5),			"sxth x4, w5")
A64_CASE(a64_uxtb(6, 7),			"uxtb w6, w7")
A64_CASE(a64_uxth(8, 9),			"uxth w8, w9")

/** Shifts by a register. */
A64_CASE(a64_shift_reg(0, A64_SHIFT_LSLV, 0, 1, 2),	"lsl w0, w1, w2")
A64_CASE(a64_shift_reg(1, A64_SHIFT_LSLV, 3, 4, 5),	"lsl x3, x4, x5")
A64_CASE(a64_shift_reg(1, A64_SHIFT_LSRV, 3, 4, 5),	"lsr x3, x4, x5")
A64_CASE(a64_shift_reg(0, A64_SHIFT_ASRV, 6, 7, 8),	"asr w6, w7, w8")

/** Multiply and divide. */
A64_CASE(a64_sdiv(0, 0, 1, 2),			"sdiv w0, w1, w2")
A64_CASE(a64_sdiv(1, 3, 4, 5),			"sdiv x3, x4, x5")
A64_CASE(a64_udiv(1, 3, 4, 5),			"udiv x3, x4, x5")
A64_CASE(a64_mul(0, 6, 7, 8),			"mul w6, w7, w8")
A64_CASE(a64_mul(1, 9, 10, 11),			"mul x9, x10, x11")
A64_CASE(a64_madd(1, 0, 1, 2, 3),		"madd x0, x1, x2, x3")
A64_CASE(a64_msub(0, 4, 5, 6, 7),		"msub w4, w5, w6, w7")
A64_CASE(a64_msub(1, 0, 1, 2, 3),		"msub x0, x1, x2, x3")

/** Loads and stores, scaled. */
A64_CASE(a64_ldr_imm(A64_X, 0, 1, 2),		"ldr x0, [x1, #16]")
A64_CASE(a64_ldr_imm(A64_X, 0, A64_SP, 0),	"ldr x0, [sp]")
A64_CASE(a64_ldr_imm(A64_W, 7, 8, 4095),	"ldr w7, [x8, #16380]")
A64_CASE(a64_str_imm(A64_W, 3, 4, 5),		"str w3, [x4, #20]")
A64_CASE(a64_str_imm(A64_X, 19, A64_SP, 3),	"str x19, [sp, #24]")
A64_CASE(a64_ldr_fp_imm(A64_X, 0, 1, 3),	"ldr d0, [x1, #24]")
A64_CASE(a64_str_fp_imm(A64_W, 2, 3, 1),	"str s2, [x3, #4]")
A64_CASE(a64_str_fp_imm(A64_X, 15, A64_SP, 2),	"str d15, [sp, #16]")
A64_CASE(a64_ls_imm(A64_B, 0, A64_LS_LDR, 0, 1, 3),	"ldrb w0, [x1, #3]")
A64_CASE(a64_ls_imm(A64_H, 0, A64_LS_LDR, 2, 3, 4),	"ldrh w2, [x3, #8]")
A64_CASE(a64_ls_imm(A64_H, 0, A64_LS_LDRS32, 2, 3, 4),	"ldrsh w2, [x3, #8]")
A64_CASE(a64_ls_imm(A64_B, 0, A64_LS_LDRS64, 4, 5, 1),	"ldrsb x4, [x5, #1]")
A64_CASE(a64_ls_imm(A64_B, 0, A64_LS_STR, 6, 7, 2),	"strb w6, [x7, #2]")
A64_CASE(a64_ls_imm(A64_H, 0, A64_LS_STR, 8, 9, 3),	"strh w8, [x9, #6]")

/** Loads and stores, unscaled, which is what a negative frame offset needs. */
A64_CASE(a64_ldur(A64_X, 0, A64_FP, -8),	"ldur x0, [x29, #-8]")
A64_CASE(a64_ldur(A64_W, 1, A64_FP, -255),	"ldur w1, [x29, #-255]")
A64_CASE(a64_stur(A64_W, 1, A64_FP, -12),	"stur w1, [x29, #-12]")
A64_CASE(a64_stur(A64_X, 2, A64_SP, 255),	"stur x2, [sp, #255]")
A64_CASE(a64_ldur_fp(A64_X, 2, A64_FP, -16),	"ldur d2, [x29, #-16]")
A64_CASE(a64_stur_fp(A64_W, 3, A64_FP, -4),	"stur s3, [x29, #-4]")

/** Loads and stores by register offset. */
A64_CASE(a64_ldr_reg(A64_X, 0, 1, 2),		"ldr x0, [x1, x2]")
A64_CASE(a64_str_reg(A64_W, 3, 4, 5),		"str w3, [x4, x5]")
A64_CASE(a64_ls_reg(A64_X, 0, A64_LS_LDR, 0, 1, 2, A64_EXT_LSL, 1),	"ldr x0, [x1, x2, lsl #3]")
A64_CASE(a64_ls_reg(A64_W, 0, A64_LS_LDR, 3, 4, 5, A64_EXT_SXTW, 0),	"ldr w3, [x4, w5, sxtw]")

/** Pairs, which is what a prologue and an epilogue are. */
A64_CASE(a64_stp(1, A64_PAIR_PRE, A64_FP, A64_LR, A64_SP, -2),	"stp x29, x30, [sp, #-16]!")
A64_CASE(a64_ldp(1, A64_PAIR_POST, A64_FP, A64_LR, A64_SP, 2),	"ldp x29, x30, [sp], #16")
A64_CASE(a64_stp(1, A64_PAIR_OFF, 19, 20, A64_SP, 4),		"stp x19, x20, [sp, #32]")
A64_CASE(a64_ldp(1, A64_PAIR_OFF, 21, 22, A64_FP, -8),		"ldp x21, x22, [x29, #-64]")
A64_CASE(a64_stp(0, A64_PAIR_OFF, 1, 2, A64_SP, 2),		"stp w1, w2, [sp, #8]")

/** Branches. */
A64_CASE(a64_b(4),				"b .+16")
A64_CASE(a64_b(-1),				"b .-4")
A64_CASE(a64_b(0),				"b .+0")
A64_CASE(a64_bl(8),				"bl .+32")
A64_CASE(a64_bcond(A64_EQ, -4),			"b.eq .-16")
A64_CASE(a64_bcond(A64_NE, 2),			"b.ne .+8")
A64_CASE(a64_bcond(A64_LT, 1),			"b.lt .+4")
A64_CASE(a64_bcond(A64_GE, 100),		"b.ge .+400")
A64_CASE(a64_cbz(1, 0, 3),			"cbz x0, .+12")
A64_CASE(a64_cbnz(0, 5, -2),			"cbnz w5, .-8")
A64_CASE(a64_br(16),				"br x16")
A64_CASE(a64_blr(17),				"blr x17")
A64_CASE(a64_ret(A64_LR),			"ret x30")
A64_CASE(a64_nop(),				"nop")
A64_CASE(a64_brk(0),				"brk #0")
A64_CASE(a64_adr(0, 8),				"adr x0, .+8")

/** Conditional select. */
A64_CASE(a64_cset(0, 0, A64_EQ),		"cset w0, eq")
A64_CASE(a64_cset(1, 3, A64_LT),		"cset x3, lt")
A64_CASE(a64_csel(1, 0, 1, 2, A64_LT),		"csel x0, x1, x2, lt")
A64_CASE(a64_csinc(1, 0, 1, 2, A64_GE),		"csinc x0, x1, x2, ge")

/** Floating point. */
A64_CASE(a64_fadd(A64_F64, 0, 1, 2),		"fadd d0, d1, d2")
A64_CASE(a64_fadd(A64_F32, 0, 1, 2),		"fadd s0, s1, s2")
A64_CASE(a64_fsub(A64_F32, 3, 4, 5),		"fsub s3, s4, s5")
A64_CASE(a64_fmul(A64_F64, 6, 7, 8),		"fmul d6, d7, d8")
A64_CASE(a64_fdiv(A64_F64, 9, 10, 11),		"fdiv d9, d10, d11")
A64_CASE(a64_fmov_reg(A64_F64, 0, 1),		"fmov d0, d1")
A64_CASE(a64_fneg(A64_F64, 2, 3),		"fneg d2, d3")
A64_CASE(a64_fcvt_s2d(0, 1),			"fcvt d0, s1")
A64_CASE(a64_fcvt_d2s(2, 3),			"fcvt s2, d3")
A64_CASE(a64_fcmp(A64_F64, 0, 1),		"fcmp d0, d1")
A64_CASE(a64_fcmp(A64_F32, 4, 5),		"fcmp s4, s5")
A64_CASE(a64_fcmp_zero(A64_F64, 2),		"fcmp d2, #0.0")

/** Across the two banks. */
A64_CASE(a64_scvtf(0, A64_F64, 0, 1),		"scvtf d0, w1")
A64_CASE(a64_scvtf(1, A64_F64, 2, 3),		"scvtf d2, x3")
A64_CASE(a64_scvtf(0, A64_F32, 4, 5),		"scvtf s4, w5")
A64_CASE(a64_fcvtzs(0, A64_F64, 4, 5),		"fcvtzs w4, d5")
A64_CASE(a64_fcvtzs(1, A64_F64, 6, 7),		"fcvtzs x6, d7")
A64_CASE(a64_fmov_to_gpr(1, A64_F64, 0, 1),	"fmov x0, d1")
A64_CASE(a64_fmov_from_gpr(1, A64_F64, 2, 3),	"fmov d2, x3")
A64_CASE(a64_fmov_to_gpr(0, A64_F32, 4, 5),	"fmov w4, s5")
A64_CASE(a64_fmov_from_gpr(0, A64_F32, 6, 7),	"fmov s6, w7")
