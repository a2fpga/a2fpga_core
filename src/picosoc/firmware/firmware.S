.section .init
.global main

#define STACKADDR	0x04800000
#define IRQSTACK	14336

/* begin: custom PicoRV32 opcodes */

#define regnum_q0   0
#define regnum_q1   1
#define regnum_q2   2
#define regnum_q3   3

#define regnum_x0   0
#define regnum_x1   1
#define regnum_x2   2
#define regnum_x3   3
#define regnum_x4   4
#define regnum_x5   5
#define regnum_x6   6
#define regnum_x7   7
#define regnum_x8   8
#define regnum_x9   9
#define regnum_x10 10
#define regnum_x11 11
#define regnum_x12 12
#define regnum_x13 13
#define regnum_x14 14
#define regnum_x15 15
#define regnum_x16 16
#define regnum_x17 17
#define regnum_x18 18
#define regnum_x19 19
#define regnum_x20 20
#define regnum_x21 21
#define regnum_x22 22
#define regnum_x23 23
#define regnum_x24 24
#define regnum_x25 25
#define regnum_x26 26
#define regnum_x27 27
#define regnum_x28 28
#define regnum_x29 29
#define regnum_x30 30
#define regnum_x31 31

#define regnum_zero 0
#define regnum_ra   1
#define regnum_sp   2
#define regnum_gp   3
#define regnum_tp   4
#define regnum_t0   5
#define regnum_t1   6
#define regnum_t2   7
#define regnum_s0   8
#define regnum_s1   9
#define regnum_a0  10
#define regnum_a1  11
#define regnum_a2  12
#define regnum_a3  13
#define regnum_a4  14
#define regnum_a5  15
#define regnum_a6  16
#define regnum_a7  17
#define regnum_s2  18
#define regnum_s3  19
#define regnum_s4  20
#define regnum_s5  21
#define regnum_s6  22
#define regnum_s7  23
#define regnum_s8  24
#define regnum_s9  25
#define regnum_s10 26
#define regnum_s11 27
#define regnum_t3  28
#define regnum_t4  29
#define regnum_t5  30
#define regnum_t6  31

// x8 is s0 and also fp
#define regnum_fp   8

#define r_type_insn(_f7, _rs2, _rs1, _f3, _rd, _opc) \
.word (((_f7) << 25) | ((_rs2) << 20) | ((_rs1) << 15) | ((_f3) << 12) | ((_rd) << 7) | ((_opc) << 0))

