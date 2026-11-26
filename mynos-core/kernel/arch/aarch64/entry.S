/*
 * MyNOS on AArch64: the ways into the kernel (doc/decisions/aarch64.md,
 * choice 6). Every exception leaves a struct frame (idt.h) on the kernel
 * stack (SP_EL1: from a process, the thread's stack top, where the last
 * return to it left SP), calls kernel_enter (the big lock, smp.c) and
 * arm_trap (idt.c); every way out is trap_return.
 */

#define FRAME 304

	.text
	.macro VENTRY n
	.balign 0x80
	sub	sp, sp, #FRAME
	stp	x0, x1, [sp, #0]
	mov	x0, #\n
	b	exception_common
	.endm

	.balign 2048
	.global exception_vectors
exception_vectors:
	VENTRY 0
	VENTRY 1
	VENTRY 2
	VENTRY 3
	VENTRY 4                        /* EL1, SP_EL1: synchronous */
	VENTRY 5                        /* IRQ */
	VENTRY 6
	VENTRY 7
	VENTRY 8                        /* EL0, AArch64: synchronous */
	VENTRY 9                        /* IRQ */
	VENTRY 10
	VENTRY 11
	VENTRY 12
	VENTRY 13
	VENTRY 14
	VENTRY 15

exception_common:
	stp	x2, x3, [sp, #16]
	stp	x4, x5, [sp, #32]
	stp	x6, x7, [sp, #48]
	stp	x8, x9, [sp, #64]
	stp	x10, x11, [sp, #80]
	stp	x12, x13, [sp, #96]
	stp	x14, x15, [sp, #112]
	stp	x16, x17, [sp, #128]
	stp	x18, x19, [sp, #144]
	stp	x20, x21, [sp, #160]
	stp	x22, x23, [sp, #176]
	stp	x24, x25, [sp, #192]
	stp	x26, x27, [sp, #208]
	stp	x28, x29, [sp, #224]
	str	x30, [sp, #240]
	str	x0, [sp, #288]
	mrs	x1, sp_el0
	str	x1, [sp, #248]
	mrs	x1, elr_el1
	mrs	x2, spsr_el1
	stp	x1, x2, [sp, #256]
	mrs	x1, esr_el1
	mrs	x2, far_el1
	stp	x1, x2, [sp, #272]
	bl	kernel_enter
	mov	x0, sp
	bl	arm_trap

/* every way out leaves the big lock (unless nested); a new thread comes
   here first, its depth 1 */
	.global trap_return
trap_return:
	bl	kernel_exit
	ldp	x1, x2, [sp, #256]
	msr	elr_el1, x1
	msr	spsr_el1, x2
	ldr	x1, [sp, #248]
	msr	sp_el0, x1
	ldp	x2, x3, [sp, #16]
	ldp	x4, x5, [sp, #32]
	ldp	x6, x7, [sp, #48]
	ldp	x8, x9, [sp, #64]
	ldp	x10, x11, [sp, #80]
	ldp	x12, x13, [sp, #96]
	ldp	x14, x15, [sp, #112]
	ldp	x16, x17, [sp, #128]
	ldp	x18, x19, [sp, #144]
	ldp	x20, x21, [sp, #160]
	ldp	x22, x23, [sp, #176]
	ldp	x24, x25, [sp, #192]
	ldp	x26, x27, [sp, #208]
	ldp	x28, x29, [sp, #224]
	ldr	x30, [sp, #240]
	ldp	x0, x1, [sp, #0]
	add	sp, sp, #FRAME
	/* the local exclusive monitor cleared: a thread interrupted between
	   its LDXR and STXR, coming back after another thread of this
	   processor did an LDXR of the same word (and no STXR: a lock found
	   taken), must not find that one's reservation and succeed (two
	   threads inside musl's malloc lock: the heap corrupted) */
	clrex
	eret

/* switch_stacks(&old->rsp, new rsp): the callee-saved registers and the
   return address of the thread switched out stay on its stack */
	.global switch_stacks
switch_stacks:
	sub	sp, sp, #96
	stp	x19, x20, [sp, #0]
	stp	x21, x22, [sp, #16]
	stp	x23, x24, [sp, #32]
	stp	x25, x26, [sp, #48]
	stp	x27, x28, [sp, #64]
	stp	x29, x30, [sp, #80]
	mov	x2, sp
	str	x2, [x0]
	mov	sp, x1
	ldp	x19, x20, [sp, #0]
	ldp	x21, x22, [sp, #16]
	ldp	x23, x24, [sp, #32]
	ldp	x25, x26, [sp, #48]
	ldp	x27, x28, [sp, #64]
	ldp	x29, x30, [sp, #80]
	add	sp, sp, #96
	ret

/* copy_user(to, from, n): a copy that may fault; a fault in its loop
   (copy_user_insn..copy_user_end) resumes at copy_user_fault (idt.c,
   mem.c), and the copy returns -1 */
	.global copy_user, copy_user_insn, copy_user_end, copy_user_fault
copy_user:
	mov	w3, w2
	cbz	x3, 2f
copy_user_insn:
1:	ldrb	w4, [x1], #1
	strb	w4, [x0], #1
	subs	x3, x3, #1
	b.ne	1b
copy_user_end:
2:	mov	w0, #0
	ret
copy_user_fault:
	mov	w0, #-1
	ret
