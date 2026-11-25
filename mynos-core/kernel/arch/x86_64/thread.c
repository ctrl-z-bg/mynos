/*
  MyNOS
  Copyright (C) 2026
  MyNOS team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.
*/

/* x86-64's threads (doc/decisions/x86-64.md, choice 5): the idle thread
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
  readyQueueInsert(t);
}

/* a thread's first kernel stack: a frame for user mode at [entry] on the
   user stack [stack], under a switch frame that returns to trap_return
   (switch_stacks pops six registers, then returns) */
void arch_thread_frame(tss_t * t, uint64_t entry, uint64_t stack, uint64_t rax,
		       int privileged)
{
  uint64_t * sp = (uint64_t *)t->rsp0;
  struct frame * f;
  sp -= sizeof(struct frame) / 8;
  f = (struct frame *)sp;
  kbzero(f, sizeof *f);
  f->rip = entry;
  f->cs = GDT_USER_CODE_SEL | 3;
  f->rflags = 0x202 | (privileged ? 0x3000 : 0);   /* IF; IOPL 3 for drivers */
  f->rsp = stack;
  f->ss = GDT_USER_DATA_SEL | 3;
  f->rax = rax;
  *--sp = (uint64_t)trap_return;
  sp -= 6;                                         /* rbx..r15: zeros */
  kbzero(sp, 6 * 8);
  t->rsp = (uint64_t)sp;
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

/* Linux's clone (56) for threads: flags, stack, ptid, ctid, tls (FS's
   base); the new thread returns from clone with 0, on [stack] */
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
  ((struct frame *)sp)->rax = 0;
  ((struct frame *)sp)->rsp = stack;
  *--sp = (uint64_t)trap_return;
  sp -= 6;
  kbzero(sp, 6 * 8);
  t->rsp = (uint64_t)sp;
  threadStart(t);
  return t->tid;
}