#define picorv32_getq_insn(_rd, _qs) \
r_type_insn(0b0000000, 0, regnum_ ## _qs, 0b100, regnum_ ## _rd, 0b0001011)

#define picorv32_setq_insn(_qd, _rs) \
r_type_insn(0b0000001, 0, regnum_ ## _rs, 0b010, regnum_ ## _qd, 0b0001011)

#define picorv32_retirq_insn() \
r_type_insn(0b0000010, 0, 0, 0b000, 0, 0b0001011)

#define picorv32_maskirq_insn(_rd, _rs) \
r_type_insn(0b0000011, 0, regnum_ ## _rs, 0b110, regnum_ ## _rd, 0b0001011)

#define picorv32_waitirq_insn(_rd) \
r_type_insn(0b0000100, 0, 0, 0b100, regnum_ ## _rd, 0b0001011)

#define picorv32_timer_insn(_rd, _rs) \
r_type_insn(0b0000101, 0, regnum_ ## _rs, 0b110, regnum_ ## _rd, 0b0001011)

/* end: custom PicoRV32 opcodes */


reset_vec:
	// no more than 8 bytes here !
	j start

.balign 8
irq_handler_addr:
	.dword 0x0000000000000000

.balign 16
irq_vec:
	/* save registers */

	picorv32_setq_insn(q2, x1)
	picorv32_setq_insn(q3, x2)

	// x2 is the stack pointer
	lui x2, %hi(IRQSTACK)
	addi x2, x2, %lo(IRQSTACK)

	picorv32_getq_insn(x1, q0)
	sw x1,   0*4(x2)

	picorv32_getq_insn(x1, q2)
	sw x1,   1*4(x2)

	picorv32_getq_insn(x1, q3)
	sw x1,   2*4(x2)

	sw x3,   3*4(x2)
	sw x4,   4*4(x2)
	sw x5,   5*4(x2)
	sw x6,   6*4(x2)
	sw x7,   7*4(x2)
	sw x8,   8*4(x2)
	sw x9,   9*4(x2)
	sw x10, 10*4(x2)
	sw x11, 11*4(x2)
	sw x12, 12*4(x2)
	sw x13, 13*4(x2)
	sw x14, 14*4(x2)
	sw x15, 15*4(x2)
	sw x16, 16*4(x2)
	sw x17, 17*4(x2)
	sw x18, 18*4(x2)
	sw x19, 19*4(x2)
	sw x20, 20*4(x2)
	sw x21, 21*4(x2)
	sw x22, 22*4(x2)
	sw x23, 23*4(x2)
	sw x24, 24*4(x2)
	sw x25, 25*4(x2)
	sw x26, 26*4(x2)
	sw x27, 27*4(x2)
	sw x28, 28*4(x2)
	sw x29, 29*4(x2)
	sw x30, 30*4(x2)
	sw x31, 31*4(x2)

	/* call interrupt handler C function */

	// arg0 = interrupt type bitmask
	picorv32_getq_insn(x10, q1)

	// arg1 = pointer to stored registers
	mv x11, x2

	// load irq handler address to x1 (ra)
	lw x1, 8(x0)

	// call to C function
	beq x0, x1, 1f
	jalr x1, x1, 0
1:

	/* restore registers */

	lw x1,   0*4(x2)
	picorv32_setq_insn(q0, x1)

	lw x1,   1*4(x2)
	picorv32_setq_insn(q1, x1)

	lw x1,   2*4(x2)
	picorv32_setq_insn(q2, x1)

	lw x3,   3*4(x2)
	lw x4,   4*4(x2)
	lw x5,   5*4(x2)
	lw x6,   6*4(x2)
	lw x7,   7*4(x2)
	lw x8,   8*4(x2)
	lw x9,   9*4(x2)
	lw x10, 10*4(x2)
	lw x11, 11*4(x2)
	lw x12, 12*4(x2)
	lw x13, 13*4(x2)
	lw x14, 14*4(x2)
	lw x15, 15*4(x2)
	lw x16, 16*4(x2)
	lw x17, 17*4(x2)
	lw x18, 18*4(x2)
	lw x19, 19*4(x2)
	lw x20, 20*4(x2)
	lw x21, 21*4(x2)
	lw x22, 22*4(x2)
	lw x23, 23*4(x2)
	lw x24, 24*4(x2)
	lw x25, 25*4(x2)
	lw x26, 26*4(x2)
	lw x27, 27*4(x2)
	lw x28, 28*4(x2)
	lw x29, 29*4(x2)
	lw x30, 30*4(x2)
	lw x31, 31*4(x2)

	picorv32_getq_insn(x1, q1)
	picorv32_getq_insn(x2, q2)

	picorv32_retirq_insn()


start:
	/* zero-initialize all registers */
	addi x1, zero, 0
	addi x2, zero, 0
	addi x3, zero, 0
	addi x4, zero, 0
	addi x5, zero, 0
	addi x6, zero, 0
	addi x7, zero, 0
	addi x8, zero, 0
	addi x9, zero, 0
	addi x10, zero, 0
	addi x11, zero, 0
	addi x12, zero, 0
	addi x13, zero, 0
	addi x14, zero, 0
	addi x15, zero, 0
	addi x16, zero, 0
	addi x17, zero, 0
	addi x18, zero, 0
	addi x19, zero, 0
	addi x20, zero, 0
	addi x21, zero, 0
	addi x22, zero, 0
	addi x23, zero, 0
	addi x24, zero, 0
	addi x25, zero, 0
	addi x26, zero, 0
	addi x27, zero, 0
	addi x28, zero, 0
	addi x29, zero, 0
	addi x30, zero, 0
	addi x31, zero, 0

	/* set stack pointer */
	lui sp, %hi(STACKADDR)
	addi sp, sp, %lo(STACKADDR)

	/* call main */
	call main

	/* halt */

loop:
        j loop

.balign 4

