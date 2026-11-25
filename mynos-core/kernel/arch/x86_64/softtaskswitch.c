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
 * The context switch on x86-64 (doc/decisions/x86-64.md, choice 5): each
 * thread has its own kernel stack; switching is saving the callee-saved
 * registers on the outgoing one's, and taking the incoming one's
 * (switch_stacks, entry.asm), with its address space, its TLS base (FS)
 * and its floating-point state. The interrupted registers of a process
 * are on its kernel stack already, in the frame of its entry.
 */

#include "global.h"
#include "process.h"
#include "tss.h"
#include "gdt.h"
#include "softtaskswitch.h"
#include "mem/mem.h"

#define FPU_AREA(a) ((void *)(((unsigned long)(a) + 15) & ~15UL))

static ubyte_t fpu_clean[512 + 16];

void fpu_init(void)
{
  unsigned long cr4;
  uint32_t mxcsr = 0x1F80;
  __asm__ volatile ("movq %%cr4, %0" : "=r"(cr4));
  cr4 |= (1 << 9) | (1 << 10);          /* OSFXSR, OSXMMEXCPT: x86-64 has SSE */
  __asm__ volatile ("movq %0, %%cr4" : : "r"(cr4));
  __asm__ volatile ("fninit");
  __asm__ volatile ("ldmxcsr %0" : : "m"(mxcsr));
  __asm__ volatile ("fxsave (%0)" : : "r"(FPU_AREA(fpu_clean)) : "memory");
}

void fpu_save(tss_t * t)
{
  __asm__ volatile ("fxsave (%0)" : : "r"(FPU_AREA(t->fpu_area)) : "memory");
  t->fpu_valid = 1;
}

static void wrmsr(uint32_t msr, uint64_t v)
{
  __asm__ volatile ("wrmsr" : : "c"(msr), "a"((uint32_t)v), "d"((uint32_t)(v >> 32)));
}

extern void switch_stacks(uint64_t * old_rsp, uint64_t new_rsp);

void switchTo(tss_t * old, tss_t * new)
{
  struct cpu * c = arch_cpu();
  if (old == new) return;
  /* the big lock's depth is the thread's: it goes on where it left */
  old->kdepth = c->depth;
  c->depth = new->kdepth;
  fpu_save(old);
  __asm__ volatile ("fxrstor (%0)" : : "r"(new->fpu_valid ? FPU_AREA(new->fpu_area)
                                                         : FPU_AREA(fpu_clean)));
  gdt_set_rsp0(new->rsp0);
  wrmsr(0xC0000100, new->fs_base);      /* FS's base: the thread's TLS */
  if (old->cr3 != new->cr3)
    __asm__ volatile ("movq %0, %%cr3" : : "r"(new->cr3) : "memory");
  switch_stacks(&old->rsp, new->rsp);
}
