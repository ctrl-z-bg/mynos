/*
  MyNOS
  Copyright (C) 2026
  MyNOS team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.
*/

/*
 * arch.h for AArch64 (doc/decisions/aarch64.md): the names of the i386's
 * and x86-64's, with ARM's instructions.
 */

#ifndef __ARCH_H__
#define __ARCH_H__

/* the machine, as uname says it */
#define ARCH_MACHINE "aarch64"

/* page table entries with ARM's bits (ptebits.h, paging.h's pte_set) */
#define ARCH_PTE_BITS
/* no ISA bus: no DMA area below 16 MB (mem.c) */
#define ARCH_NO_ISA_DMA

/* ---- interrupts (IRQ: PSTATE.I) ---- */

static inline void arch_irq_disable(void) { __asm__ volatile ("msr daifset, #2" ::: "memory"); }
static inline void arch_irq_enable(void)  { __asm__ volatile ("msr daifclr, #2" ::: "memory"); }

static inline unsigned long arch_irq_save(void) {
  unsigned long flags;
  __asm__ volatile ("mrs %0, daif; msr daifset, #2" : "=r"(flags) : : "memory");
  return flags;
}
static inline void arch_irq_restore(unsigned long flags) {
  __asm__ volatile ("msr daif, %0" : : "r"(flags) : "memory");
}

static inline void arch_wait_interrupt(void) { __asm__ volatile ("wfi"); }

static inline void arch_halt_forever(void) {
  __asm__ volatile ("msr daifset, #2");
  for (;;) __asm__ volatile ("wfi");
}

/* ---- time and randomness ---- */

/* the generic timer's counter, in place of the TSC */
static inline void arch_cycles(unsigned int * lo, unsigned int * hi) {
  unsigned long v;
  __asm__ volatile ("isb; mrs %0, cntvct_el0" : "=r"(v));
  *lo = (unsigned int)v;
  *hi = (unsigned int)(v >> 32);
}

/* no CPUID: nothing to report */
static inline void arch_cpuid(unsigned int leaf, unsigned int * b, unsigned int * c) {
  (void)leaf; *b = 0; *c = 0;
}

/* ARMv8.5's RNDR is not on a Cortex-A72: none (random.c mixes the
   timer's jitter) */
static inline int arch_rdrand(unsigned int * v) { *v = 0; return 0; }
static inline int arch_rdseed(unsigned int * v) { *v = 0; return 0; }

/* ---- atomic bits (the semaphores' locks) ---- */

static inline int arch_test_and_set(unsigned int * m) {
  return (__atomic_fetch_or(m, 2u, __ATOMIC_ACQUIRE) & 2u) ? -1 : 0;
}
static inline void arch_clear(unsigned int * m) {
  __atomic_fetch_and(m, ~2u, __ATOMIC_RELEASE);
}

/* ---- memory ---- */

/* a page's translation out of the TLBs: TLBI VAAE1IS reaches every
   processor in the inner shareable domain (no IPI, unlike x86) */
extern unsigned int ncpus;
static inline void arch_flush_page(unsigned long laddr) {
  __asm__ volatile ("dsb ishst; tlbi vaae1is, %0; dsb ish; isb"
                    : : "r"(laddr >> 12) : "memory");
}
static inline void arch_flush_page_local(unsigned long laddr) {
  __asm__ volatile ("dsb nshst; tlbi vaae1, %0; dsb nsh; isb"
                    : : "r"(laddr >> 12) : "memory");
}

/* the kernel's writes respect read-only pages always on ARM (AP[2]
   applies at EL1 too) */
static inline void arch_write_protect_kernel(void) { }

static inline void arch_load_task_register(unsigned short selector) { (void)selector; }

/* an entry's saved registers, as the page fault handler gets them: where
   the interrupted instruction's address is, in words (idt.h's frame) */
#define ARCH_FRAME_IP 32

/* ---- fork (linux_syscalls.c), as on x86-64 ---- */
#define ARCH_FORK_SAVE_REGISTERS(t) arch_fork_child(t)
#define ARCH_FORK_SWITCH(t)         do { } while (0)
#define ARCH_FORK_CHILD_RESUME(t)   do { } while (0)
void arch_fork_child(void * t);

/* ---- the FPU: nothing to reset (fpu_init keeps a clean state) ---- */

static inline void arch_fpu_reset(void) { }

#endif
