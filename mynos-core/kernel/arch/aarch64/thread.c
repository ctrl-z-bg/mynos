/*
  MyNOS
  Copyright (C) 2026
  MyNOS team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.
*/

/* AArch64's threads, as x86-64's (doc/decisions/x86-64.md, choice 5): the idle thread
   (the boot's, process 0), a new thread's first kernel stack, clone. */

#include "global.h"
#include "mem/mem.h"
#include "gdt.h"
#include "tss.h"
#include "idt.h"
#include "process.h"
#include "threads.h"
#include "kutils.h"
#include "sem.h"
#include "sched.h"
#include "mynos.h"
#include "mem/dynalloc.h"

extern process_descriptor_t * processTable[];
extern paddr_t kernel_pml4;
extern void trap_return(void);

/* process 0: the kernel's idle thread, the boot's stack */
void tsksw(void)
{
  process_descriptor_t * p = kmalloc(sizeof(process_descriptor_t));
  tss_t * t = kmalloc(sizeof(tss_t));
  kbzero(p, sizeof *p);
  kbzero(t, sizeof *t);
  processTable[0] = p;
  p->tss = t;
  kmemcpy(p->name, "kernel", 7);
  p->isAlive = 1;
  p->numThreads = 1;
  p->pid = 0;
  t->cr3 = kernel_pml4;
  t->privSem = __OS_sem_allocateSemaphore(0);
  currThread = t;
  arch_cpu()->idle = t;           /* the boot's thread: processor 0's idle */
  readyQueueInsert(t);
}

/* switch_stacks's frame under a new thread's entry frame: x19-x29 zero,
   x30 trap_return */
static void switch_frame(tss_t * t, uint64_t * sp)
{
  sp -= 12;
  kbzero(sp, 12 * 8);
  sp[11] = (uint64_t)trap_return;
  t->rsp = (uint64_t)sp;
}

/* a thread's first kernel stack: a frame for EL0 at [entry] on the user
   stack [stack] (PSTATE 0: EL0t, interrupts on), under a switch frame
   that returns to trap_return. Drivers need nothing more on ARM: their
   devices are memory (mapPhysical) */
void arch_thread_frame(tss_t * t, uint64_t entry, uint64_t stack, uint64_t x0,
		       int privileged)
{
  uint64_t * sp = (uint64_t *)t->rsp0;
  struct frame * f;
  (void)privileged;
  sp -= sizeof(struct frame) / 8;
  f = (struct frame *)sp;
  kbzero(f, sizeof *f);
  f->pc = entry;
  f->pstate = 0;
  f->sp = stack;
  f->x[0] = x0;
  t->kdepth = 1;                       /* trap_return leaves the big lock */
  switch_frame(t, sp);
}

static int privileged(void)
{
  return (processTable[currProcess]->privileges & MYNOS_PRIV_IO) != 0;
}

void arch_thread_init(tss_t * tss, vaddr_t entry, vaddr_t stack)
{
  tss->rsp0 = tss->kstack + KERNEL_STACK_NPAGES * PAGE_SIZE;
  arch_thread_frame(tss, entry, stack, 0, privileged());
}

/* Linux's clone for threads (calls.c puts AArch64's arguments in
   x86-64's order): flags, stack, ptid, ctid, tls (TPIDR_EL0); the new
   thread returns from clone with 0, on [stack] */
#define CLONE_VM             0x00000100
#define CLONE_THREAD         0x00010000
#define CLONE_SETTLS         0x00080000
#define CLONE_PARENT_SETTID  0x00100000
#define CLONE_CHILD_CLEARTID 0x00200000
#define CLONE_CHILD_SETTID   0x01000000
extern struct frame * current_frame;

long arch_clone(long flags, long stack, long ptid, long ctid, long tls)
{
  tss_t * t;
  uint64_t * sp;
  if ((flags & (CLONE_VM | CLONE_THREAD)) != (CLONE_VM | CLONE_THREAD)) return -38;
  if (((flags & CLONE_PARENT_SETTID) && !__mem_userArea((void *)ptid, 4)) ||
      ((flags & (CLONE_CHILD_SETTID | CLONE_CHILD_CLEARTID)) &&
       !__mem_userArea((void *)ctid, 4)))
    return -14;
  if ((t = threadAlloc()) == NULL) return -12;
  if (flags & CLONE_SETTLS) t->fs_base = tls;
  if (flags & CLONE_CHILD_CLEARTID) t->clearTid = (int32_t *)ctid;
  if (flags & CLONE_PARENT_SETTID) *(int32_t *)ptid = t->tid;
  if (flags & CLONE_CHILD_SETTID) *(int32_t *)ctid = t->tid;
  t->rsp0 = t->kstack + KERNEL_STACK_NPAGES * PAGE_SIZE;
  sp = (uint64_t *)t->rsp0;
  sp -= sizeof(struct frame) / 8;
  kmemcpy(sp, current_frame, sizeof(struct frame));
  ((struct frame *)sp)->x[0] = 0;
  ((struct frame *)sp)->sp = stack;
  t->kdepth = 1;
  switch_frame(t, sp);
  threadStart(t);
  return t->tid;
}
