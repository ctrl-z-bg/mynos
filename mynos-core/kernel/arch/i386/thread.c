/*
  MyNOS
  Copyright (C) 2002-2004, 2026
  MyNOS team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.
*/

/*
 * The i386's threads (doc/decisions/x86-64.md, choice 5): the idle
 * thread and the task register (tsksw), a new thread's registers
 * (arch_thread_init), Linux's clone with its iret frame, and the TLS
 * segment of set_thread_area. Moved from main.c, threads.c, lthreads.c
 * and linux_syscalls.c, unchanged.
 */

#include "global.h"
#include "mem/mem.h"
#include "gdt.h"
#include "tss.h"
#include "process.h"
#include "threads.h"
#include "kutils.h"
#include "sem.h"
#include "sched.h"
#include "linux_syscalls.h"
#include "mynos.h"
#include "mem/dynalloc.h"

/* a pointer of the process, checked (as linux_syscalls.c does) */
#define USER(P, N) do { if (!__mem_userArea((P), (N))) return -14; } while (0)

#define EFAULT    14
#define ENOMEM    12
#define ENOSYS    38
#define CLONE_VM             0x00000100
#define CLONE_SETTLS         0x00080000
#define CLONE_PARENT_SETTID  0x00100000
#define CLONE_CHILD_CLEARTID 0x00200000
#define CLONE_CHILD_SETTID   0x01000000
#define CLONE_THREAD         0x00010000

extern process_descriptor_t * processTable[];

/* a new thread of the current process: it starts at [entry], on the user
   stack [stack] */
void arch_thread_init(tss_t * tss, vaddr_t entry, vaddr_t stack) {
  tss->eip = entry;
  tss->esp = stack;
  tss->eflags = INITIAL_EFLAGS |
    ((processTable[currProcess]->privileges & MYNOS_PRIV_IO) ? IOPL3 : 0);
  tss->esp0 = tss->kstack + KERNEL_STACK_NPAGES * PAGE_SIZE - 1;

  /* initialize the kernel stack for the new thread */
  initStack(tss->esp0, tss);
}

ushort16_t * idle_tssd_selector;

tss_t THEtss;

void tsksw() {
  ushort16_t gdt_index, tssd_gdt_selector;

  /* allocate a new tss */
  processTable[0] = 
    (process_descriptor_t*)kmalloc(sizeof(process_descriptor_t));
  processTable[0]->tss = (tss_t*)kmalloc(sizeof(tss_t));
  kmemcpy(processTable[0]->name, "kernel", 7);
  processTable[0]->faultsAlloc = processTable[0]->faultsCow = 0;
  kbzero(processTable[0]->childWaiting, sizeof processTable[0]->childWaiting);
  processTable[0]->tss->tls_base = 0;
  processTable[0]->tss->tls_limit = 0;
  processTable[0]->tss->tls_pages = 0;

  /* set a tss for the outcoming process */
  processTable[0]->tss->pgdir = (uint32_t**)0x100000;
  processTable[0]->tss->io_bitmap_offset = sizeof(tss_t)<<16;
  processTable[0]->tss->ldt = 0;
  processTable[0]->isAlive = 1;
  processTable[0]->tss->justForked = 0;

  processTable[0]->numThreads = 1;
  (processTable[0]->tss)->next = (processTable[0]->tss)->prev = NULL;
  processTable[0]->pid = 0;
  processTable[0]->tss->pid = 0;
  processTable[0]->tss->tid = 0;
  processTable[0]->tss->clearTid = NULL;
  processTable[0]->tss->kstack = 0;

  processTable[0]->tss->timeToWake = 0;

  processTable[0]->tss->cs = GDT_OS_CODE_SEL;
  processTable[0]->tss->ss0 = GDT_OS_DATA_SEL;

  currThread = processTable[0]->tss;

  // insert the thread into readyQueue
  readyQueueInsert(currThread);

  //SEM
  processTable[0]->tss->privSem = __OS_sem_allocateSemaphore(0);
  processTable[0]->tss->semHeld = 0;

  gdt_index = gdt_get_free_index();
  tssd_gdt_selector = (uint32_t)gdt_index << 3;

  kmemcpy(&THEtss, processTable[0]->tss, sizeof(tss_t));

  /* set the tssd in the gdt, for the incoming and the outcoming processes */
  gdt_set_entry(gdt_index,
		(uint32_t)(&THEtss),
		sizeof(tss_t), D_TSS);

  /* load the task register with the relative address in the gdt of the
     current process's tssd */
  idle_tssd_selector = (ushort16_t*)((uint32_t)tssd_gdt_selector);
  arch_load_task_register(tssd_gdt_selector);

}


