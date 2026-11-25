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
 * arch.h for x86-64 (doc/decisions/arch.md, x86-64.md): the same names as
 * the i386's, with 64-bit instructions.
 */

#ifndef __ARCH_H__
#define __ARCH_H__

/* the machine, as uname says it */
#define ARCH_MACHINE "x86_64"

/* ---- interrupts ---- */

static inline void arch_irq_disable(void) { __asm__ volatile ("cli" ::: "memory"); }
static inline void arch_irq_enable(void)  { __asm__ volatile ("sti" ::: "memory"); }

static inline unsigned long arch_irq_save(void) {
  unsigned long flags;
  __asm__ volatile ("pushfq; popq %0; cli" : "=r"(flags) : : "memory");
  return flags;
}
static inline void arch_irq_restore(unsigned long flags) {
  __asm__ volatile ("pushq %0; popfq" : : "r"(flags) : "memory", "cc");
}

static inline void arch_wait_interrupt(void) { __asm__ volatile ("hlt"); }

static inline void arch_halt_forever(void) {
  __asm__ volatile ("cli");
  for (;;) __asm__ volatile ("hlt");
}

/* ---- time and randomness ---- */

static inline void arch_cycles(unsigned int * lo, unsigned int * hi) {
  __asm__ volatile ("rdtsc" : "=a"(*lo), "=d"(*hi));
}

static inline void arch_cpuid(unsigned int leaf, unsigned int * b, unsigned int * c) {
  unsigned int a = leaf, d;
  __asm__ volatile ("cpuid" : "+a"(a), "=b"(*b), "=c"(*c), "=d"(d) : "c"(0));
}

static inline int arch_rdrand(unsigned int * v) {
  unsigned int x; unsigned char ok;
  __asm__ volatile ("rdrand %0; setc %1" : "=r"(x), "=q"(ok) : : "cc");
  *v = x;
  return ok;
}
static inline int arch_rdseed(unsigned int * v) {
  unsigned int x; unsigned char ok;
  __asm__ volatile ("rdseed %0; setc %1" : "=r"(x), "=q"(ok) : : "cc");
  *v = x;
  return ok;
}

/* ---- atomic bits (the semaphores' locks) ---- */

static inline int arch_test_and_set(unsigned int * m) {
  unsigned int result;
  __asm__ volatile ("btsl $1, %1; sbbl %0, %0"
                    : "=r"(result) : "m"(*m) : "memory");
  return result;
}
static inline void arch_clear(unsigned int * m) {
  __asm__ volatile ("lock btrl $1, %0" : : "m"(*m) : "memory");
}

/* ---- memory ---- */

/* a page's translation out of this processor's TLB, and out of the
   others' that may hold it (smp.c) */
extern unsigned int ncpus;
void smp_tlb_shootdown(unsigned long laddr);
static inline void arch_flush_page(unsigned long laddr) {
  __asm__ volatile ("invlpg (%0)" : : "r"(laddr) : "memory");
  if (ncpus > 1) smp_tlb_shootdown(laddr);
}
/* an entry that was not present: no processor holds it, this one's TLB
   may hold that it was not */
static inline void arch_flush_page_local(unsigned long laddr) {
  __asm__ volatile ("invlpg (%0)" : : "r"(laddr) : "memory");
}

static inline void arch_write_protect_kernel(void) {
  unsigned long cr0;
  __asm__ volatile ("movq %%cr0, %0" : "=r"(cr0));
  __asm__ volatile ("movq %0, %%cr0" : : "r"(cr0 | 0x10000));
}

static inline void arch_load_task_register(unsigned short selector) {
  __asm__ volatile ("ltr %0" : : "r"(selector));
}

/* an entry's saved registers, as the page fault handler gets them: where
   the interrupted instruction's address is, in words */
#define ARCH_FRAME_IP 17

/* ---- fork (linux_syscalls.c) ----
   The child's first thread starts by returning from fork with 0, through
   a copy of the parent's entry frame (arch/x86_64/space.c): nothing to
   do in fork's own frame */
#define ARCH_FORK_SAVE_REGISTERS(t) arch_fork_child(t)
#define ARCH_FORK_SWITCH(t)         do { } while (0)
#define ARCH_FORK_CHILD_RESUME(t)   do { } while (0)
void arch_fork_child(void * t);

/* ---- the FPU ---- */

static inline void arch_fpu_reset(void) { __asm__ volatile ("fninit"); }

#endif
