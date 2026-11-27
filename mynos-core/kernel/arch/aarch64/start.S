/*
 * MyNOS on AArch64 (doc/decisions/aarch64.md): the first instructions.
 *
 * QEMU virt's -kernel starts the ELF image at its physical entry, MMU
 * off, at EL1 (or EL2 with virtualization on: dropped to EL1). The
 * kernel is linked at 2 MB, loaded at 2 MB into RAM (0x40200000): until
 * the MMU is on, only PC-relative addresses (adrp) are used. A Raspberry
 * Pi's firmware (MYNOS_RASPI, btq.7) starts kernel8.img, this image's
 * bytes, where it put it (0x80000 by default), at EL2, the device tree's
 * address in x0: the image moves itself to 2 MB first. The first
 * tables (in .bss):
 *   TTBR0: L0[0] -> L1: [0] the kernel's gigabyte (linear 0..1 GB = RAM's
 *          first GB, in 2 MB blocks: L2), [1] RAM at its own address (1 GB
 *          block), only to go on after the MMU is turned on
 *   TTBR1: L0[256] -> L1: [0] the direct map (RAM, 0xFFFF800000000000)
 *          L0[511] -> L1: [0] the devices' first GB (0xFFFFFF8000000000)
 * Then C: arch_boot (dtb.c) reads the device tree and calls mynos_main.
 */

#ifdef MYNOS_RASPI
/* a Raspberry Pi (btq.7): RAM from 0, the peripherals from 0x3F000000
   (not normal memory: the RAM's maps stop there), the processors' local
   peripherals (their interrupt controller) at 0x40000000 */
#define RAM_BASE      0
#define RAM_BLOCKS    504
#else
#define RAM_BASE      0x40000000
#define RAM_BLOCKS    512
#endif
#define BLOCK_NORMAL  0x701                     /* valid, normal, inner shareable, AF */
#define BLOCK_DEVICE  (0x405 | (3 << 53))       /* valid, device nGnRE, AF, never run */
#define TABLE         3

/* MAIR: 0 normal write-back, 1 device nGnRE, 2 normal non-cacheable */
#define MAIR_VALUE    0x4404FF
/* TCR: 48-bit halves (T0SZ, T1SZ 16), 4 KB granules, write-back walks,
   inner shareable; IPS from the processor's physical address size */
#define TCR_VALUE     (16 | (1 << 8) | (1 << 10) | (3 << 12) | (16 << 16) | \
                       (1 << 24) | (1 << 26) | (3 << 28) | (2 << 30))
/* SCTLR: RES1 bits, MMU, caches; EL0 may use DC ZVA, CTR, WFI, WFE and
   cache maintenance (musl's string functions, the runtime) */
#define SCTLR_VALUE   (0x30D00800 | (1 << 0) | (1 << 2) | (1 << 12) | (1 << 14) | \
                       (1 << 15) | (1 << 16) | (1 << 18) | (1 << 26))

	.section .text.boot, "ax"
	.global _start
_start:
	mov	x20, x0                     /* the device tree (a Pi's firmware) */
	mrs	x0, mpidr_el1               /* processor 0 only: the others */
	and	x0, x0, #0xFF               /* start powered off (PSCI), or wait */
	cbnz	x0, park                    /* in the Pi's firmware */
#ifdef MYNOS_RASPI
	/* where the firmware put the image: if not at 2 MB, it moves there
	   (backwards: the two may overlap), and goes on there */
	adr	x1, _start
	ldr	x2, =_start                 /* 2 MB: RAM_BASE 0, linked == real */
	cmp	x1, x2
	b.eq	moved
	ldr	x3, =__bss_start            /* the image's end at 2 MB */
	sub	x4, x3, x2
	add	x4, x1, x4                  /* its end where it is */