/* the kernel stack of a new clone thread, popped by startClonedThread:
   segment registers, the general ones (popal order), then the iret frame */
typedef struct {
  ushort16_t gs, fs, es, ds;
  uint32_t edi, esi, ebp, esp_unused, ebx, edx, ecx, eax;
  uint32_t eip, cs, eflags, esp, ss;
} clone_stack_t;

void startClonedThread();
/* startClonedThread: arch/i386/entry.c */


int32_t _linux_syscall_clone(uint32_t flags, uint32_t stack, int32_t * ptid,
			     struct user_desc * tls, int32_t * ctid,
			     uint32_t ebp) {
  /* the caller's iret frame is above the six registers the system call
     entry pushed (our arguments): eip, cs, eflags, esp, ss */
  uint32_t * frame = (uint32_t *)&flags + 6;
  clone_stack_t * cs;
  tss_t * tss;

  /* only threads: fork is its own call */
  if ((flags & (CLONE_VM | CLONE_THREAD)) != (CLONE_VM | CLONE_THREAD))
    return -ENOSYS;
  if (((flags & CLONE_SETTLS) && !__mem_userArea(tls, sizeof *tls)) ||
      ((flags & CLONE_PARENT_SETTID) && !__mem_userArea(ptid, sizeof *ptid)) ||
      ((flags & (CLONE_CHILD_SETTID | CLONE_CHILD_CLEARTID)) &&
       !__mem_userArea(ctid, sizeof *ctid)))
    return -EFAULT;
  if ((tss = threadAlloc()) == NULL) return -ENOMEM;

  if (flags & CLONE_SETTLS) {
    tss->tls_base = tls->base_addr;
    tss->tls_limit = tls->limit & 0xFFFFF;
    tss->tls_pages = (tls->flags >> 4) & 1;
  }
  if (flags & CLONE_CHILD_CLEARTID) tss->clearTid = ctid;
  if (flags & CLONE_PARENT_SETTID) *ptid = tss->tid;
  if (flags & CLONE_CHILD_SETTID) *ctid = tss->tid;

  /* its kernel stack: it starts by returning from this system call */
  tss->esp0 = tss->kstack + KERNEL_STACK_NPAGES * PAGE_SIZE;
  cs = (clone_stack_t *)(tss->esp0 - sizeof(clone_stack_t));
  cs->gs = (tss->tls_base || tss->tls_limit) ? ((GDT_TLS_INDEX << 3) | 3)
					      : GDT_USER_DATA_SEL + 3;
  cs->fs = cs->es = cs->ds = GDT_USER_DATA_SEL + 3;
  cs->eax = 0;                       /* clone returns 0 in the child */
  cs->ebx = flags;
  cs->ecx = stack;
  cs->edx = (uint32_t)ptid;
  cs->esi = (uint32_t)tls;
  cs->edi = (uint32_t)ctid;
  cs->ebp = ebp;
  cs->esp_unused = 0;
  cs->eip = frame[0];
  cs->cs = GDT_USER_CODE_SEL + 3;
  cs->eflags = frame[2];
  cs->esp = stack;
  cs->ss = GDT_USER_DATA_SEL + 3;
  tss->esp = (uint32_t)cs;
  tss->eip = (uint32_t)startClonedThread;

  threadStart(tss);
  return tss->tid;
}


/* Thread-local storage: a single GDT slot (GDT_TLS_INDEX) shared by all
   threads, rewritten from the incoming thread's tss on every switch. */
void tls_load(void * t) {
  tss_t * thread = (tss_t *)t;
  if (thread->tls_limit == 0 && thread->tls_base == 0)
    gdt_set_entry(GDT_TLS_INDEX, 0, 0xFFFFF,
		  D_DATA + D_WRITE + D_BIG + D_BIG_LIM + D_DPL3);
  else
    gdt_set_entry(GDT_TLS_INDEX, thread->tls_base, thread->tls_limit,
		  D_DATA + D_WRITE + D_BIG + D_DPL3 +
		  (thread->tls_pages ? D_BIG_LIM : 0));
}

int _linux_syscall_set_thread_area(struct user_desc * u_info) {
  USER(u_info, sizeof *u_info);
  if (u_info->entry_number != (uint32_t)-1 &&
      u_info->entry_number != GDT_TLS_INDEX)
    return -22; /* EINVAL */

  currThread->tls_base = u_info->base_addr;
  currThread->tls_limit = u_info->limit & 0xFFFFF;
  currThread->tls_pages = (u_info->flags >> 4) & 1;
  u_info->entry_number = GDT_TLS_INDEX;
  tls_load(currThread);
  return 0;
}

