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
 * arch.h: what the kernel's generic code asks of the processor, for the
 * i386 (doc/decisions/arch.md). Every architecture gives the same names;
 * the generic code (scheduler, memory, IPC, semaphores, the random pool)
 * calls these instead of writing instructions of its own.
 */

#ifndef __ARCH_H__
#define __ARCH_H__

/* ---- interrupts ---- */

static inline void arch_irq_disable(void) { __asm__ volatile ("cli" ::: "memory"); }
static inline void arch_irq_enable(void)  { __asm__ volatile ("sti" ::: "memory"); }

/* interrupts off, and the state before, for arch_irq_restore */
static inline unsigned int arch_irq_save(void) {
  unsigned int flags;
  __asm__ volatile ("pushfl; popl %0; cli" : "=r"(flags) : : "memory");
  return flags;
}
static inline void arch_irq_restore(unsigned int flags) {
  __asm__ volatile ("pushl %0; popfl" : : "r"(flags) : "memory", "cc");
}

/* wait for the next interrupt (the idle loop) */
static inline void arch_wait_interrupt(void) { __asm__ volatile ("hlt"); }

/* stop the processor for good: interrupts off, halted */
static inline void arch_halt_forever(void) {
  __asm__ volatile ("cli");
  for (;;) __asm__ volatile ("hlt");
}

/* ---- time and randomness ---- */

/* the processor's cycle counter (RDTSC), in two halves */
static inline void arch_cycles(unsigned int * lo, unsigned int * hi) {
  __asm__ volatile ("rdtsc" : "=a"(*lo), "=d"(*hi));
}

/* CPUID leaf [leaf], subleaf 0: ebx and ecx */
static inline void arch_cpuid(unsigned int leaf, unsigned int * b, unsigned int * c) {
  unsigned int a = leaf, d;
  __asm__ volatile ("cpuid" : "+a"(a), "=b"(*b), "=c"(*c), "=d"(d) : "c"(0));
}

/* RDRAND, RDSEED (as bytes: old assemblers do not know them); 1 if the
   processor gave a value. Ask arch_cpuid first whether they exist. */
static inline int arch_rdrand(unsigned int * v) {
  unsigned int x; unsigned char ok;
  __asm__ volatile (".byte 0x0f, 0xc7, 0xf0; setc %1" : "=a"(x), "=q"(ok) : : "cc");
  *v = x;
  return ok;
}
static inline int arch_rdseed(unsigned int * v) {
  unsigned int x; unsigned char ok;
  __asm__ volatile (".byte 0x0f, 0xc7, 0xf8; setc %1" : "=a"(x), "=q"(ok) : : "cc");
  *v = x;
  return ok;
}

/* ---- atomic bits (the semaphores' locks) ---- */

/* set bit 1 of *m; whether it was set already */
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

/* the translation of one page forgotten (after its entry changed) */
static inline void arch_flush_page(unsigned int laddr) {
  __asm__ volatile ("invlpg %0" : : "m"(*(char *)laddr) : "memory");
}

/* the kernel's own writes respect read-only pages (CR0.WP): a system call
   writing into a copy-on-write page copies it first (mynos-bvz) */
static inline void arch_write_protect_kernel(void) {
  unsigned int cr0;
  __asm__ volatile ("movl %%cr0, %0" : "=r"(cr0));
  __asm__ volatile ("movl %0, %%cr0" : : "r"(cr0 | 0x10000));
}

/* ---- the FPU ---- */

static inline void arch_fpu_reset(void) { __asm__ volatile ("finit"); }

#endif
