/*
  MyNOS
  Copyright (C) 2026
  MyNOS team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.
*/

/* The processor running this code (process.h's struct cpu), on AArch64:
   TPIDR_EL1, which EL0 cannot read or change (doc/decisions/aarch64.md,
   choice 6). One processor for now; the hooks of x86-64's SMP are here
   empty. */

#ifndef __PERCPU_H__
#define __PERCPU_H__

static inline struct cpu * arch_cpu(void)
{
  struct cpu * c;
  __asm__ volatile ("mrs %0, tpidr_el1" : "=r"(c));
  return c;
}

/* the boot processor's struct cpu, first thing in mynos_main (gdt.c) */
void arch_cpu_boot(void);
/* the other processors started, before the first process (smp.c) */
void arch_smp_start(void);
/* the big lock (smp.c); the boot's work after arch_smp_start under it */
void kernel_enter(void);
void kernel_exit(void);
static inline void arch_boot_lock(void) { kernel_enter(); }
static inline void arch_boot_unlock(void) { kernel_exit(); }
/* a thread became ready: an idle processor woken to run it */
void arch_smp_kick(void);
/* a process ended: the processors running its threads leave them */
void arch_smp_kick_process(pid_t pid);
/* this processor's thread is of a process ended meanwhile: it leaves it */
void smp_leave_if_dead(void);

#endif