4:	ldp	x5, x6, [x4, #-16]!
	stp	x5, x6, [x3, #-16]!
	cmp	x3, x2
	b.hi	4b
	dsb	sy
	ic	iallu
	dsb	sy
	isb
	adr	x5, moved
	sub	x5, x5, x1
	add	x5, x5, x2
	br	x5
moved:
#endif
	mrs	x0, CurrentEL
	lsr	x0, x0, #2
	cmp	x0, #2
	b.ne	el1
	/* EL2: EL1 in AArch64, its counters its own, then down to it */
	mov	x0, #(1 << 31)
	msr	hcr_el2, x0
	mov	x0, #3
	msr	cnthctl_el2, x0
	msr	cntvoff_el2, xzr
	mov	x0, #0x3c5                  /* EL1h, interrupts masked */
	msr	spsr_el2, x0
	adr	x0, el1
	msr	elr_el2, x0
	eret
el1:
	adrp	x0, boot_stack_top
	add	x0, x0, :lo12:boot_stack_top
	mov	sp, x0
	/* .bss cleared */
	adrp	x0, __bss_start
	add	x0, x0, :lo12:__bss_start
	adrp	x1, __bss_end
	add	x1, x1, :lo12:__bss_end
1:	cmp	x0, x1
	b.hs	2f
	str	xzr, [x0], #8
	b	1b
2:
	/* the kernel's gigabyte: 512 blocks of 2 MB from RAM's base */
	adrp	x0, pt_l2_kern
	add	x0, x0, :lo12:pt_l2_kern
	ldr	x1, =(RAM_BASE | BLOCK_NORMAL)
	mov	x2, #RAM_BLOCKS
	mov	x3, #0x200000
3:	str	x1, [x0], #8
	add	x1, x1, x3
	subs	x2, x2, #1
	b.ne	3b
	adrp	x0, pt_l1_lo
	add	x0, x0, :lo12:pt_l1_lo
	adrp	x1, pt_l2_kern
	add	x1, x1, :lo12:pt_l2_kern
	orr	x1, x1, #TABLE
	str	x1, [x0]
#ifndef MYNOS_RASPI                       /* (a Pi's RAM is at its own address) */
	ldr	x1, =(RAM_BASE | BLOCK_NORMAL)
	str	x1, [x0, #8]
#endif
	adrp	x0, pt_l0_lo
	add	x0, x0, :lo12:pt_l0_lo
	adrp	x1, pt_l1_lo
	add	x1, x1, :lo12:pt_l1_lo
	orr	x1, x1, #TABLE
	str	x1, [x0]
	/* the direct map: RAM's first GB (a Pi's: up to its peripherals, in
	   2 MB blocks) */
	adrp	x0, pt_l1_dm
	add	x0, x0, :lo12:pt_l1_dm
#ifdef MYNOS_RASPI
	adrp	x1, pt_l2_dm
	add	x1, x1, :lo12:pt_l2_dm
	orr	x1, x1, #TABLE
	str	x1, [x0]
	adrp	x0, pt_l2_dm
	add	x0, x0, :lo12:pt_l2_dm
	ldr	x1, =(RAM_BASE | BLOCK_NORMAL)
	mov	x2, #RAM_BLOCKS
	mov	x3, #0x200000
5:	str	x1, [x0], #8
	add	x1, x1, x3
	subs	x2, x2, #1
	b.ne	5b
#else
	ldr	x1, =(RAM_BASE | BLOCK_NORMAL)
	str	x1, [x0]
#endif
	adrp	x0, pt_l0_hi
	add	x0, x0, :lo12:pt_l0_hi
	adrp	x1, pt_l1_dm
	add	x1, x1, :lo12:pt_l1_dm
	orr	x1, x1, #TABLE
	str	x1, [x0, #(256 * 8)]
	/* the devices: the first GB; and the GB of PCI's configuration
	   space (ECAM, at 0x4010000000 on virt: arch/aarch64/pci.c) */
	adrp	x0, pt_l1_dev
	add	x0, x0, :lo12:pt_l1_dev
	ldr	x1, =BLOCK_DEVICE
	str	x1, [x0]
#ifdef MYNOS_RASPI
	ldr	x1, =(0x40000000 | BLOCK_DEVICE)   /* the local peripherals' GB */
	str	x1, [x0, #8]
#else
	ldr	x1, =(0x4000000000 | BLOCK_DEVICE)
	str	x1, [x0, #(256 * 8)]
#endif
	adrp	x0, pt_l0_hi
	add	x0, x0, :lo12:pt_l0_hi
	adrp	x1, pt_l1_dev
	add	x1, x1, :lo12:pt_l1_dev
	orr	x1, x1, #TABLE
	str	x1, [x0, #(511 * 8)]
	/* the MMU */
	ldr	x0, =MAIR_VALUE
	msr	mair_el1, x0
	mrs	x1, id_aa64mmfr0_el1
	and	x1, x1, #7
	ldr	x0, =TCR_VALUE
	orr	x0, x0, x1, lsl #32
	msr	tcr_el1, x0
	adrp	x0, pt_l0_lo
	add	x0, x0, :lo12:pt_l0_lo
	msr	ttbr0_el1, x0
	adrp	x0, pt_l0_hi
	add	x0, x0, :lo12:pt_l0_hi
	msr	ttbr1_el1, x0
	mov	x0, #(3 << 20)              /* FP and SIMD: not trapped */
	msr	cpacr_el1, x0
	isb
	tlbi	vmalle1
	dsb	nsh
	isb
	ldr	x0, =SCTLR_VALUE
	msr	sctlr_el1, x0
	isb
	ldr	x0, =high
	br	x0
high:
	ldr	x0, =boot_stack_top
	mov	sp, x0
	mov	x0, x20
	bl	arch_boot
park:
	wfe
	b	park

/*
 * The other processors (doc/decisions/smp.md): PSCI's CPU_ON starts one
 * here, MMU off, at EL1 (or EL2: dropped as above), x0 its number; on a
 * Pi the firmware's spin table, at EL2 (its number from MPIDR). The
 * boot's tables again (still there), the MMU on, up to the kernel's
 * addresses, then the kernel's own tables (ap_ttbr0: processor 0's
 * kernel_pml4, its real address) before the stack is touched: the stack
 * processor 0 left in ap_stack_top is a page of the kernel's tables, at
 * another place in the boot's (what was written there before the change
 * was not there after it: ap_main's number read back as 0), then
 * ap_main (smp.c).
 */
	.global _start_secondary
_start_secondary:
#ifdef MYNOS_RASPI
	mrs	x19, mpidr_el1              /* (a spin table gives no number) */
	and	x19, x19, #0xFF
#else
	mov	x19, x0
#endif
	mrs	x0, CurrentEL
	lsr	x0, x0, #2
	cmp	x0, #2
	b.ne	1f
	mov	x0, #(1 << 31)
	msr	hcr_el2, x0
	mov	x0, #3
	msr	cnthctl_el2, x0
	msr	cntvoff_el2, xzr
	mov	x0, #0x3c5
	msr	spsr_el2, x0
	adr	x0, 1f
	msr	elr_el2, x0
	eret
1:	ldr	x0, =MAIR_VALUE
	msr	mair_el1, x0
	mrs	x1, id_aa64mmfr0_el1
	and	x1, x1, #7
	ldr	x0, =TCR_VALUE
	orr	x0, x0, x1, lsl #32
	msr	tcr_el1, x0
	adrp	x0, pt_l0_lo
	add	x0, x0, :lo12:pt_l0_lo
	msr	ttbr0_el1, x0
	adrp	x0, pt_l0_hi
	add	x0, x0, :lo12:pt_l0_hi
	msr	ttbr1_el1, x0
	mov	x0, #(3 << 20)
	msr	cpacr_el1, x0
	isb
	tlbi	vmalle1
	dsb	nsh
	isb
	ldr	x0, =SCTLR_VALUE
	msr	sctlr_el1, x0
	isb
	ldr	x0, =secondary_high
	br	x0
secondary_high:
	ldr	x0, =ap_ttbr0
	ldr	x0, [x0]
	dsb	ish
	msr	ttbr0_el1, x0
	isb
	tlbi	vmalle1
	dsb	nsh
	isb
	ldr	x0, =ap_stack_top
	ldr	x0, [x0]
	mov	sp, x0
	mov	x0, x19
	bl	ap_main
	b	park

	.section .bss
	.balign 4096
	.global pt_l0_lo, pt_l1_lo, pt_l2_kern, pt_l0_hi, pt_l1_dm, pt_l1_dev
pt_l0_lo:	.space 4096
pt_l1_lo:	.space 4096
pt_l2_kern:	.space 4096
pt_l0_hi:	.space 4096
pt_l1_dm:	.space 4096
pt_l1_dev:	.space 4096
#ifdef MYNOS_RASPI
pt_l2_dm:	.space 4096
#endif
	.balign 16
boot_stack:	.space 16384
	.global boot_stack_top
boot_stack_top:
