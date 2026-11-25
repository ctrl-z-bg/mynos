/*
  MyNOS
  Copyright (C) 2026
  MyNOS team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.
*/

/* The big kernel lock on AArch64 (doc/decisions/smp.md), as x86-64's:
   taken at every way in (entry.S), left at the way out (trap_return),
   unless nested; a depth per processor, kept per thread across a switch.
   One processor for now: the lock is never contended. */

#include "global.h"
#include "process.h"

static volatile int big_lock;

void kernel_enter(void)
{
  struct cpu * c = arch_cpu();
  if (c->depth++ == 0)
    while (__atomic_exchange_n(&big_lock, 1, __ATOMIC_ACQUIRE))
      while (big_lock) __asm__ volatile ("yield");
}

void kernel_exit(void)
{
  struct cpu * c = arch_cpu();
  if (--c->depth == 0) __atomic_store_n(&big_lock, 0, __ATOMIC_RELEASE);
}
