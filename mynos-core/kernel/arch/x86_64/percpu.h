/*
  MyNOS
  Copyright (C) 2026
  MyNOS team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.
*/

/* The processor running this code (process.h's struct cpu), on x86-64:
   in the kernel GS's base is its struct cpu, whose first field points to
   itself; in a process GS's base is the process's (0), and swapgs, at
   every way in from a process and out to one (entry.asm, idt.h, pit.c),
   exchanges the two (doc/decisions/smp.md). */

#ifndef __PERCPU_H__
#define __PERCPU_H__

static inline struct cpu * arch_cpu(void)
{
  struct cpu * c;
  __asm__ volatile ("movq %%gs:0, %0" : "=r"(c));
  return c;
}

/* the boot processor's GS, first thing in mynos_main (gdt.c) */
void arch_cpu_boot(void);
/* the other processors started, before the boot one becomes idle (smp.c) */
void arch_smp_start(void);

#endif
