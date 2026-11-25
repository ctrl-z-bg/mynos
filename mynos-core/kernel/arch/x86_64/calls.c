/*
  MyNOS
  Copyright (C) 2026
  MyNOS team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.
*/

/* x86-64's system calls (doc/decisions/x86-64.md, choice 6): MyNOS's
   native calls (int 0x90) and Linux's (syscall), dispatched by number to
   the generic handlers. Not written yet: every call answers -ENOSYS. */

#include "global.h"
#include "idt.h"
#include "video.h"

#define MSR_EFER  0xC0000080
#define MSR_STAR  0xC0000081
#define MSR_LSTAR 0xC0000082
#define MSR_FMASK 0xC0000084

static void wrmsr(uint32_t msr, uint64_t v)
{
  __asm__ volatile ("wrmsr" : : "c"(msr), "a"((uint32_t)v), "d"((uint32_t)(v >> 32)));
}
static uint64_t rdmsr(uint32_t msr)
{
  uint32_t lo, hi;
  __asm__ volatile ("rdmsr" : "=a"(lo), "=d"(hi) : "c"(msr));
  return lo | ((uint64_t)hi << 32);
}

extern void syscall_entry(void);

/* the syscall instruction: on (EFER.SCE), its entry, the kernel's code
   selector, interrupts and the direction flag off on entry */
void arch_init_calls(void)
{
  wrmsr(MSR_EFER, rdmsr(MSR_EFER) | 1);
  wrmsr(MSR_STAR, (uint64_t)0x08 << 32);
  wrmsr(MSR_LSTAR, (uint64_t)syscall_entry);
  wrmsr(MSR_FMASK, 0x600);
}

void _mynos_native_call(struct frame * f)
{
  f->rax = (uint64_t)-38;
}

void x86_syscall(struct frame * f)
{
  f->rax = (uint64_t)-38;
}
